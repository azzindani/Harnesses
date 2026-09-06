# Round 25 — the isolated re-check

Round 24's axis, re-asked on the ten phases holding the sixteen tools its
findings touched. Same question, so a description that was false and is now true
should return **HELD** where it returned **BROKEN**.

**45 → 10 phases, 61 rows, run 2026-09-06 07:58Z–12:01Z.**

## The comparison

| tool | r24 | r25 | |
|---|---|---|---|
| `find` | BROKEN | **HELD** | |
| `read_page` | BROKEN | **HELD** | |
| `optimize` | BROKEN | **HELD** | |
| `protect` | BROKEN | **HELD** | |
| `fs_archive` | BROKEN | **HELD** | |
| `statistical_test` | BROKEN | **HELD** | |
| `time_series_analysis` | BROKEN | **HELD** | |
| `period_comparison` | BROKEN | **HELD** | |
| `cohort_analysis` | BROKEN | **HELD** | |
| `query_export` | BROKEN | **HELD** | |
| `search_columns` | BROKEN | **HELD** | |
| `create_report` | BROKEN | **HELD** | |
| `ocr` | BROKEN | BROKEN | new claim |
| `resample_timeseries` | BROKEN | BROKEN | new claim |
| `feature_engineering` | BROKEN | BROKEN | new claim |
| `concat_datasets` | BROKEN | BROKEN | new claim |

**12 of 16 flipped.** Each of the four that did not was read row by row: none is
a regression, and none re-states its round-24 claim. All four quote the *new*
description correctly and then test something else.

Two are worth quoting because they show the fix landing exactly as intended:

    statistical_test | "Run a stat test. 17 available: an unknown 'test' lists
    them all." | called test=unknown_test | HELD | Returns error with hint
    listing exactly 17 valid tests

An uninformed model discovered all seventeen tests from the description alone.
Round 24 found eleven of them invisible to every caller.

    create_report | "Multi-sheet .xlsx from [{name,headers,rows}], plus a Cover
    sheet." | HELD | automatically added Cover sheet as promised

## What an axis re-run could not do, again

Every `dayfirst` tool came back HELD, and every one was called with
`dayfirst=auto` — the valid value. **The refusal branch was never exercised**,
3-for-3, which is the standing lesson holding: a model picks its own inputs and
picks the branch the fix did not change. `verify_r24_shipped.sh` is what settles
that, and did (`dayfirst='yes' refused`, refusal names all three).

What the sweep contributes instead is the half no script can reach: **nothing
nearby broke.** Trend, seasonality, cohort matrices, MoM comparison, the other
five docs-read tools, the whole filesystem action set — all still HELD.

## Three new findings, all round 24's own family

The re-check found the same disease in tools round 24 had passed:

* **`resample_timeseries` lists five aggregations and accepts nine.** The
  description says `agg: sum mean count min max`; `median` succeeds, and the
  real set is `first, last, median, min, max, mean, std, sum, count`. This is
  `statistical_test` exactly — a vocabulary written down twice where the copies
  drifted — in a tool nobody had checked.
* **`feature_engineering`'s `one_hot` silently skips columns.** More than 10
  distinct values, or beyond the first 5 eligible columns, and the column is
  dropped from the encoding. The progress messages say so at call time (*"above
  the 10 one-hot allows"*), so it is declared — just not before you call.
* **`concat_datasets` column-mode requires equal row counts.** Unstated in the
  description. Weakest of the three: it refuses cleanly and the error names the
  counts (`Got: [3, 1]`), so only the pre-warning is missing.

## Fixed 2026-09-06 — MCP_Data_Analyst `8cb3767`

All three shipped, CI green, deployed, and asserted on the live server by
`verify_r25_fixes.sh` (4/4). `resample_timeseries` now names all nine
aggregations, and a test reads `_VALID_AGGS` and fails if the sentence and the
set ever separate again. `concat_datasets` states the equal-row-count
constraint its refusal already named. `feature_engineering` says `one_hot` is
capped, with a test holding the response to naming which columns were skipped
and why.

The root cause of the first is worth keeping: **its description carried
`compute_aggregations`' vocabulary**, not its own. Five words that were correct
somewhere else.

`verify_r24_shipped.sh` still passes 16/16 and all 26 endpoints negotiate, so
nothing regressed.

## `ocr` — investigated and CLOSED, not a defect (2026-09-06)

Round 25 reported `ocr` returning MCP error `-32001` while its output grew
912KB → 3.9MB, which reads like work completing behind a caller who was told it
failed. Chased three ways; the server is not at fault.

**An isolated single-phase round (26) did not reproduce it.** A focused axis --
"make each tool fail, then look at what it left behind", verdicts CLEAN /
ORPHAN / NO-FAIL -- ran phase 6 alone. The model produced its failures with a
non-existent source for all six tools and scored **6 CLEAN, 0 ORPHAN**. It
never went near the heavy path, which is the third time in two rounds that a
model has picked the branch the question was about and missed it.

**A deliberate client abort leaves nothing.** `ocr` on the 183-page filing with
a 10-second client timeout: `curl rc=28`, no response, and the output directory
empty — still empty 90 seconds later. A dropped client does not leave a partial
file.

**The code says why.** `_edit_optimize.py:205-245` renders and OCRs every page
into a `TemporaryDirectory`, and only after the whole loop succeeds does it
`original.save(destination)` — a single write at the end.
`subprocess.TimeoutExpired` is caught *before* that save and returns `fail`. A
server-side OCR timeout therefore writes nothing, and there is no partial file
to orphan.

**And it already bounds itself up front**, in the shape its siblings use
(`extract`: *"Bounded; refuses when too big"*). `_edit_optimize.py:172-183`
estimates `pages × ocr_seconds_per_page`, compares it to `max_ocr_seconds()`,
and refuses with the page range that would fit.

So what round 25 saw was a job the server **accepted, completed and wrote
correctly**, while opencode's own request timeout fired because the box was at
load average 12.95 on four cores — against ~4 seconds per page idle. The file
was complete because the work was complete. The caller was misled by its own
client, not by this tool.

**No fix made, deliberately.** The remaining gap is a mismatch between
`max_ocr_seconds()` and how long a particular client will wait, which is
environmental and belongs in deployment tuning, not in the tool.

## Provider notes

Three models and two quota walls for ten phases. `nemotron-3-ultra-free` ran
phases 4–14 then hit OpenCode Zen's daily cap — which, unlike OpenRouter's,
says so in the status bar (*"Free usage exceeded, subscribe to Go [retrying in
12h 52m]"*) and cost phases 15, 16 and 22. `muse-spark-1.3-contributor-free`
had recovered from its own cap 12 hours earlier and answered, then
`nvidia/nemotron-3-super-120b-a12b:free` on OpenRouter — whose daily quota had
reset overnight — finished all five remaining phases in 50 minutes with zero
rate limits.

**Each switch needs a new session, not new config**, and the sweep container's
accumulated context is itself a reason to restart: the session that ran round 24
held 45 phases of the *old* descriptions, and a model that has already read
"Page range required" is not the uninformed caller this round is testing.
