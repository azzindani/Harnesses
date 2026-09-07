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

## 23. `append_text` and `insert_paragraph` report a style they did not apply — MEDIUM

Found by probing all 55 dispatch parameters with a value they cannot mean.

    append_text(style="Heading 1")  -> success, style: "Heading 1"
    append_text(style="Headng 1")   -> success, style: "Headng 1"

    read_document:
      index 1  "should be a heading"  style: "Heading 1"   <- applied
      index 2  "typo style"           style: "Normal"      <- silently fell back

An unknown style name falls back to Normal, and the response echoes the name the
caller sent as though it had been used. One typo in a style name produces body
text where a heading was asked for, reported as a success naming the heading.
Every downstream consumer then agrees with the document and not the response:
`get_document_outline` will not list it, `get_document_index` will not open a
section for it.

Same shape as finding 2 — the echo describes the request, not the result.

## 24. `plot_learning_curve` accepts any `task` — MEDIUM

    plot_learning_curve(target_column="spends", model="lir", task="typo")
      -> success: true, scoring: "r2", final_val_score: 0.7829

It fell through to the regression path. Its siblings all refuse:

    train_with_cv(task="typo")         -> refused, legal set listed
    tune_hyperparameters(task="typo")  -> refused, legal set listed
    compare_models(task="typo")        -> refused, legal set listed

`task` decides whether the curve is scored with r2 or accuracy. Asking for
classification on a continuous target and silently getting an r2 curve back,
labelled `scoring: "r2"`, is a plot that answers a different question than the
one asked.

---

## Where the fleet already gets this right

Of the 55 dispatch parameters probed with a value they cannot mean, **50
refused** — including every one on filesystem, docs-edit, data-transform,
data-visual and ml-basic:

    fs_manage       "Use one of: disk_usage, permissions, symlink_info, versions."
    reshape_dataset "Valid modes: combine_columns, melt, pivot, split_column, transpose"
    generate_chart  "Valid types: bar, funnel, geo, line, parallel_coords, pie, ..."
    train_regressor "Unknown model: 'lr'. Allowed: dtr, lar, lir, pr, rfr, rr, xgb"
                    "'lr' is a train_classifier() model. Pick one listed above..."

All but one of those 50 named the legal set or the specific conflict; the
exception was `generate_chart`'s `agg_func`, which is finding 4.

*(A correction to how that number was reached: the first pass used
`definitely_not_a_valid_value` as the probe, and the test for "did the refusal
list the legal values?" searched the response for words including **valid** —
which the probe string itself contains, so every refusal that echoed the value
scored as a pass. Re-run with the neutral token `zzqq_no_such_choice` and the
probe value stripped before the search. The counts above are from the corrected
run. The six silent acceptances were unaffected, and one of those six —
`fs_query`'s `grep_mode` — turned out to be the probe's own error: `True` is a
valid value for a boolean.)*

So finding 5 is not "the fleet does not validate dispatch values" — it validates
them well in 50 places and forgets in 5. The enum belongs in the schema so that
remembering is not required.

---

# The fixes

All 24 findings addressed, one deliberately declined. Every repo green on its
own full gate — `ruff check`, `ruff format --check`, `pyright`, `pytest`,
and the 80-char tool-docstring cap — and 82 tests added:

| repo | suite | was |
|---|---|---|
| MCP_Data_Analyst | 2,952 | 2,934 |
| MCP_Microsoft_Office | 2,197 | 2,181 |
| MCP_Machine_Learning | 1,942 | 1,930 |
| MCP_File_System | 723 | 712 |
| MCP_Documents | 440 | 435 |
| MCP_Web_Browser | 260 | 248 |
| MCP_Math | 239 | 231 |

## What each fix was

**1, 6 — `check_outliers`, and the two names for one statistic.**
`shared/choice.py` is a new module in the line `arg_alias.py` (parameter names)
and `value_alias.py` (filter operators) already established: one table per
closed set of dispatch values, one refusal rendered from it, and sibling
spellings resolved rather than punished. `check_outliers` now refuses a method
it cannot read and names `iqr, std, both`; `zscore` resolves to `std` there and
`std` resolves to `zscore` at `detect_anomalies`. Neither canonical name moved.

**2, 3 — `cross_tabulate`.** `normalize_mode()` refuses what it cannot read and
the response echoes the value *used*, not the value sent. When `values_column`
is absent, `agg_func` cannot apply, so the response says so in `progress`
instead of dropping it in silence.

