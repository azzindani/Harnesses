# Round 18 phase ledger — "do what the hint told you to do"

Written AS the round runs, per the standing rule (2026-08-28): record every
phase's outcome so round 19 re-runs only the phases that did not pass. Do not
reconstruct this from the reports afterwards — that was tried after round 16 and
the scanner got it wrong twice.

Plan `phases_r18.tsv`, 62 phases, reports `report_r18_*`.
Started 2026-08-28 13:21Z. Model `nvidia/nemotron-3-super-120b-a12b:free` via
OpenRouter with `FREE_FALLBACK=0`, so the routing is pinned and attributable.

## Verdicts

* **PASS** — completed, every hint it followed worked.
* **DEFECT** — completed and found something. DONE for coverage; goes on round
  19's re-run list once fixed.
* **SHORT** — did not exercise everything it named. Re-run regardless of fixes.

| ph | label | rows | verdict | tool | note |
|---|---|---|---|---|---|
| 1 | fs_write, part 1 | 7/8 | SHORT | — | one op never reported |
| 2 | fs_write, part 2 | 8/8 | PASS | | |
| 3 | fs_read + fs_query | 1/7 | SHORT | — | worst phase of the round; also fell short in r17 |
| 4 | fs_index/manage/archive | 4/8 | SHORT | — | |
| 5 | data-basic, part 1 | 3/3 | PASS | | |
| 6 | data-basic, part 2 | 2/3 | SHORT + DEFECT | `apply_patch` | hint lists the valid ops but not their parameters; obeying it gave a valid op called with `column` instead of `columns`, and the retry still failed. Needed `list_patch_ops` for the arguments. |
| 7 | data-basic, part 3 | 3/3 | PASS | | |
| 8 | data-ingest, part 1 | 4/4 | PASS | | |
| 9 | data-ingest, part 2 | 4/4 | PASS | | |
| 10 | data-ingest, part 3 | 2/2 | PASS | | |
| 11 | data-medium, part 1 | 4/4 | PASS | | |
| 12 | data-medium, part 2 | 4/4 | PASS | | |
| 13 | data-medium, part 3 | 3/3 | PASS | | |
| 14 | data-statistics, part 1 | 4/4 | PASS | | |
| 15 | data-statistics, part 2 | 1/4 | SHORT | — | |
| 16 | data-statistics, part 3 | 4/4 | PASS (dissolved) | `period_comparison` | reported failure is the model's own second mistake (a nonexistent date column); the hint was right about `period_unit`. Worth noting only that the tool reports one problem at a time. |
| 17 | data-transform, part 1 | 4/4 | **DEFECT** | `filter_dataset` | **CONFIRMED live.** Bad *column* → error names the column and lists the real ones; hint answers *"Valid filter ops: between, contains, …"*. The op was already valid. Obeying the hint changes the wrong thing and fails again. |
| 18 | data-transform, part 2 | 4/4 | PASS, but see below | `smart_impute`, `run_cleaning_pipeline` | both edited `Ad_Data.csv` **in place**; this is what set up the phase-26 stop |
| 19 | data-transform, part 3 | 2/2 | PASS (dissolved) | `enrich_with_geo` | model quoted a hint *"Use list_mcp_resources…"* that **does not exist** in the source or the fleet — fabricated. Real hint is *"Check geo_file_path is absolute."*, itself weak: the path given already was absolute. |
| 20 | data-visual, part 1 | 4/4 | PASS | | |
| 21 | data-visual, part 2 | 4/4 | PASS | | |
| 22 | data-visual, part 3 | 4/4 | PASS | | |
| 23 | data-workspace, part 1 | 3/3 | PASS | | |
| 24 | data-workspace, part 2 | 3/3 | **DEFECT** | `run_workspace_pipeline` | **CONFIRMED live.** Bad *pipeline* name → error names it and lists the real ones; hint says *"Use list_workspace_files() to check registered aliases."* That lists **files/aliases**, not pipelines, so it cannot contain the answer — and the error had already given it. |
| 25 | ml-basic, part 1 | 4/4 | PASS | | |
| 26 | ml-basic, part 2 | 4/4 | PASS | `restore_version` | see the stop, below |
| 27 | ml-basic, part 3 | 3/3 | PASS | | |
| 28 | ml-medium, part 1 | 4/4 | PASS | | |
| 29 | ml-medium, part 2 | 4/4 | PASS | | |
| 30 | ml-medium, part 3 | 4/4 | PASS | | |
| 31 | ml-advanced, part 1 | 4/4 | PASS | | |
| 32 | ml-advanced, part 2 | 4/4 | PASS | | |
| 33 | ml-advanced, part 3 | 2/2 | PASS | | |
| 34-38 | office-docx-basic/layout | full | PASS | | |
| 39 | office-docx-layout, part 2 | 2/3 | **SHORT** | — | `add_header_footer`, `export_pdf` never reported |
| 40-52 | docx-new/tables, pptx-*, xlsx-basic p1 | full | PASS | | one exception below |
| 51 | office-pptx-new, part 2 | 2/3 | PASS | | 2 rows but coverage confirms all 3 tools appear |
| 53 | office-xlsx-basic, part 2 | 4/4 | **DEFECT ×3** | `set_cell`, `set_range`, `insert_row` | **CONFIRMED live.** See below — the round's most serious finding. |
| 54 | office-xlsx-basic, part 3 | 4/4 | DEFECT (same cause) | | same undo hint |
| 49 | office-pptx-design, part 2 | 4/4 | DEFECT (same cause) | | same undo hint |
| 55-56 | office-xlsx-basic p4, charts p1 | full | PASS | | |
| 57-62 | xlsx-charts p2 … xlsx-new p2 | full | PASS | | **run on Muse Spark**, not nemotron — see the model switch |

