# Round 24 findings — the first 18 phases

Two confirmed, both re-tested by hand against the live deployment rather than
taken from a report. The raw reports carry roughly sixty BROKEN verdicts across
the eighteen phases; that is a candidate count, not a defect count — round 17
confirmed 2 of 9 and the rest dissolved on verification. These two did not.

---

## 1. `dayfirst` documents three values and enforces none (MCP_Data_Analyst)

**Confirmed on the deployment.** The description of `time_series_analysis`,
`period_comparison` and `cohort_analysis` all end the same way:

    Trend, seasonality and rolling stats. dayfirst: auto true false.

Three values, named in the sentence the caller reads. What the deployed server
actually does with `Ad_Data.csv`, whose `Date` column is unambiguous ISO
`YYYY-MM-DD` (verified: all 16,834 rows have a four-digit first field):

| `dayfirst=` | documented? | date range returned | correct? |
|---|---|---|---|
| `auto` | yes | 2019-10-16 .. 2020-07-07 | yes |
| `true` | yes | 2019-01-11 .. 2020-12-06 | no — month and day swapped |
| `false` | yes | 2019-10-16 .. 2020-07-07 | yes |
| `yes` | **no** | 2019-01-11 .. 2020-12-06 | no |
| `YES` | **no** | 2019-01-11 .. 2020-12-06 | no |
| `1` | **no** | 2019-01-11 .. 2020-12-06 | no |
| `banana` | **no** | 2019-10-16 .. 2020-07-07 | yes, by luck |

Every one of the seven returned `success: true`. Anything truthy-looking is
coerced to day-first, anything else falls through to month-first, and **no value
is ever refused** — so `ture`, `Yes` and `flase` are three different silent
answers to the same question, and only one of them is the one the caller meant.
The dates then flow into `trend`, `seasonality`, the rolling stats and the
chart, which is why this is worth more than a validation nit.

**The fleet already disagrees with itself here.** Office's `bold`/`italic` are
the quoted strings `"true"`, `"false"`, `""` precisely because a boolean cannot
say *turn it off*, and a wrong value there is **refused with a hint naming the
accepted forms**. That is the same tri-state shape, solved. `dayfirst` is the
copy that drifted.

Fix has two halves and both are wanted: refuse a value outside the documented
three, with a hint naming them; and, since `true` on an unambiguous ISO column
produces a silently wrong answer, say so in the response when the requested
interpretation contradicts what the column plainly is.

---

## 2. `statistical_test` advertises six tests and runs seventeen (MCP_Data_Analyst)

**Confirmed on the deployment.** The description:

    Run stat test. test: shapiro_wilk t_test anova chi_square mann_whitney kruskal.

Six. Calling `test="anderson"` does not fail as unknown — it fails asking for
the argument it needs, and its own hint enumerates the real vocabulary:

    Valid tests: anderson, anova, chi_square, fisher, kendall, kruskal, ks,
    levene, mann_whitney, one_sample_t, paired_t_test, pearson, proportion_z,
    shapiro_wilk, spearman, t_test, wilcoxon

**Seventeen.** The description names six of them, so eleven working tests —
`levene`, `wilcoxon`, `ks`, `fisher`, `kendall`, `spearman`, `pearson`,
`proportion_z`, `one_sample_t`, `paired_t_test`, `anderson` — are invisible to
every caller who reads the tool list, which is every caller. This is the
round-14 family exactly: **a vocabulary written down twice, where the copies
drifted.** The error path is the honest copy.

The 80-character cap is the reason and not an excuse: `list_block_kinds` is the
pattern this fleet already uses when a vocabulary outgrows its sentence, and the
error hint here is already the content such a tool would return.

---


---

# Triage of the 43 BROKEN rows

Isolated to the BROKEN verdicts only — the 226 HELD rows were not re-checked.
Every line below was re-called against the live deployment.

## Confirmed

### 3. `search_columns`' dtype filter does nothing (MCP_Machine_Learning)

    Search columns by condition. Returns names only, no data

