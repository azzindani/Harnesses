# Round 27 — the frontier caller

Every previous round put a small, uninformed model in a container and asked it
to probe. This one has no container and no probe list: **I am the tool user**,
calling the deployed endpoints directly, running one real task end to end and
recording what it cost as it happens.

The point is not to repeat rounds 24–25. A competent caller routes *around* a
bad description instead of tripping on it, so the description axis is spent.
What a frontier caller can reach that no probe could:

* whether one tool's output is actually a valid input to the next
* whether the Level-3 composability gap (only Data_Analyst has `customize_*`)
  bites in practice or only on paper
* what verification actually costs when the caller is competent
* whether the Level-4 honesty claims survive a real task rather than a probe

**Dataset:** `Ad_Data.csv`, 16,834 × 16, reset to pristine
(`9a16b9248526466960194df4eb7a3e90`) with the exchange dir wiped to fixtures.

**Task:** a marketing performance review a human would actually ask for —
*"Which platform and audience actually earns the spend, what's wrong with the
data, and can we predict clicks?"* — delivered as charts, a spreadsheet and a
written report. No folio.

**Rule:** the task comes first. Findings are what the task runs into, not what
I go looking for. Nothing is dressed up: if a step is clean, it is recorded
clean.

---

## Ledger

| # | step | endpoint · tool | outcome |
|---|---|---|---|
| 1 | load the file | data-basic · `load_dataset` | **clean** — 16,834×16, dtypes, nulls, uniques, sample and a next-step hint in one 3.3KB call. `counted_from_sample: false` is an honest count, unasked. |
| 2 | quality gate | data-statistics · `validate_dataset` | **clean** — score 89, six issues, every figure matching the corpus record (546 nulls, 205 dups, 24.38/26.91/89.71% zeros). Carries `token_estimate`. |
| 3 | spend by platform | data-transform · `aggregate_dataset` groupby | **finding 1** — see below. Numbers correct (Google 1,939,003.26 / Facebook 564,115.51). |
| 4 | device split | data-transform · `aggregate_dataset` crosstab | **clean, and the error taught** — `group_by` refused with *"mode='crosstab' reads: col_col, normalize, row_col, values_col"*. Retried right first time. Confirms the corpus's known corruption: all 1,733 Facebook rows carry `device="device"`. |

---

## Finding 1 — an invented argument is accepted in silence, everywhere but one repo

Calling as a competent user rather than a schema-reader, I wrote `agg_column`
and `agg_func` from habit. Neither is a parameter of `aggregate_dataset`; the
real one is `agg`, and it takes a dict.

| call | result |
|---|---|
| `agg_func: "mean"` (invented) | `success: true` — **sums returned** |
| `agg_column: "clicks"` (invented) | `success: true` — byte-identical output |
| `banana: "yes"` (nonsense) | `success: true` — byte-identical output |
| `agg: "mean"` (real name, wrong type) | refused: *"Input should be a valid dictionary (got str)… Nothing was written."* |
| `group_by` in `mode=crosstab` (real name, wrong mode) | refused, naming the four args that mode reads |
| `agg: {"spends":"mean"}` (correct) | works — 325.51 vs 128.40 |

So the server checks argument **type** and argument **mode-scope**, both
precisely — and never checks whether the argument exists. The one missing layer
is the only one that changes a number without saying so: I asked for a mean,
was told `success: true`, and got a sum.

**It is not fleet-wide, and that is what makes it fixable.** Same invented-arg
probe on four more endpoints:

    data-transform  aggregate_dataset  banana / agg_func   -> success: true
    data-statistics validate_dataset   strictness          -> success: true
    data-basic      inspect_dataset    depth               -> success: true
    math            calculate          precision_mode      -> success: true
    filesystem      fs_read            encoding_hint       -> REFUSED:
                                       "fs_read does not take encoding_hint"

**File_System already solved it.** This is the `dayfirst` shape again — one
repo holding the correct handling of a contract the others drifted from — and
the fix is to propagate `fs_read`'s check, not to invent one.

