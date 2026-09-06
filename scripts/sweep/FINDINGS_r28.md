# Round 28 — direct-call sweep

Run as direct MCP calls from the control session. No harness container, no probe
model: every call below was made by the assistant against the deployed servers,
and every claim is checked against `ledger.jsonl`, which holds the full response
to each call.

**Fixture:** `/workspace/data/r28d/ads.csv`, a copy of `Ad_Data.csv`
(md5 `9a16b9248526466960194df4eb7a3e90`, 16,834 rows). The original is never
written to.

**Axis:** the *value* side of the argument contract. Round 27 shipped
`enforce_known_arguments`, which refuses an argument *name* the tool does not
declare. It cannot see a wrong *value* on a parameter whose entire job is to
select behaviour — `method`, `mode`, `action`, `agg_func`, `chart_type`. That is
the next layer down, and it is where this round looked.

**Coverage:** 338 calls, **all 244 tools on all 26 endpoints**, every one called
with real arguments against real data — not a one-argument probe. 258 succeeded,
63 were refused (most of them deliberately, to test a refusal), 17 returned
outside the `success` envelope (all browser — finding 13).

Two tools could only be verified on their refusal path, for want of a fixture:
`data-basic/load_geo_dataset` and `data-transform/enrich_with_geo` both need a
`.geojson` or `.shp` and there is none in the corpus. Both refused a `.csv` and a
`.png` correctly and named the types they want, so their argument contract is
checked and their happy path is not. Nothing else went untested.

`Ad_Data.csv` is still `9a16b9248526466960194df4eb7a3e90` — every write went to
`/workspace/data/r28d/`.

---

## 1. `check_outliers` reports "no outliers" for any method it does not recognise — HIGH

`data-statistics/check_outliers`, and the same function re-exported into
`data-medium`.

    method="std"     -> columns_with_outliers: 4   spends: 238 outliers
    method="iqr"     -> columns_with_outliers: 4   spends: 2178 outliers
    method="both"    -> columns_with_outliers: 4   (the default)
    method="zscore"  -> columns_with_outliers: 0   success: true
    method="typo"    -> columns_with_outliers: 0   success: true

`servers/data_medium/_med_inspect.py:135,169`:

```python
if method in ("iqr", "both"):
    ...
if method in ("std", "both"):
    ...
```

There is no `else`. An unrecognised `method` runs neither branch, so the
per-column record stays `{"n": 16834}`, `cols_with_outliers` stays 0, and the
tool returns `success: true` with `columns_with_outliers: 0` and an empty
`flagged_rows`. Nothing in the response says the method was not understood.

A typo turns "2,178 outliers in spends" into "no outliers found", stated
confidently. This is the truth axis: not a crash, an answer.

`zscore` is the specific typo that matters, because it is not a random string —
it is the token the sibling tool `data-medium/detect_anomalies` uses for this
exact concept (see finding 6). A caller who learns `zscore` there and carries it
here is told the data is clean.

The same file guards the *small sample* case meticulously — `MIN_N_IQR`,
`min_n_for_zscore(3.0)`, and a comment reading *"'0 outliers' there states a
property of the row count, dressed as a finding about the data"*. The unknown
method produces precisely the failure that comment describes, and was never
guarded.

## 2. `cross_tabulate` echoes a `normalize` it did not apply — MEDIUM

`servers/data_medium/_med_report.py:94`:

```python
norm = normalize if normalize in ("index", "columns", "all") else False
```

Garbage silently becomes `False`, which is right. But the response echoes the
caller's value, not the one used:

    normalize="index"   -> table 1.0 / 0.0      echoed "index"     (applied)
    normalize="typo"    -> table 1733 / 15101   echoed "typo"      (NOT applied)
    normalize omitted   -> table 1733 / 15101   echoed false

The row that was not normalised claims it was. A caller reading the echo to
confirm the request landed is told yes.

## 3. `cross_tabulate` discards `agg_func` when `values_column` is absent — MEDIUM

`pd.crosstab` is called without `aggfunc` on that branch, so `agg_func` has no
effect at all:

    agg_func="mean", no values_column  -> counts (1733 / 15101), echoed "count"

The echo is honest here — it says `count`, which is what was computed. But the
caller asked for `mean` and nothing tells them the request was dropped. One
`warn()` in `progress` would close it.

