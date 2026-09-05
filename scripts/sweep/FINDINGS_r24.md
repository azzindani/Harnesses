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