Why no probe round found it: a small model copies argument names out of the
schema it was just shown. Inventing a plausible wrong name is a competent
caller's error, and it is the caller most likely to trust `success: true`.

---

| # | step | endpoint · tool | outcome |
|---|---|---|---|
| 5 | derive CTR and CPC | data-transform · `feature_engineering` | **friction, then clean** — five calls to find the `derive` grammar. See finding 2. |
| 6 | read the new columns | data-basic · `read_column_stats` | **finding 3** |
| 7 | deep stats on `ctr` | data-statistics · `extended_stats` | **finding 4** — the serious one |

## Finding 2 — `derive`'s grammar costs five round trips, one key at a time

`feature_engineering`'s schema types `derive` as `array[object]` with
`additionalProperties: true`, so the inner shape is undiscoverable. Each error
is individually excellent and teaches exactly one key:

    1. {name, expr}                     -> "has op=''. Valid ops: arith, compare, date_part, parse_date, text"
    2. {name, op, column, operator,
        other_column}                   -> "needs a 'how' key. Its keys are: name, op, column, operator, other_column"
    3. + how="divide"                   -> "has how='divide'. Valid: add, div, floordiv, mod, mul, sub"
    4. + how="div", other_column=...    -> "needs either 'other' (a column name) or 'value' (a literal)"
    5. + other="impressions"            -> success

Not a defect — nothing lied, and I got there. But error 2 echoes *my* keys back
(`Its keys are: …other_column`), which reads as confirmation that
`other_column` was right when the real key is `other`; that is what made step 4
necessary. And errors 1 and 3 enumerate their vocabulary while 2 does not.

**The fix already exists next door.** `data-basic` ships `list_patch_ops` —
*"List apply_patch ops. Omit category to get all, grouped by category"* —
exactly this problem solved for `apply_patch`'s grammar. `derive` has no
equivalent. One `list_derive_ops`, or the spec in the docstring, turns five
calls into one.

## Finding 3 — a statistic that is `null` for three different reasons

`ctr = clicks / impressions` on the 4 rows where `impressions = 0` yields `inf`.
`read_column_stats` then returns:

    count: 16834   null_count: 0   zero_count: 4530
    mean: null     std: null       max: null
    median: 0.125  min: 0.0        q1: 0.0    q3: 0.2571

A complete column — `null_count: 0`, every row counted — with three statistics
returned as `null` and **no field anywhere saying why**. `inf` is not null, so
`null_count` is right; there is no `inf_count`. For `ctr` the four infinities
are too rare to reach `top_values`, so the response contains no trace of them
at all. The true finite mean is 0.184974.

`null` here means "the value is infinite", but a caller cannot distinguish that
from "not computed", "not applicable", or "empty column". The fleet already
reports `returned/total/truncated`, `counted_from_sample` and `was_sampled`
without being asked; this is the same contract, unhonoured.

Note the asymmetry inside one repo: `validate_dataset` flags *"impressions: 4
zeros (0.02%)"* as a warning. The zero is reported. The infinity it causes is
not.

## Finding 4 — 4 rows in 16,834 flip a normality verdict, with an impossible p-value

`extended_stats` on the same column nulls **eleven** figures — mean, std,
variance, max, range, cv, skewness, skewness_label, kurtosis, kurtosis_label
and both confidence bounds — and then states positively:

    "distribution_hint": "likely normal (Shapiro p>1.00)"

A p-value cannot exceed 1. And the claim is the reverse of the truth: `ctr` is
zero-inflated (4,530 zeros) and right-skewed (finite skew 2.21).

**Mechanism, confirmed through the shipped code path** —
`shared/small_sample.py:197`:

    array = array[~np.isnan(array)]     # strips NaN, keeps inf

`np.isnan` where `np.isfinite` was meant. scipy's `shapiro` does not raise on
`inf`; it returns `W=nan, p=1.0`. The helper's `finite(p)` guard passes 1.0
through, and `1.0 > 0.05` prints "likely normal".

    shapiro_p() as shipped, on ctr     -> p = 1.0        -> "likely normal"
    shapiro_p() with inf dropped first -> p = 5.359e-65  -> "non-normal"