## 4. `pivot_table`'s bad-`agg_func` error blames the wrong argument — MEDIUM

    error: "'typo' is not a valid function for 'DataFrameGroupBy' object"
    hint:  "Check file_path and column names. values must be numeric for most agg_funcs."

The raw pandas exception is passed through, and the hint sends the caller to
inspect `file_path` and the column names — neither of which is wrong. The
sibling `compute_aggregations` gets this right for the same parameter:

    error: "Invalid agg_func: typo"
    hint:  "Valid functions: count, max, mean, min, sum"

## 5. 55 dispatch parameters, 0 enums — MEDIUM, fleet-wide

Across 244 tools on 26 endpoints, 55 parameters exist only to select behaviour
(`action`, `mode`, `method`, `agg_func`, `chart_type`, `how`, `direction`,
`format`, `task`, `model`, `rule`, `style`, `to`, `normalize`). **None declares
an `enum`.** Every one is a bare `{"type": "string"}`.

| endpoint | bare dispatch params |
|---|---|
| data-transform | 8 |
| data-visual | 8 |
| filesystem | 7 |
| data-medium | 6 |
| ml-advanced | 6 |
| ml-medium | 6 |
| data-statistics | 3 |
| docs-edit | 3 |
| ml-basic, office-docx-basic | 2 each |
| browser, office-pptx-design, office-xlsx-charts, office-xlsx-formulas | 1 each |

The legal values exist only in prose, and often not even there —
`fs_manage`'s docstring reads *"Disk usage, permissions, symlink info, or
snapshot version list"* while the tokens are `disk_usage`, `permissions`,
`symlink_info`, `versions`. The caller must guess the exact spelling from
English, and learns it by burning a call.

An `enum` in the schema costs nothing at runtime and moves the whole class from
"discovered by failing" to "impossible to get wrong", because the client
validates before the call is ever sent. It would also have made finding 1
unreachable.

**Where the runtime does validate, it is good.** All seven filesystem dispatch
parameters refuse an unknown value and list the legal set:

    fs_manage  -> "Use one of: disk_usage, permissions, symlink_info, versions."
    fs_index   -> "Use one of: build, query, list, stats, clear, receipt."
    fs_read    -> "Use one of: content, tree, meta, diff, auto."
    fs_archive -> "Use one of: create, extract, list."

That is the standard the rest of the fleet should meet; the point of the enum is
that meeting it should not require remembering to.

## 6. Two names for one concept across sibling tools — MEDIUM

| concept | `data-statistics/check_outliers` | `data-medium/detect_anomalies` |
|---|---|---|
| 3-sigma scan | `method="std"` | `method="zscore"` |
| IQR fence | `method="iqr"` | `method="iqr"` |
| both | `method="both"` | `method="both"` |

Same repo, same fixture, same statistic, two spellings — and because of finding
1, carrying the wrong one into `check_outliers` fails silently rather than
loudly.

## 7. `fs_write` has 21 ops and no way to discover any of them — MEDIUM

`fs_write`'s input schema is:

```json
"ops": {"items": {"additionalProperties": true, "type": "object"}, "type": "array"}
```

— an opaque object. The docstring is one line and names no field: *"Write, edit,
move, copy, download a URL, restore. Delete needs a token."* So the grammar of
all 21 ops is unreachable from `tools/list`.

My own first call this round was `{"op": "copy", "source": ..., "destination": ...}`
and was refused: the fields are `src` and `dst`. The refusal is excellent —

    Op 0 (copy): unknown field(s) destination, source -- copy accepts: dst, op, path, src

— but a call had to fail to produce it.

This is the defect round 27 fixed for `feature_engineering` by adding
`list_derive_ops` and appending the grammar to every `DeriveError`. Filesystem
has the second half and not the first. A `list_fs_ops` mirroring
`list_derive_ops` closes it.

## 8. `add_chart`'s docstring names a parameter that does not exist — MEDIUM

`office-xlsx-charts/add_chart`: *"Create chart from data range. **type:** bar,
line, pie, area, scatter."* The declared parameter is `chart_type`. Same in
`office-pptx-design/add_chart`: *"Add chart to slide. **type:** bar, line, pie."*