`dtype="float64"` on `Ad_Data.csv` returns **all 16 columns** — `Date`,
`product`, `phase` and the rest included — with `total_matched: 16`.
`dtype="object"` also returns 16. `has_nulls=true` correctly returns 1.
So the condition is ignored for `dtype` and honoured for `has_nulls`.

**The sibling settles it.** `data-basic.search_columns`, same name and same
claim in MCP_Data_Analyst, answers `dtype="float64"` with exactly the four
numeric columns. One repo filters, the other does not, and the caller cannot
tell: both say `success: true` and both "return names only".

### 4. `fs_archive` writes a ZIP and calls it `.tar.gz` (MCP_File_System)

    Create or extract zip/tar.gz. path=archive, target=what goes in it.

`action=create` with `path=t.tar.gz`:

    "format": "zip"
    $ file t.tar.gz
    t.tar.gz: Zip archive data, at least v2.0 to extract

The bytes are a zip, the name says tar.gz, and `success: true`. tar.gz is
advertised in the description, so a caller who asks for one gets a file that
`tar -xzf` cannot open. The `format` field is honest and the filename is not,
which is the wrong way round: the extension is what the next tool reads.

### 5. `read_page` promises links it never returns (MCP_Documents)

    Read one page: text, tables, links, and how each was obtained.

Fields actually returned: `basis, bbox, columns, confidence, looks_tabular,
message, of, op, page, progress, result, rotation, rows, shape, size, status,
success, tables, text, token_estimate, words`. **No `links`.** Three of the
four things the sentence names come back; the third does not exist.

### 6. `find` says "not content" and returns content (MCP_Documents)

    Locate text across a document. Returns page locations, not content.

Every hit carries a `snippet` holding real document text
(`"…one. (021) 235 88000 | Fax. (021) 235 88300 | Website : www"`). The
snippets are wanted — they are how a caller decides which page to extract —
so the code is right and the sentence is wrong. Deleting three words fixes it.

### 7. `ocr` says a page range is required and does not require one (MCP_Documents)

    Add a searchable text layer to scanned pages. Page range required.

Called with no `pages`: `success: true`, `pages_ocred: 1`, `pages: "2"`. It
defaults to the pages with no text layer, which is better behaviour than the
description promises — and the description still turns a caller away from the
call that works.

### 8. Two docs-edit descriptions name a verb the tool will not accept

    optimize:  Compress, repair or linearise a PDF.  -> action="linearise"
               "'linearise' is not an action this tool has." Use: linearize.
    protect:   Encrypt, decrypt, or clear a PDF's permission flags. -> action="clear"
               "'clear' is not an action this tool has." Use: permissions.

Both refusals are well-formed and name the right value, so a caller recovers on
the second try. But in both cases the word the description uses is the word the
tool rejects, and the description is the only place a caller looks first.

## Minor — the description should say it, the code is fine