The docstring says it *"Guards the two ways this goes wrong"* — too few values,
and a degenerate sample returning NaN. There is a third, and it is the one that
produces a confident false statement rather than a `None`.

**Three callers, and the third is the worst:**

| caller | what it reports |
|---|---|
| `_med_inspect.py:1368` | `extended_stats` distribution hint (observed above) |
| `_med_analysis.py:299` | distribution shape in the analysis path |
| `_stats_regression.py:428` | residual normality in `regression_analysis` — **different failure, checked below** |

I predicted the third would also answer "normal". It does not; I called it and
it took the other branch. `regression_analysis(y_col="ctr")` returns:

    "normality_of_residuals": {
      "status": "undetermined: Shapiro-Wilk needs at least 3 residuals, this fit has 16834"
    }

A sentence that contradicts itself in nine words. The residuals are all NaN, so
the `~np.isnan` strip empties the array, `size < 3` returns `None`, and the
`None` branch's message assumes the only possible cause is too few values — then
prints the *pre-strip* count. Same root, milder symptom: not a false claim, but
a reason that cannot be true.

**What that call gets right, and it is worth as much as the finding:** every
coefficient, `r_squared`, `rmse`, `f_statistic`, `aic` and `bic` came back
`null`, `equation` read `"ctr = None"` — and the response led with

    "insight": "No predictor could be tested: 2 coefficient(s) came back without a p-value."

That is the honest contract working. A caller cannot miss it. `success: true`
on an empty fit is still arguable, but nothing here is hidden.

**Contrast that with finding 4's `extended_stats`, which is the whole point:**
same repo, same root cause, same non-finite input — one tool says plainly that
it could compute nothing, and the other says the distribution is likely normal.

---

| # | step | endpoint · tool | outcome |
|---|---|---|---|
| 8 | platform × audience | data-transform · `aggregate_dataset` | **clean** — `agg` dict honoured, honest `returned/total/truncated`. Real result: Facebook Audience 3 has the best CTR *and* the lowest CPC on 0.8% of the budget. |
| 9 | cross-check the rates | math · `calculate` ×8 | **clean** — all eight agree with the aggregation. |
| 10 | monthly trend | data-statistics · `time_series_analysis` | **exemplary** — see below. |
| 11 | model clicks | ml-basic · `train_regressor` | **finding 5** — r²=0.983 on a leaking feature, `leakage_warning: ""` |
| 12 | drop the leak | ml-basic · `train_regressor` | **finding 6** — `feature_columns` silently ignored; identical metrics |
| 13 | drop it cross-tool | data-basic · `apply_patch` | **finding 7 — the destructive one** |
| 14 | recover | data-basic · `restore_version` | **exemplary** — see below |

### Step 10, recorded as a positive because it is the standard

`time_series_analysis` refused to decompose a 10-period series and said exactly
why, unprompted:

    "stl_skipped": { "spends": { "reason": "the series resamples to 10 period(s);
      STL needs 24 (two full cycles of 12)", "periods_available": 10,
      "periods_needed": 24, "seasonal_cycle": 12 } }
    "hint": "...an empty 'stl' does NOT mean the series has no seasonality --
      see stl_skipped. Re-run with period='D'..."

It anticipated the wrong inference, named it, and gave the fix. This is what
findings 3, 4 and 5 are all missing, in the same repo.

## Finding 5 — the leakage check is inert on a regression target, and says nothing

Target `clicks`, model `rfr`, all 15 remaining columns as features, **r² =
0.983**. `link_clicks` is among them, and `link_clicks ≤ clicks` in **100.0%**
of the 16,288 rows that have it (r = 0.9256) — a link click *is* a click. This
is the credit-risk review's own defect, in a different dataset.

The manifest carries `"leakage_warning": ""`.