A caller working from the description sends `type=` and is refused. That refusal
is the round-27 guard working correctly — it caught me making exactly this
mistake — but the description is what sent me there. Before round 27 the
argument would have been silently dropped and the chart drawn with the default
type.

## 9. Office missing-argument errors use two different shapes — LOW

    office-pptx-basic/add_slide
      error: "add_slide rejected an argument: layout_name: Field required"
      hint:  "layout_name is required. add_slide accepts: body, file_path, layout_name, title."

    office-docx-tables/add_table
      error: "add_table rejected an argument: Error executing tool add_table:
              1 validation error for add_tableArguments\nafter_paragraph_index\n
              Field required [type=missing, input_value={'file_path': '/workspace...
              ['a','b'],['c','d']]}, input_type=dict]"
      hint:  "add_table accepts: after_paragraph_index, cols, data, file_path, rows."

The hint is right in both. The `error` string in the second is the raw pydantic
dump: it leaks the internal model name `add_tableArguments`, echoes a truncated
copy of the caller's own input back at them, and costs roughly four times the
tokens to say the same thing. `create_from_data` on `office-xlsx-new` behaves
the same way.

## 10. `fs_read`'s not-found error drops the path it was given — LOW

    sent:  path="/workspace/data/r28d/ads.csv"
    error: "Path does not exist: ads.csv"
    hint:  "Use fs_query to locate the file first."

Reporting the basename makes a full absolute path look like it was interpreted
as a relative one, which sends the caller to debug the wrong thing.

## 11. The same Shapiro-Wilk test is implemented three ways and reports two different p-values — MEDIUM

Same file, same column (`spends`, n=16,834), same test, two endpoints:

    data-statistics/statistical_test   test=shapiro_wilk  ->  W=0.286858  p=3.81e-121
    data-medium/statistical_tests      test=shapiro_wilk  ->  W=0.282     p=3.61e-88

33 orders of magnitude apart, and neither response says why. The cause is three
separate implementations of one statistic:

| caller | code | sample used | disclosed? |
|---|---|---|---|
| `data-statistics/statistical_test` | `_stats_tests.py:290` — `scipy_stats.shapiro(a.values)` | all 16,834 | n/a |
| `data-medium/statistical_tests` | `_med_analysis.py:551` — `series.sample(min(len, 5000), random_state=42)` | 5,000 | no |
| `data-statistics/regression_analysis` | `_stats_regression.py:428` — `shapiro_p(...)`, `cap=5000` | 5,000 of 16,834 residuals | no |

Two problems, both about what the caller is told:

**The uncapped path suppresses scipy's own accuracy warning.** Run directly,
scipy says:

    UserWarning: scipy.stats.shapiro: For N > 5000, computed p-value may not be
    accurate. Current N is 16834.

`statistical_test` returns `p_value: 3.81e-121` with no caveat.

**The capped paths do not say they subsampled.** `regression_analysis` reports
`observations: 16834` beside `normality_of_residuals: {p_value: 2.41e-84}`,
which reads as a test on all 16,834 residuals. It is a seeded 5,000-row draw;
11,834 residuals were dropped and nothing in the response says so.

The verdict happens to agree in every case here — the column is not remotely
normal — so nothing downstream is wrong today. What is wrong is that two tools
in one fleet answer one question with different numbers and no way to reconcile
them.

`shared/small_sample.py` is the natural home: `shapiro_p` already holds the cap,
and `finite_split` exists precisely so a caller can say what was dropped. Its
own docstring says *"Callers use this to say why a test could not run"*. The
large-n case wants the same sentence.

## 12. Argument-type errors escape the fleet envelope on 4 of 26 endpoints — MEDIUM

Sending a required string parameter as an int, one tool per endpoint:

    22 endpoints  ->  {"success": false, "error": "<tool> rejected an argument:
                       op: Input should be a valid string (got int)",
                       "hint": "Correct the type of op and call again. Nothing was written."}

    browser, docs-read, docs-edit, math  ->  bare text, no envelope:

        Error executing tool calculate: 1 validation error for calculateArguments
        expression
          Input should be a valid string [type=string_type, input_value=123, input_type=int]
            For further information visit https://errors.pydantic.dev/2.13/v/string_type