## The stop at phase 26

`FIXTURE MUTATED — STOPPING`. The guard did its job; the round lost ~20 hours
sitting idle because nothing was watching for it.

The chain, reconstructed from snapshot checksums:

1. Phase 18, 15:19:36Z — `smart_impute` was given `Ad_Data.csv` (the model
   obeyed *"check file_path is absolute and the file exists"* by reaching for
   the obvious existing file) and edited it **in place**, snapshotting the
   pristine bytes first. `run_cleaning_pipeline` wrote again at 15:19:50,
   snapshotting the **already-modified** file.
2. The file was returned to pristine before the phase ended, so the guard passed
   on phases 18-25.
3. Phase 26 — `restore_version` was called with a bad timestamp. The hint
   listed the available timestamps **newest first**; the model picked the
   newest, which was the snapshot of the *modified* file, and restored it.
   16,835 rows instead of 16,834.

Nothing here is a tool misbehaving: every step did what it said. But it is a
real property of the fleet worth keeping — **obeying a good hint restored a
protected dataset to a stale state**, and no tool in the chain warned that the
file it was about to overwrite in place was the shared fixture.

Fixture restored from `/root/Harnesses/project/Ad_Data.csv`, md5 back to
`9a16b924…`; the mutated copy is kept in the session scratchpad.

## The round's most serious finding: a hint that recommends data loss

`set_cell(cell_address="A0")` on office-xlsx-basic. Reproduced live:

    error: Row numbers must be between 1 and 1048576. Row number supplied was 0
    hint : Use restore_version to undo if a snapshot was taken.

**Nothing was written.** The call was rejected on argument validation before the
file was touched. The hint tells the caller to perform a *destructive rollback* —
and a caller who obeys it discards unrelated legitimate work. The sweep model
obeyed it three times in a row (`set_cell`, `set_range`, `insert_row`), and all
three retries failed, because restoring a snapshot cannot fix a bad argument.

Cause is known and is a choke point, not a call site: `hint_for_error()` in
`shared/shared/file_utils.py` ends with

    return "Use restore_version to undo if a snapshot was taken."

as its final fallback, reached by any exception that is not PermissionError,
FileNotFoundError, or a `.mcp_versions` path. A `ValueError` from cell-address
validation lands squarely there. **70 call sites across 8 Office servers** route
through that function, plus 8 literal copies of the same sentence; the hint
turned up in three different reports on two different servers.

The fix has a precedent in the same file: `hint_for_message()` (`e7ec243`) picks
the hint from the message actually being returned instead of from the call site's
default. `hint_for_error` needs the same treatment — and specifically must not
advise an undo for an error raised before any write.

## The pattern behind all the confirmed defects

`filter_dataset` and `run_workspace_pipeline` fail the same way: **one hint per
tool, written for its commonest failure and then returned for every error branch
the try block can raise.** So the error is specific and correct, and the hint
beside it answers a different question — ops for a column error, aliases for a
pipeline error. A caller acts on the hint, so it changes the wrong thing and
fails again, which is exactly what the sweep model did both times.

This is the same shape Office fixed in `e7ec243` with `hint_for_message()`:
pick the hint from the message actually being returned rather than from the call
site's default. Data_Analyst has no equivalent. Likely a choke-point fix rather
than a per-site one — the same lesson as round 17's two half-fixes.

All three confirmed defects are the same bug in three repos' worth of code:
**the error is computed from what went wrong, the hint is a constant.** The more
specific the errors get, the more visibly the hint contradicts them.

Whole-fleet check worth doing before round 19: for every tool, does the error
identify a *kind* of thing (column / op / sheet / pipeline / cell address) that
the hint then fails to talk about? And separately: does any hint recommend a
write or a rollback for an error raised before anything was written?

## Round 19 re-run list — FINAL

**SHORT — re-run regardless of any fix.** `check_coverage.py` is the authority
here, not the driver's row count: phases 1, 3, 4 and 15 have low row counts but
every tool they named appears in their report (filesystem ops share rows, the
same trap as round 17's phase 2). Only two phases actually left a tool untested:

| phase | untested |
|---|---|
| 6 | `search_columns` |
| 39 | `add_header_footer`, `export_pdf` |

**DEFECT — re-run once the fix is deployed.**

| phase | tool | fix |
|---|---|---|
| 17 | `filter_dataset` | hint must address the column error |
| 24 | `run_workspace_pipeline` | hint must address the pipeline error |
| 49, 53, 54 | `set_cell`, `set_range`, `insert_row`, pptx-design | `hint_for_error` fallback |
| 6 | `apply_patch` | candidate: op list without parameters |

## The model switch, mid-round

Phases 1-56 ran on `nvidia/nemotron-3-super-120b-a12b:free` (OpenRouter).
That free tier hit its quota at 04:08Z and the driver's provider probe refused
to start the round rather than write six empty reports. Phases **57-62 ran on
`opencode/muse-spark-1.2-contributor-free`** — opencode's own provider, no API
key, no proxy in the path.

Worth remembering when reading those six reports: a hint verdict is a judgement,
and the last six phases were judged by a different model. They came back clean
and also ran roughly twice as fast (~3.5 min/phase against 5-10).

## Running totals — ROUND COMPLETE

- phases: **62 / 62**, every phase wrote a report
- tools named 230, rows written 216; only 2 phases left a tool untested
- **confirmed defects: 3** (`filter_dataset`, `run_workspace_pipeline`, and the
  `hint_for_error` undo fallback affecting at least 4 tools across 2 servers)
- 1 candidate (`apply_patch`)
- dissolved: 2
- all 7 ML phases clean — every hint followed worked, in the whole repo