**Why it is empty.** `shared/leakage.py` builds all three of its evidence
signals on a binary label: rank AUC (`_binary_auc`), a missingness-vs-class gap,
and a post-outcome name regex. `_as_binary` returns `None` unless the target has
exactly 2 distinct values — `clicks` has 263 — so both measured signals are
skipped and only the name hint can fire. That regex is credit vocabulary
(`total_payment`, `chargeoff`, `recovery`, `settlement`…); `link_clicks` cannot
match it.

So for **any** continuous target the check reduces to a word list that no ad,
traffic, or revenue column will ever hit. The module's docstring is honest that
it was built from the loan review — it never claims regression coverage. The
defect is not the gap, it is that `""` is indistinguishable from *"checked, and
found nothing"*. Same shape as finding 3: one empty value standing for two
different facts.

## Finding 6 — `feature_columns` is ignored, and no parameter can replace it

Having spotted the leak, I did the obvious thing and re-trained without it:

    train_regressor(target_column="clicks", model="rfr",
                    feature_columns=[...nine columns, link_clicks excluded...])
    -> mse 32.9186   rmse 5.7375   r2 0.983     <- identical, to four decimals

Identical because `feature_columns` is not a parameter. `train_regressor`
accepts `file_path, target_column, model, degree, alpha, n_estimators,
test_size, random_state, dry_run, output_path` — **there is no way to choose or
exclude features.** It always trains on every column but the target.

Chained with finding 5 this is the whole failure: the check that should find the
leak cannot see it, and the caller who finds it anyway cannot act on it — and is
told `success: true` with the same leaky model.

The user review asked for exactly this: *"agent must not ship without time-split
+ drop of id/member_id/total_payment."* Detection shipped for classification.
**The drop was never expressible.**

## Finding 7 — `output_path` discarded, source file overwritten, `success: true`

The cross-tool route to dropping a column. I wrote the careful call — patch the
data, put the result somewhere else, leave the original alone:

    apply_patch(file_path="/workspace/data/Ad_Data.csv",
                ops=[{"op":"drop_column","columns":["link_clicks"]}],
                output_path="/workspace/data/ad_noleak.csv")

    -> success: true
       "file_path": "/workspace/data/Ad_Data.csv"
       "changed_file": true
       progress: "Saved Ad_Data.csv"

`ad_noleak.csv` was never created. **`Ad_Data.csv` itself lost the column** —
16 columns to 15, md5 `9a16b924…` → `bfa5f7e5…`. `apply_patch` takes only
`file_path, ops, dry_run`; `output_path` is not a parameter, so finding 1
discarded it in silence.

In-place mutation is `apply_patch`'s design and is not the defect. The defect is
that an explicit instruction to write elsewhere was dropped without a word, and
the tool that did it is the one that edits data. **Finding 1 is not a
tidiness problem; this is what it costs.**

**Two things stopped it being worse, and both deserve the record.** The op
grammar *is* validated strictly, one level below where the check is missing:

    ops=[{"op":"drop_column","column":"link_clicks"}]
    -> "Op 0 (drop_column): unknown field(s) column -- did you mean columns?
        drop_column accepts: columns, op, params"

A did-you-mean, inside the same server whose top-level arguments accept
`banana`. The fix is already written; it is applied to the wrong layer.

And the safety net held completely. `apply_patch` snapshotted before writing and
said so; `restore_version` put the file back to `9a16b924…` on one call, named
the snapshot it used, **took a counter-snapshot first so the restore is itself
reversible**, and warned that it had picked the newest because I gave no
timestamp. Nothing was lost.

---

| # | step | endpoint · tool | outcome |
|---|---|---|---|
| 15 | copy the file | filesystem · `fs_write` | **clean, and the counterexample again** — refused `action, path, target` by name, then taught the op grammar (`copy accepts: dst, op, path, src`) |
| 16 | drop leak on the copy, retrain | data-basic + ml-basic | **clean** — honest model r² 0.9643, RMSE 8.32 |
| 17 | Excel export | data-visual · `export_data` | **exemplary** — see below |
| 18 | dashboard from a spec | data-visual · `generate_dashboard` | **clean** — spec honoured, resolved spec returned |
| 19 | round-trip the dashboard | data-visual · `customize_dashboard` | **exemplary** — see below |
| 20 | write the report | office-docx-new · `create_from_blocks` | **clean output, finding 8 in the response** |
| 21 | read the report back | office-docx-basic · `get_document_outline` | **clean** — cross-repo round trip, 6 headings, 22 paragraphs |