There is no `success` field at all on those four, so a client that branches on
the fleet envelope has nothing to read. It also leaks the internal model name
(`calculateArguments`) and a pydantic docs URL.

These four are exactly the servers that were *not* touched when
`enforce_known_arguments` went in — the guard covers the wrong-*name* case
everywhere, and the wrong-*type* case was never given the same treatment.

## 13. `browser` answers `ok`, the other 25 endpoints answer `success` — MEDIUM

All 13 browser tools — `browse_search`, `browse_locate`, `browse_inspect`,
`browse_fetch`, `browse_verify`, `browse_status`, `browse_datetime`,
`browse_extract`, `query_locate`, `query_search`, `query_select`,
`query_export`, `query_stats` — return:

    {"ok": false, "op": "browse_extract", "error": "...", "hint": "..."}

Every other endpoint in the fleet returns `success`. A caller written against
the fleet contract reads `success` from a browser response, gets nothing, and
cannot tell a failure from a success. The rest of the envelope (`op`, `error`,
`hint`, `progress`) matches; it is one key.

## 14. `math` alone leaves its string-typed tri-state unexplained — LOW

Six Office parameters and both of `math/integrate`'s bounds are declared
`{"type": "string", "default": ""}` where the value looks boolean or numeric:

    office-docx-layout/set_font           bold, italic
    office-docx-tables/set_cell_style     bold
    office-pptx-design/set_font_style     bold
    office-pptx-design/set_font_all_slides bold
    office-xlsx-charts/set_cell_style     bold
    math/integrate                        lower, upper

This is deliberate and correct: the empty string is a third state. `bold=""`
means *leave the current value alone*, distinct from `"false"`; `lower=""` means
*no bound*, i.e. an indefinite integral. A real boolean or number could not
express it.

Office documents the convention in the docstring — *"bold: 'true', 'false' or ''
to leave"* — and explains it again on failure:

    set_font(bold=True)
      error: "set_font rejected an argument: bold: Input should be a valid string (got bool)"
      hint:  "Pass bold as a quoted string: bold='true' to turn it on,
              bold='false' to turn it off, or leave it out to keep the current
              value. Nothing was written."

`math/integrate` does neither. Its docstring is *"Integrate expression. Returns
indefinite or definite integral"* — no mention that the bounds must be quoted —
and because math is one of the four endpoints in finding 12, the natural call
`integrate(expression="2*x", variable="x", lower=0, upper=3)` fails with a raw
pydantic dump and no hint at all. `lower="0", upper="3"` returns 9.

The pattern is fine. One server implements it without telling anyone.

## 15. `dry_run` is the one mode that withholds the leakage warning — HIGH

`train_regressor(file_path=ads.csv, target_column="clicks", model="rfr")`:

    dry_run omitted:
      leakage_suspects: [{"feature": "link_clicks", "reason": "component_of_target",
                          "containment": 1.0, "r": 0.9253, "rho": 0.2635,
                          "confidence": "high"}]
      leakage_note: "Score 0.9830 may not be real: 'link_clicks' look like they
                     already contain the outcome. Re-train without them..."
      r2: 0.983

    dry_run: true:
      feature_columns: [... "spends", "impressions", "link_clicks"]
      would_train: true
      (no leakage_suspects key, no leakage_note)

`servers/ml_basic/_basic_train.py` — in both trainers the dry-run branch returns
before the check ever runs:

    line 169 / 497:  if dry_run: return {..., "would_train": True}
    line 304 / 591:  suspects = leakage_suspects(df, target_column, feature_cols)

`dry_run` is what a careful caller uses to see what a run *would* do before
committing to it. It is exactly the moment the leakage warning is worth having,
and it is the only mode that does not produce one — so the caller most likely to
look is the one told nothing. Worse, the dry run lists `link_clicks` in
`feature_columns` and says `would_train: true`, which reads as approval.

The fix is cheap: `leakage_suspects` needs only `df`, the target and
`feature_cols`, all of which are already in hand at the dry-run return — it is
the same list the dry run prints.

Round 27 built this check and this round confirms it works: the live run names
`link_clicks`, gives containment 1.0 with `r=0.9253` against `rho=0.2635` (the
max-of-the-two calibration holding up), and says the 0.983 may not be real.
That is the fix working. It just does not reach dry-run callers.