* **`create_report` adds a Cover sheet nobody asked for.** Two sheets in,
  `sheets_created: 3`. It is announced in `progress` ("2 data sheet(s) +
  Cover"), so nothing is hidden; the description just does not mention it.
* **`query_export` says "Returns path only"** and returns thirteen fields. The
  intended contrast — the path rather than the exported rows — is true and
  useful. Wording, not behaviour.

## Plausible, NOT reproduced

**`convert_to_values` may never convert a formula this server wrote.** The
report has it returning `success: true`, `formulas_converted: 0`, and
`skipped_no_cached_value` listing all nine cells, with a hint saying formulas
written here are never calculated — openpyxl writes no cached value, so there
is nothing to convert to. I could not reproduce it end to end because
`set_formula` rejected my argument name and the range then held no formulas, so
the tool correctly answered "that range holds no formula cells". The shape is
right and the mechanism is believable. **Unverified; check before fixing.**

## Dissolved

| candidate | verdict |
|---|---|
| `detect_anomalies method=both` computes z-scores but never flags them | **No.** The written file has `spends_zscore_flag: 238 True` and `impressions_zscore_flag: 124 True`, matching `zscore_outliers` exactly. The sweep read `anomalies_only`, a filtered subset, and generalised from it. |
| nine rows of "returns more fields than the description lists" (`probe`, `load_dataset`, `inspect_dataset`, `lag_correlation`, `regression_analysis`, `browse_status`, …) | **No.** An 80-character summary is not an exhaustive field list. Judge what the sentence claims, not what it omits. |
| `generate_distribution_plot` "Samples above 5k" sampled exactly 5000 | **No.** The sentence means *samples when the data is above 5k*, not *takes a sample larger than 5k*. |
| `restore_version` "No timestamp overwrites with the newest" | **No.** The behaviour matches; the sentence is ambiguous English and was read as "does not overwrite". Worth rewording. |
| `fs_write` `delete_lines` / `patch_lines` need no token | **No.** "Delete needs a token" is about the delete op, not about editing lines. |
| `cross_tabulate` / `value_counts` accept a numeric column | **No.** Treating a numeric column as categorical is a choice, and `value_counts` announces the extension change in `progress`. |
| `concat_datasets` direction, `feature_engineering` auto | **Real vocabulary drift, same family as `statistical_test`** — the description says vertical/horizontal and auto; the tool takes rows/columns and four named types. Folded into finding 2 rather than counted separately. |

**Score: 8 confirmed findings over 11 tools, 2 wording fixes, 1 unverified,
the rest dissolved.** In line with the round-17 ratio, and the two that came
from reading rather than from a report are still the two best.

## Not findings, recorded so they are not re-raised

| candidate from the reports | verdict |
|---|---|
| every File_System write op "creates a backup file" not mentioned in any description | **True but not scored.** It is the versions/snapshot mechanism `fs_manage action=versions` exists to expose. Worth one clause in a description; not a defect. |
| `set_permissions` rejects `mode="u+rw"` with *"Invalid octal mode"* + a hint | **Contract working.** Scored BROKEN against a claim the model invented. |
| `delete_request` "deletes the file immediately upon request" | **The model's own sentence**, not the tool's. The real description says *Delete needs a token*, which is what it does. |
| `lag_correlation` errors when `min_overlap` exceeds the overlap available | Refusing an impossible request is not a broken promise. |

## What phases 1-4 cost, and what it bought

All four File_System phases scored their verdicts against descriptions the model
wrote itself, because `columns_ops` asked for a per-op sentence and no such
sentence exists — six tools carry about fifty ops behind one line each. Their
verdict columns are void; `columns_ops` is fixed in `AXES[24]` and `phases_r24b.tsv`
re-runs them.

It is worth saying plainly that **`descriptions_r24.tsv` caught this on the
round's first four phases**, which is the entire argument for freezing the
descriptions at launch. Without the key, eight fabricated quotes and a dozen
BROKEN verdicts read exactly like findings.


---

# Shipped 2026-09-06

All eight confirmed findings and both wording fixes, across six repos. Each
commit carries the evidence; `verify_r24_shipped.sh` asserts every one of them
against the deployed servers with no model involved — **16/16 PASS**, and 26/26
endpoints still negotiate.

| repo | head | fix |
|---|---|---|
| Data_Analyst | `abdef7b` | `dayfirst` refuses what it does not document; three drifted vocabularies |
| Machine_Learning | `aba0de7` | `search_columns` dtype filter actually filters |
| File_System | `36b89bc` | `fs_archive` honours the extension |
| Documents | `80af92e` | five sentences that were not true |
| Microsoft_Office | `ff39b88` | `create_report` declares its Cover sheet |
| Web_Browser | `ee51ba9` | `query_export` says what it meant |

Suites after: DA 2898, ML 1900, Office 2170, Documents 428, Browser 243,
File_System 712 — all both modes, ruff, format, pyright and the docstring
census clean in all six, CI green on all six.

**One correction worth keeping.** The first `dayfirst` fix refused unknown
values but kept `"yes"`, `"no"`, `"1"` and `"0"` as silent aliases, on the
reasoning that a JSON boolean arrives as a string. The live check caught it:
`dayfirst="yes"` was still accepted and still chose day-first, which is the
finding itself one draft smaller. The accepted set is now exactly the
documented three. **The lesson is the round's own: a fix verified only by its
own tests is verified against the author's reading of the contract, not against
the contract.** The tests passed; the deployed server was still wrong.