### Steps 17 and 19, recorded as positives because they answer the review directly

`export_data` delivered the credit-risk review's PART II §2 ask whole, unasked:

    "sheets": ["README", "Data"], frozen_header: true, autofilter: true,
    formatted_columns: [spends, impressions, clicks],
    validated_columns: [campaign_platform, audience_type],
    rows_total: 4, rows_written: 4, is_preview: false,
    lineage_path: "…/Ad_Performance_Summary.xlsx.mcp_lineage.json"

`customize_dashboard` completed the round trip PART III asked for. I passed a
spec to `generate_dashboard`; the resolved spec came back in the response *and*
was embedded in the HTML; `customize_dashboard` then read it back out of the
file, applied `{title, theme}`, and re-rendered — **without me re-supplying the
data path, the layout or the KPIs.** `get_spec → patch_spec → re-render` works.

That is Level 3 composability, shipped and working, and I understated it two
turns ago.

## Finding 8 — three Office servers claim to have opened a file that nothing opened

Every document written by `docx_new`, `pptx_new` and `xlsx_new` returns:

    {"status": "ok", "message": "Opened Ad_Spend_Efficiency_Review.docx in default app"}

There is no default app. This is a headless container. The claim is
unconditional — `servers/docx_new/docx_new/engine.py:72`:

    def _open_if_requested(path, open_after, progress):
        if open_after:
            open_file(path)
            progress.append(ok(f"Opened {path.name} in default app"))

and `shared/platform_utils.py:195` is documented *"Open file in the default
system application. **Silently ignored on failure.**"* — it returns `None`
whether it worked or not, so the success line is appended regardless.
`open_after` defaults to `True`, so this is on every write.

Nothing breaks; the document is correct. It matters because of what it does to
an earlier decision: `open_after` was reviewed on 2026-09-05 and closed as **not
a defect**, on the stated grounds that *"no response field ever claims it
opened."* A `progress` entry with `status: ok` is a response field, and it does.
The conclusion may still be right — the fix is one line, gate the message on a
return value — but **the reason recorded for it is not true**, and that is worth
more than the bug.

---

## What the round says

**Eight findings in 76 calls**, one task, no probing. Ranked by what they cost a
caller:

| | finding | severity |
|---|---|---|
| 7 | `output_path` discarded → source file overwritten, `success: true` | **high** — data loss, recovered only because snapshots exist |
| 6 | `feature_columns` ignored; no way to exclude a feature from training | **high** — the leak cannot be dropped |
| 4 | 4 rows in 16,834 turn "non-normal, p=5e-65" into "likely normal (p>1.00)" | **high** — a confident false statement |
| 1 | unknown arguments accepted in silence across 4 repos | **high** — the root of 6 and 7 |
| 5 | leakage check structurally inert on regression targets, reports `""` | medium |
| 3 | `null` statistics with no `inf_count` and no reason | medium |
| 8 | three Office servers claim a file was opened that was not | low |
| 2 | `derive` grammar costs five round trips | friction |

**Findings 1, 6 and 7 are one defect wearing three faces.** No layer anywhere
asks *"is this argument real?"* — so an invented name is discarded, and whether
that is harmless (`banana`), merely wrong (`feature_columns`, which left a
leaking model in place) or destructive (`output_path`, which overwrote the
corpus) is decided by luck.

**And the fix is already written, three times over, inside the same fleet:**

    filesystem  fs_read      -> "fs_read does not take encoding_hint"
    filesystem  fs_write     -> "fs_write does not take action, path, target.
                                 fs_write accepts: dry_run, ops."
    data-basic  apply_patch  -> "Op 0 (drop_column): unknown field(s) column --
                                 did you mean columns?"