## 16. `drop_column` has two incompatible grammars in one fleet — MEDIUM

Three tools run ordered op lists. The same op name takes a different field:

| tool | accepted | rejected |
|---|---|---|
| `ml-medium/run_preprocessing` | `{"op":"drop_column","column":"age"}` | `columns` |
| `data-basic/apply_patch` | `{"op":"drop_column","columns":["age"]}` | `column` |
| `data-transform/run_cleaning_pipeline` | `{"op":"drop_column","columns":["age"]}` | `column` |

Singular string on the ML server, plural list on both Data Analyst servers. The
refusals are good on their own terms — the DA side even says *"unknown field(s)
column -- did you mean columns?"* — but that suggestion is precisely wrong for a
caller who just used the ML spelling, and the ML side's error (*"missing
required field: 'column'"*) is equally confident in the other direction.

Nothing tells a caller the two servers disagree, and neither `list_patch_ops`
(DA, 52 ops) nor anything on the ML side mentions the other spelling.

## 17. `create_from_blocks` writes an empty document and calls it success — LOW

    blocks: [{"kind":"paragraph"...}, {"kind":"para"...}, {"kind":"bodytext"...}]
    -> success: true, block_count: 0, and a d8.docx containing only its title

The correct kind for a body paragraph is `text`. All three of mine were wrong,
all three were dropped, and the file was still written and reported as a
success.

The reporting around it is genuinely good — better than most of this fleet:

    skipped:  ["block 0 has kind='paragraph'", "block 1 has kind='para'",
               "block 2 has kind='bodytext'"]
    progress: warn "3 block(s) written nothing" -- "block 0 has kind='paragraph';
              ... Valid kinds: heading, text, bullets, table, kpi, callout,
              image, links, risks, checklist, rule, pagebreak."

Every skipped block is named and every legal kind is listed, which is exactly
what finding 5 asks the rest of the fleet for. The only thing wrong is the
verdict: `success: true` on a document where none of the requested content
landed. A downstream `merge_documents` or `export_pdf` then runs happily on an
empty file. When `block_count` is 0 and `skipped` is non-empty, nothing was
built.

## 18. `create_invoice` produces an invoice with no numbers in it — HIGH

    create_invoice(company_name="Analytics Ltd", client_name="Marketing",
                   invoice_number="R28-001", tax_rate=0.1,
                   items=[{"description": "Ad spend review", "quantity": 1,
                           "unit_price": 1000}])

    -> success: true, subtotal: 1000.0
       progress: ok "Written subtotal, tax, and total rows"

Reading the file back, every money cell is empty:

    A7   'Ad spend review'      B7  1        C7  1000
    D7   value=None             formula='=B7*C7'      <- line total
    D9   value=None             formula='=SUM(D7:D7)' <- subtotal
    D10  value=None             formula='=D9*0.1'     <- tax
    D11  value=None             formula='=D9+D10'     <- grand total

The Office server has no calculation engine — it writes formula text and the
cached result only appears once Excel or LibreOffice opens and saves the file.
That is a known, deliberate limitation, and three sibling tools on the same
server state it plainly in every response:

    set_formula / auto_sum / fill_formula_down:
      "note": "Stored, not computed. This server writes the formula text; it has
               no calculation engine, so the cell has no cached result until
               Excel or LibreOffice opens the file and saves it. read_cell()
               reports such a cell as type 'formula_uncalculated'."

    convert_to_values:
      "skipped_no_cached_value": ["D2", "D3", "D4"]

`create_invoice` carries no such note. It reports `subtotal: 1000.0` — computed
in Python, correct, and *not* what is in the file — and never mentions tax or
total at all. So the response looks like a finished invoice while the artifact
has four blank cells where the money goes, and the one figure the caller is
shown is the one figure the document does not contain.

Anything that reads the file without recalculating sees the blanks: a preview,
a PDF conversion, `openpyxl`, pandas, or this fleet's own `read_cell`, which
correctly reports `type: "formula_uncalculated"`.

The fix is the note the other four tools already carry, plus returning the
computed `tax` and `total` beside `subtotal`. Writing literal values instead of
formulas would also work, but loses the recalculating spreadsheet the formulas
are there to provide — the note is the honest minimum.