**4 — hints that named the wrong argument.** `pivot_table`,
`generate_correlation_heatmap` and `generate_chart` now validate the parameter
that was actually wrong, before pandas sees it. `compute_aggregations` and
`pivot_table` share one `AGG_FUNCS` table, so the two siblings stop disagreeing
about what a valid function is — and `average` resolves to `mean`.

**5 — the enum.** The five runtime gaps are closed (findings 1, 2, 23, 24, and
`cross_tabulate`'s `agg_func`). The schema-level `enum` is **not** done, and is
the one substantial thing left: several of these parameters accept documented
aliases (`period_unit` takes `D/W/M/Q/Y/H` *and* `MoM/QoQ/YoY`; `export_data`'s
`format` takes `xlsx` for `excel`), so a `Literal` narrows a contract callers
already rely on. That is a deliberate change of surface, not a bug fix, and it
belongs in its own round with the alias sets enumerated first.

**7 — `list_fs_ops`.** Filesystem now has the discovery half it was missing,
rendered from `ALLOWED_OPS`/`_REQUIRED`/`_OPTIONAL`/`_FIELD_ALIASES` rather than
restated, with a worked example per op and a test asserting every example is a
call the validator accepts.

**8 — `add_chart` docstrings** name `chart_type`, which is the parameter that
exists.

**9 — the regex.** `_DETAIL` in `arg_errors.py` could not cross a `]` inside
`input_value`, so a rejected call that happened to contain a list fell through
to the raw pydantic dump while one without a list parsed cleanly. That was the
whole difference between `add_slide`'s clean refusal and `add_table`'s. Fixed
in all four repos that ship the module.

**10 — not-found errors** report the path they were given, not its basename.

**11 — Shapiro-Wilk.** `shapiro_sample()` reports what was actually tested.
`data-statistics/statistical_test` now caps at 5,000 like its two siblings, so
the fleet gives one answer (p=3.61e-88) instead of two, and every caller that
subsamples says so with `n_used`, `n_total` and a note naming scipy's reason.

**12 — the four repos without `arg_errors.py`** have it, installed before
`enforce_known_arguments` so the name guard still answers first.

**13 — `browser`** emits `success` alongside `ok`. `ok` is unchanged.

**14 — `math/integrate`'s docstring** says the bounds are quoted strings.

**15 — `dry_run`** computes and returns `leakage_suspects` and `leakage_note` in
both trainers, from the same data the dry run already had in hand.

**16 — `drop_column`** accepts `column` and `columns` at all three tools that
run the op, and a list drops all or none.

**18 — `create_invoice`** returns `tax` and `total` beside `subtotal`, plus the
`"Stored, not computed"` note its four sibling formula tools already carry.

**19 — `diff_versions`** says what it compared: *"No changes detected: no text
or structural changes (formatting and styling are not compared)."*

**20 — `add_table`** returns `table_index` and `table_count`, and warns when the
insert renumbers tables a caller may already be holding an index into.

**21 — `set_cell_style`** takes `fill` and `fill_color` at both tools, resolved
in the engine so a direct caller and an MCP caller cannot diverge.

**22 — `fs_archive`** infers the format from the extension for every action, not
just `create`. In passing: the server defaulted `format_=""` and the engine
`"zip"`, so the engine default was dead for every MCP caller and live for every
direct one — two behaviours behind one signature. Now aligned.

**23 — `append_text` / `insert_paragraph`** check the style against the open
document before the snapshot and before anything is written, and refuse with the
document's real style names. Nothing is written on a refusal.

**24 — `plot_learning_curve`** validates `task` with the same sentence its three
siblings use.

## The one declined

**17 — `create_from_blocks` returning success when no block was written.**
Implemented, then reverted. This repo states the opposite contract deliberately,
in a test whose docstring reads *"The refusal has to carry the answer, or it
costs the loop it saved"* and whose assertion is *"an unrecognised kind must be
reported, not dropped"*. The response already carries `skipped`, `block_count: 0`
and a warning naming every valid kind — the information a caller needs is all
there, and refusing would hand back no file instead of a file plus a diagnosis.
Round 28 rated this LOW and it does not survive contact with the repo's own
reasoning. What was kept is the half that does: the warning now also points at
`list_block_kinds` and says body text is `kind='text'` — which is what all three
of the blocks round 28 sent actually meant.

---

# Verified on the deployed fleet

All seven containers rebuilt from the pushed commits, all seven CI runs green
(ubuntu-22.04 / macos-latest / windows-latest, plus the container E2E job).

`./verify_r28_fixes.sh` — **47 assertions, all passing**, by direct MCP call
against the running servers. Each one picks inputs that hit the branch the fix
*added*, which is the standing lesson of four previous rounds: a checker left to
choose its own inputs picks the branch that did not change and reports green.

    check_outliers  refuses an unknown method, names iqr/std/both, offers no
                    verdict alongside the refusal; zscore resolves to std and
                    the 3-sigma scan runs; std resolves to zscore the other way
    cross_tabulate  refuses an unreadable normalize; echoes "index" for "rows";
                    reports a dropped agg_func instead of swallowing it
    pivot_table     names agg_func, no longer blames file_path; "average" ->
                    "mean"; median accepted at both siblings
    Shapiro         both endpoints now answer 3.61e-88 (was 3.61e-88 against
                    3.81e-121), and the subsample is disclosed
    dry_run         returns leakage_suspects naming link_clicks with
                    component_of_target, while still saying would_train
    list_fs_ops     names copy's src/dst with a worked example
    fs_read/manage  report the whole path they were given
    fs_archive      lists a .zip without being told the format
    4 endpoints     a wrong-typed argument stays inside the contract, no
                    pydantic.dev URL; browser carries both success and ok
    append_text     refuses an unknown style and suggests the real name
    add_table       returns table_index and warns when it renumbers
    create_invoice  reports tax and total and says the cells are formulas
    diff_versions   says what it did not compare
    Ad_Data.csv     md5 9a16b9248526466960194df4eb7a3e90, unchanged

**The first run of that script scored 44/47** and reported three passing
behaviours as broken — `integrate`, the Shapiro comparison and `diff_versions`.
All three were the same bug in the *checker*: a tool result arrives as the JSON
string `result.content[0].text`, so every quote on the wire is
backslash-escaped, and half the assertions matched `"` instead of `\"`. The
identical mistake had just been made in the File_System smoke test and caught by
CI. Fixed, stated at the top of the script, and worth repeating: **a checker
that scores itself wrong is indistinguishable from a regression** until you read
the response it rejected.

## Fleet-wide re-probes

    245 tools on 26 endpoints, an argument name none of them declares
      -> REFUSED 245/245     (r27's guard intact, including the new tool)

    56 dispatch parameters, a value they cannot mean
      -> silently accepted: 0 of the 5 that were   (fs_query's grep_mode still
         appears, and is the probe's own error: True is valid for a boolean)
      -> refused: 55, all naming the legal set except fs_archive's format_,
         which names the specific conflict instead ("format 'zip' contradicts
         the extension of 'out.tar.gz'") and is better for that case

Tool count 244 → 245: `list_fs_ops`.
---

# Round 29 — the enum

Round 28 fixed the runtime side of the dispatch contract and deferred the
schema, for a stated reason: several of these parameters accept documented
aliases, so a `Literal` would narrow a contract callers already rely on. This
round did the schema side, and the deferral turned out to be the right call for
a sharper reason than the one given.

## The mechanism, chosen by measurement

Both candidates emit **the same JSON schema** on the bundled FastMCP:

    Literal["a", "b"]
    Annotated[str, Field(json_schema_extra={"enum": ["a", "b"]})]

      -> {"default": "a", "enum": ["a", "b"], "title": "Mode", "type": "string"}

So both deliver the entire client-facing benefit — a client reads `tools/list`,
sees the legal values, and never sends a wrong one. They differ only in what
happens to a value from outside the set:

    with_literal   mode='alias_c'  -> RAISED ToolError: 1 validation error
    with_extra     mode='alias_c'  -> {'success': True, 'mode': 'alias_c'}

`Literal` makes pydantic answer before the tool body runs. That costs two things
this fleet has spent twenty-eight rounds building:

**The aliases.** `zscore` for `std`, `average` for `mean`, `MoM` for `M`, `==`
for `equals`, `xlsx` for `excel`, `column` for `columns`. Each exists because a
caller reached for it first, and being refused over a vocabulary difference is a
wasted turn. A `Literal` of canonical names breaks every one; a `Literal` that
lists the aliases too turns a three-value enum into a fourteen-value wall and
stops being the readable answer it was added to be.

**The refusals.** `train_regressor(model="lr")` currently answers:

    error: "Unknown model: 'lr'. Allowed: dtr, lar, lir, pr, rfr, rr, xgb"
    hint:  "'lr' is a train_classifier() model. Pick one listed above, or
            call train_classifier()."

That is the best error message in the fleet. `Literal` would replace it with
pydantic's generic `literal_error`.

So the enum **advertises** rather than enforces. The schema names the canonical
values, the client validates against them and stops sending wrong ones, and
anything that does arrive still reaches a tool that knows about aliases and can
say something useful. `shared/schema_enum.py` carries that reasoning next to the
two functions that implement it.

## What was annotated

**63 dispatch parameters across 6 repos** now name their values in the schema.
Math has none. Every enum renders from the table the runtime switches on rather
than a second copy — `ALLOWED_OPS` for `list_fs_ops`, `ALLOWED_CLASSIFIERS` /
`ALLOWED_REGRESSORS` for the six model parameters, `AGG_FUNCS`,
`OUTLIER_METHODS`, `ANOMALY_METHODS`, `CORRELATION_METHODS`, `NORMALIZE_MODES`
from `shared/choice.py`. This repo has twice traced a chain of defects to a
second table whose copies drifted; a test asserts the two agree.

Three parameters correctly have **no** enum, and the exception list carries the
reason for each rather than just the name:

    office-docx-basic/append_text.style        a .docx defines its own styles.
    office-docx-basic/insert_paragraph.style   The stock template has about a
                                               hundred and a caller's template
                                               can add any name. `resolve_style`
                                               reads the real set at call time
                                               and the refusal lists it.

    data-visual/generate_geo_map.location_mode plotly's own vocabulary, passed
                                               through unchanged and detected
                                               from the data when omitted.

## Four more of finding 4, found by the survey

Building the value tables meant poisoning every dispatch parameter and reading
what came back, and that turned up four tools round 28 had not reached — the
same class as finding 4, in tools I had not thought to check:

    cross_tabulate.agg_func       "'typo' is not a valid function for
    reshape_dataset.agg_func       'DataFrameGroupBy' object" -- pandas'
    generate_multi_chart.agg_func  complaint, under a hint naming the
                                   arguments that were fine

    aggregate_dataset.normalize   "Not a valid normalize argument" under
                                  "Check mode and required parameters. Use
                                  inspect_dataset() to verify column names"

All four now validate against the same shared tables as their siblings. That is
the argument for doing the schema work at all: **enumerating the legal values
forces you to find out what they are**, and three of the four tools could not
answer the question.

## The tests

A census test per repo, and it is the part worth keeping:

* every parameter matching the dispatch names must declare an enum, or appear in
  `NO_ENUM_IS_CORRECT` **with a reason** — so a new tool with a bare `mode: str`
  fails loudly rather than joining the pile;
* an exception that no longer exists is a stale excuse and fails too;
* no enum may be empty or repeat itself;
* a default must be one of its own declared values;
* the declared set must equal the runtime table it renders from;
* **every declared value must be one the tool actually takes** — the test that
  matters most, because an advertised set can lie and this one must not.

The census caught two real gaps while being written: the `test` alias spellings
of `test_type` on both statistical-test tools had no enum, and three of my own
exception entries named parameters that did not exist.

## Verified on the deployed fleet

The same script, run before and after the rebuild, is the whole result:

    before:  69 dispatch parameters,  0 naming their values  -> FAILED
    after:   69 dispatch parameters, 66 naming their values  -> ALL PASSED

and the three without one print the reason rather than a blank:

    data-visual/generate_geo_map.location_mode   plotly's set, auto-detected when omitted
    office-docx-basic/append_text.style          the .docx defines its own styles;
    office-docx-basic/insert_paragraph.style     resolve_style reads the real set

Nothing regressed. Re-run against the rebuilt servers:

    verify_r28_fixes.sh          47 / 47 assertions pass
    unknown-argument sweep       245 / 245 tools still refuse a name they do not declare
    dispatch-value probe         0 of the 5 silent acceptances have returned

And the reason the enum advertises rather than enforces, checked through the
deployed servers with the enum in place:

    check_outliers        method="zscore"      -> success, used std
    detect_anomalies      method="std"         -> success, used zscore
    compute_aggregations  agg_func="average"   -> success, used mean
    cross_tabulate        normalize="rows"     -> success, used index
    period_comparison     period_unit="MoM"    -> success, used M
    compare_models        models=["lir","rfr"] -> success, ranked both

A `Literal` would have refused every one of those six before the tool body ran.