The third is the sharpest: **the same server that silently swallowed
`output_path` at the top level rejects an unknown field one level down, with a
did-you-mean.** The check exists in the codebase. It is applied to the nested op
grammar and not to the tool signature.

## What this round could reach that rounds 24–25 could not

Every finding here came from *doing the task*, and none would have been found by
probing:

* A probe copies argument names from the schema. **I invented them from habit** —
  `agg_column`, `agg_func`, `feature_columns`, `output_path`, `target_column`,
  `action/path/target` — which is what a competent caller does, and is the only
  way finding 1 surfaces.
* A probe does not build a ratio, so it never divides by zero, so `inf` never
  enters a column and findings 3 and 4 stay invisible.
* A probe does not *notice a leak and try to fix it*, which is the exact
  sequence that produced findings 5, 6 and 7 in three consecutive calls.
* Nothing here required a bad description. Every description I relied on was
  true. Rounds 24–25 really are spent.

**The counter-lesson, which holds for the third round running:** a competent
caller is the wrong instrument for anything a probe already covers. I read
`fs_write`'s refusal, corrected, and moved on in two calls — a probe would have
recorded a defect where there was none. The two methods find disjoint sets, and
this one costs one session instead of nine hours of container time.

---

# The fixes

## Finding 1 — the root, and why it went missing

Not drift. **A migration.** Every repo moved to the official `mcp` SDK, whose
bundled FastMCP builds each tool's argument model with pydantic's default
`extra="ignore"`. The fleet previously ran standalone fastmcp 2.x, which
refuses extra arguments outright — so the check was there, for free, and the
migration removed it in every repo that had not written its own.

Two had. File_System and Office each wrote `shared/strict_args.py` for their own
reasons and kept it. Office's copy still carries the evidence table from when it
was written:

    ml-basic            list_models          refused
    data-basic          list_patch_ops       refused

Both refuse no longer. And this repo's `shared/arg_errors.py` — the guard for
argument *types* — names `enforce_known_arguments` in its own docstring and was
built assuming the name guard was installed beside it. It was not.

`shared/strict_args.py` is now byte-identical in all five repos that lacked it,
wired into all fourteen live servers, installed last so it wraps the other
guards and answers first:

| repo | servers wired |
|---|---|
| MCP_Data_Analyst | 7 (basic, ingest, medium, statistics, transform, visual, workspace) |
| MCP_Machine_Learning | 3 (basic, medium, advanced) |
| MCP_Documents | 2 (read, edit) |
| MCP_Math | 1 |
| MCP_Web_Browser | 1 |

`data_advanced` has zero tools and `data_project` is a redirect to the wired
`data_workspace`; both correctly skipped.

### A second hole, found by the test rather than by the round

The shipped guard read `if unknown and known:` — so a tool whose parameter list
is *empty* fell straight through and accepted anything. `browse_datetime` and
`browse_status` take no arguments; every argument sent to them was ignored in
silence, on the two repos that had the guard all along as well as the five
getting it now.

    if unknown and "properties" in schema:

An explicit `properties: {}` is a tool that takes nothing, which is a fact worth
enforcing. A *missing* `properties` is a schema that cannot be read, and there
the original caution is right. Fixed in all seven copies, File_System and Office
included.

## Findings 6 and 7 — what the root fix does and does not settle

**7 is closed by 1.** `apply_patch` now refuses `output_path` by name instead of
discarding it and editing the source. Its description says so too — *"Apply
ordered ops to a CSV in place, snapshot first"* — because the tool genuinely has
no output path, and a caller should learn that from the sentence rather than
from a lost column.

**6 needed its own fix**, and the root fix alone would have made it *worse*: a
refusal instead of silence, but still no way to drop a leaking feature.
`shared/feature_select.py` adds `feature_columns` and `exclude_columns` to all
four trainers — `train_classifier`, `train_regressor`, `train_with_cv`,
`compare_models`. Either name, never both; an unknown column is refused with the
file's real ones; excluding everything is refused; and a narrowed set is
confirmed in `progress`, because a silently ignored narrowing looked exactly
like a successful one.