## 19. `diff_versions` reports "No changes detected" after a change it just made — MEDIUM

Controlled test, both document servers. Change one thing — the font — then diff
against the snapshot taken immediately before it:

    office-pptx-design/set_font_all_slides(p3.pptx, font_name="Times New Roman", bold="true")
      -> success: true, slides_modified: 2, shapes_modified: 3
         backup: p3_2026-09-06T22-44-40-335733Z.pptx.bak

    office-pptx-basic/diff_versions(p3.pptx, timestamp_a="2026-09-06T22-44-40-335733Z")
      -> summary: "No changes detected."   change_count: 0
         text_changes: []   slide_changes: []

    office-docx-layout/set_font(d5.docx, paragraph_index=0, font_name="Times New Roman", bold="true")
    office-docx-basic/diff_versions(d5.docx, timestamp_a=<that backup>)
      -> summary: "No changes detected."   change_count: 0

Both diffs compare text and structure only. That is a reasonable scope — but
"No changes detected" is a claim about the documents, not about the comparison,
and the fleet had reported `shapes_modified: 3` for the very edit being denied.

A caller using `diff_versions` to confirm an edit landed, or to decide whether a
restore is needed, is told nothing happened. The honest sentence is the one the
rest of this fleet writes without being asked — `check_outliers` carries a
comment warning against "a property of the row count, dressed as a finding about
the data", and this is the same shape: a property of the comparison dressed as a
finding about the file. "No text or structural changes; formatting is not
compared" costs six words.

## 20. `add_table` renumbers existing tables and never says which index it made — MEDIUM

    d2.docx, 0 tables
    add_table(after_paragraph_index=0,  data=[["x","y"],["1","2"]])  -> success, no index returned
    add_table(after_paragraph_index=-1, data=[["p","q"],["3","4"]])  -> success, no index returned
    list_tables  -> 2 tables, index 0 and index 1
    read_table(table_index=0)  -> p / q / 3 / 4      <- the SECOND table created

`-1` means "first" (per the docstring), so the second call inserted ahead of the
first and took index 0. Everything about that is correct. What is missing is
that neither response says what index it produced, and nothing warns that
indices the caller already holds have shifted.

This cost me a real mistake inside this sweep: holding `table_index=1` from
before an `add_table`, I called `delete_row(table_index=1, row=1)` expecting the
table I had just created and deleted `["Google Ads", "1939003.26"]` out of the
original one instead. The tool did exactly as asked; the index just no longer
meant what it did a call earlier.

The same server family gets this right elsewhere — `office-pptx-design/duplicate_slide`
returns `new_index: 2` alongside `slide_count: 3`, and `office-pptx-basic/add_slide`
returns `slide_index: 2`. `add_table` should return `table_index`, and say so
when it displaces others.

## 21. Two `set_cell_style` tools, two spellings for the fill colour — LOW

    office-docx-tables/set_cell_style  accepts: align, band_fill, bold, col, color,
                                                file_path, fill, row, table_index
    office-xlsx-charts/set_cell_style  accepts: bold, cell_address, file_path,
                                                fill_color, font_name, font_size,
                                                number_format, sheet_name

Same tool name on the same fleet: `fill` on one, `fill_color` on the other, and
`color` on the first means the *text* colour. Both refuse the other's spelling
with a correct hint, so nothing breaks — but a caller who styles a Word table
and then a spreadsheet cell has to relearn the parameter, and the r27 guard is
what turns each attempt into a wasted call rather than a silent no-op.

Same family as findings 6 and 16.

## 22. `fs_archive` infers the format when creating and demands it when listing — LOW

    fs_archive(action="create", path="out/r28.zip", target="out")
      -> success, "format": "zip"          (inferred from the extension)

    fs_archive(action="list", path="out/r28.zip")
      -> error: "Unknown format ''"
         hint:  "Use 'zip' or 'tar.gz'."

    fs_archive(action="list", path="out/r28.zip", format_="zip")   -> success
    fs_archive(action="list", path="out/r28.zip", format="zip")    -> success

`create` reads `.zip` off the name — and its own earlier error even advises
*"Drop `format` and let the extension decide"* — while `list` refuses to. The
error also names no parameter, and the tool declares two of them (`format` and
`format_`, both accepted), so the caller has to guess which the message means.