## Findings 3 and 4 — infinities

`shared/small_sample.py:197` stripped NaN with `~np.isnan`, which keeps `inf`.
One character of intent, `np.isfinite`, and the false verdict goes away:

    shapiro_p as shipped   -> p = 1.0        -> "likely normal (Shapiro p>1.00)"
    shapiro_p fixed        -> p = 5.359e-65  -> "non-normal"

`finite_split()` is new beside it, so the three callers can say *which* reason
applies. The regression diagnostic no longer prints "needs at least 3 residuals,
this fit has 16834"; it names the finite count and, when non-finite values are
what emptied the sample, says so.

`read_column_stats` and `extended_stats` now carry `non_finite_count` and a
`not_computed` sentence whenever it is non-zero. `null` stops meaning three
different things.

> The helper was first called `testable_sample`. pytest collects anything
> matching `test*`, so it was picked up as a test function and errored on a
> missing fixture. Renamed to `finite_split`.

## Finding 5 — leakage on a continuous target

Two gaps, not one. `ml_basic` ran only `leakage_warning` — the 0.999
exact-determination check that `shared/leakage.py` exists to supersede — and
never `leakage_suspects`, which had been in `ml_medium` since the credit-risk
review. Both trainers now run both.

And `leakage_suspects` measured nothing on a continuous target: rank AUC and the
missingness gap are two-class statistics, so only the post-outcome name regex
could fire, and that regex is credit vocabulary. Two continuous signals added:

* `component_of_target` — the feature lies between 0 and the target in ≥99% of
  rows and moves with it. This is what `link_clicks` is.
* `alone_predicts_target` — rank correlation ≥ 0.98, a monotone transform of
  the answer.

**Both thresholds were calibrated against the real file, and the first draft had
both wrong.** At Spearman ≥ 0.90 — mirroring `SINGLE_FEATURE_AUC` — it flagged
`spends` (rho 0.923), an honest causal predictor of clicks, and missed
`link_clicks` entirely, because 89.7% zeros crush its Spearman to 0.261 while
its Pearson is 0.926. So the correlation gate takes the larger of the two, and
the single-feature threshold moved to 0.98. Measured result:

    leaky file  -> link_clicks, component_of_target, high confidence
    clean file  -> nothing
    spends, impressions -> never flagged

## Findings 2 and 8

`derive`'s errors now carry the whole grammar for the op instead of the single
next missing key, and stop echoing the caller's own keys back as though they
were right. Five round trips become two. `list_derive_ops` joins `list_patch_ops`
as the discovery tool for the repo's other nested grammar — **fleet tool count
243 → 244.**

`open_file` returns whether a handler actually started; thirteen call sites
across `docx_new`, `pptx_new` and `xlsx_new` gate their "Opened … in default
app" claim on it. The decision to keep `open_after` defaulting to True stands —
only the false claim is gone.

## Tests

| repo | file | tests |
|---|---|---|
| MCP_Data_Analyst | `test_the_argument_that_was_never_read.py` | 27 |
| MCP_Machine_Learning | `test_a_leak_you_could_not_drop.py` | 23 |
| MCP_Machine_Learning | `test_an_undeclared_argument_is_refused.py` | 6 |
| MCP_Microsoft_Office | `test_a_file_that_was_never_opened.py` | 10 |
| MCP_Documents | `test_an_undeclared_argument_is_refused.py` | 7 |
| MCP_Math | `test_an_undeclared_argument_is_refused.py` | 6 |
| MCP_Web_Browser | `test_an_undeclared_argument_is_refused.py` | 5 |

Three of these tests failed first and were right to: the zero-parameter hole
above, `probe` taking `source` rather than `file_path` (the guard caught the
same class of guess that started this round), and an over-broad static check
that flagged "Opened template base.docx" — a true sentence about reading a file.

The ML leakage tests run against the committed 16,834-row `ad_data_full.csv`,
not a synthetic frame. A synthetic one is what got the thresholds wrong: built
as `spends = clicks * 3 + noise` it correlates at 0.999, a property of the
generator rather than of advertising.


