# Round 24 ledger — "believe the description"

**Seven repos, 243 tools from `tools/list` on 26 live endpoints, 45 phases.**
Driver: the opencode harness in its own throwaway container (`harness-sweep`,
uninformed model), OpenRouter -> `nvidia/nemotron-3-super-120b-a12b:free`.
Plan `phases_r24.tsv`, axis `AXES[24]`, reports `report_r24_*.md` in
`/root/Harnesses/data`.

**Why this axis.** An MCP client sees one sentence per tool and nothing else.
In this fleet that sentence is the docstring, and a CI check caps it at 80
characters — exactly the pressure that makes a description over-promise.
Round 23b's best defect was found by reading one: `query_select` says
*"SELECT-only SQL (parameterless). Bounded."* and enforces it by testing
whether the string starts with `select` or `with`, so
`WITH x AS (SELECT 1) DELETE FROM pages` walks past the guard and empties the
table under `ok: true`. Nothing in CI can see this class — CI asserts what the
code does and never that the sentence above it is true — and it needs no ground
truth, because every tool ships its own oracle.

**Both directions are in scope**, and the second is the one no round has ever
asked: not only *is the claim false*, but *what does the tool do that its
description never mentions* — a second file, a backup, a chart nobody asked
for, a modified input. Verdicts are HELD / BROKEN / VAGUE; VAGUE is a real
result, because a description that cannot be tested cannot be relied on.

**Fuel, measured not assumed.** `descriptions_r24.tsv` holds all 243
descriptions as the servers report them, and 39 of them carry an explicit
limiting word: *Bounded always*, *SELECT-only*, *Returns names only, no data*,
*content is literal unless regex=True*, *preserving run formatting*,
*Permanently remove … then verify*, *Max 50 paragraphs*. That file is also the
grading key: a row that paraphrases its tool's description instead of quoting
it can be caught against it.

**The two meta-lessons this round is answering.** Round 23 and 23b produced
five defects and *all five came from reading responses and source, not from the
axis* — so this round makes reading the instrument rather than the accident.
And round 23's axis "was applied thinly": tools were exercised, the axis
mostly was not. Here the axis IS the call, so a row with no quoted description
is visibly not axis work.

**Fixtures, staged fresh and verified before the round.**

| file | md5 | what it is for |
|---|---|---|
| `Ad_Data.csv` | `9a16b9248526466960194df4eb7a3e90` | the designated tabular set, 16,834 rows, restored pristine |
| `BBCA_filing.pdf` | `e7ca79e6b91037cff193c89c7bd38849` | the 183-page IDX filing, committed to MCP_Documents so the private corpus is still only referenced |
| `BBCA_instance.zip` | `63297e12d6725aa55ba57a44629727eb` | **new this round** — an archive, not a document, so "identify a document" has a container to answer about |

`/root/Harnesses/data` was wiped to those three plus `.gitkeep` (221 entries,
920 MB); round 23's 76 reports are in `archive/reports_r23.tar.gz` first.

**Carried in, and already settled without a model.** The user-review fixes
shipped 2026-09-05 — discriminated chart filenames, `calibration` in the split
manifest, an `image` in `create_from_sections`, leakage suspects across
`run_eda` / `check_data_quality` / `evaluate_model` — are asserted by
`verify_r24_fixes.sh`, **26/26 PASS on the live fleet before launch**. A model
picking its own inputs picks the branch the fix did not change (4-for-4 in one
round), so the sweep's job on those tools is finding what the fix broke
*elsewhere*, not confirming the fix.

Fill in `verdict` as the round runs: **PASS** / **DEFECT ×n** / **UNFINISHED**
(rows written < tools) / **DRY** (no report). Re-runs take the unpassed only.
`ledger_update.py` writes only the `rows` and `verdict` cells and never
overwrites a verdict a person typed.

| phase | label | report | tools | rows | verdict |
|---|---|---|---:|---|---|
| 1 | filesystem: fs_write, part 1 | `report_r24b_fs_write_1.md` | 8 | 8 | PASS |
| 2 | filesystem: fs_write, part 2 | `report_r24b_fs_write_2.md` | 8 | 8 | PASS |
| 3 | filesystem: fs_read modes and fs_query | `report_r24b_fs_read.md` | 7 | 7 | PASS |
| 4 | filesystem: fs_index, fs_manage, fs_archive | `report_r24b_fs_actions.md` | 8 | 14 | PASS |
| 5 | docs-read | `report_r24_docs_read.md` | 7 | 7 | PASS |
| 6 | docs-edit | `report_r24_docs_edit.md` | 6 | 6 | PASS |
| 7 | data-basic, part 1 | `report_r24_data_basic_1.md` | 5 | 5 | PASS |
| 8 | data-basic, part 2 | `report_r24_data_basic_2.md` | 4 | 4 | PASS |
| 9 | data-ingest, part 1 | `report_r24_data_ingest_1.md` | 5 | 5 | PASS |
| 10 | data-ingest, part 2 | `report_r24b_data_ingest_2.md` | 5 | 5 | PASS |
| 11 | data-medium, part 1 | `report_r24_data_medium_1.md` | 6 | 6 | PASS |
| 12 | data-medium, part 2 | `report_r24_data_medium_2.md` | 5 | 4 | **UNFINISHED** (4/5) |
| 13 | data-statistics, part 1 | `report_r24_data_statistics_1.md` | 6 | 6 | PASS |
| 14 | data-statistics, part 2 | `report_r24_data_statistics_2.md` | 6 | 6 | PASS |
| 15 | data-transform, part 1 | `report_r24_data_transform_1.md` | 5 | 5 | PASS |
| 16 | data-transform, part 2 | `report_r24b_data_transform_2.md` | 5 | 5 | PASS |
| 17 | data-visual, part 1 | `report_r24_data_visual_1.md` | 7 | 7 | PASS |
| 18 | data-visual, part 2 | `report_r24b_data_visual_2.md` | 6 | 6 | PASS |
| 19 | data-workspace | `report_r24b_data_workspace.md` | 6 | 6 | PASS |
| 20 | math | `report_r24b_math.md` | 8 | 8 | PASS |
| 21 | browser, part 1 | `report_r24b_browser_1.md` | 7 | 7 | PASS |
| 22 | browser, part 2 | `report_r24b_browser_2.md` | 6 | 6 | PASS |
| 23 | ml-basic, part 1 | `report_r24b_ml_basic_1.md` | 6 | 6 | PASS |
| 24 | ml-basic, part 2 | `report_r24b_ml_basic_2.md` | 5 | 5 | PASS |
| 25 | ml-medium, part 1 | `report_r24b_ml_medium_1.md` | 6 | 6 | PASS |
| 26 | ml-medium, part 2 | `report_r24b_ml_medium_2.md` | 6 | 6 | PASS |
| 27 | ml-advanced, part 1 | `report_r24b_ml_advanced_1.md` | 5 | 5 | PASS |
| 28 | ml-advanced, part 2 | `report_r24b_ml_advanced_2.md` | 5 | 5 | PASS |
| 29 | office-docx-basic, part 1 | `report_r24b_office_docx_basic_1.md` | 8 | 8 | PASS |
| 30 | office-docx-basic, part 2 | `report_r24b_office_docx_basic_2.md` | 7 | 7 | PASS |
| 31 | office-docx-layout | `report_r24b_office_docx_layout.md` | 7 | 7 | PASS |
| 32 | office-docx-new, part 1 | `report_r24b_office_docx_new_1.md` | 5 | 5 | PASS |
| 33 | office-docx-new, part 2 | `report_r24b_office_docx_new_2.md` | 4 | 4 | PASS |
| 34 | office-docx-tables, part 1 | `report_r24b_office_docx_tables_1.md` | 5 | 5 | PASS |
| 35 | office-docx-tables, part 2 | `report_r24b_office_docx_tables_2.md` | 5 | 5 | PASS |
| 36 | office-pptx-basic, part 1 | `report_r24b_office_pptx_basic_1.md` | 5 | 5 | PASS |
| 37 | office-pptx-basic, part 2 | `report_r24b_office_pptx_basic_2.md` | 5 | 5 | PASS |
| 38 | office-pptx-design | `report_r24b_office_pptx_design.md` | 8 | 8 | PASS |
| 39 | office-pptx-new | `report_r24b_office_pptx_new.md` | 6 | 6 | PASS |
| 40 | office-xlsx-basic, part 1 | `report_r24b_office_xlsx_basic_1.md` | 7 | 7 | PASS |
| 41 | office-xlsx-basic, part 2 | `report_r24b_office_xlsx_basic_2.md` | 7 | 7 | PASS |
| 42 | office-xlsx-charts | `report_r24b_office_xlsx_charts.md` | 5 | 5 | PASS |
| 43 | office-xlsx-formulas, part 1 | `report_r24b_office_xlsx_formulas_1.md` | 5 | 5 | PASS |
| 44 | office-xlsx-formulas, part 2 | `report_r24b_office_xlsx_formulas_2.md` | 4 | 4 | PASS |
| 45 | office-xlsx-new | `report_r24b_office_xlsx_new.md` | 6 | 6 | PASS |

## State at the quota stop — 2026-09-05

**18 of 45 phases reported, 109 rows.** OpenRouter's `free-models-per-day-high-balance`
quota hit at **18:22:10Z**, mid-phase-19; phases 19, 20 and 21 wrote nothing and the
driver's three-consecutive-empties guard stopped the round at 18:47. Phases 22-45 were
never reached. Log `sweep_r24.log`, 43 rate-limit lines in the container's own log.

**Five phases are INVALID rather than short, and both reasons matter.**

* **Phases 1-4 (File_System) fabricated the descriptions they were scored against.**
  `fs_write`'s real description is the 70-character *"Write, edit, move, copy, download
  a URL, restore. Delete needs a token."* covering sixteen ops. Asked by `columns_ops`
  for "the description sentence that covers this op", the model wrote one per op —
  *"Delete lines from a file by line number range."*, *"Set file permissions (mode) on a
  file."* — none of which appear in any server's `tools/list`. It then marked its own
  inventions BROKEN: `delete_request` was scored against "deletes the file immediately",
  a claim the tool never makes and correctly does not honour. **This is an axis bug, not
  a model failure, and `descriptions_r24.tsv` is what caught it** — the grading key
  earning its keep on the round's first four phases. `columns_ops` is fixed for r24b.
  What survives from these four: the *undeclared effects* column, which independently
  reports that every write op leaves a backup no description mentions.
* **Phase 16 passed on row count while covering none of its tools.** Five rows, and
  `check_coverage.py` finds all five named tools — `concat_datasets`, `smart_impute`,
  `run_cleaning_pipeline`, `feature_engineering`, `enrich_with_geo` — absent. The
  standing rule that row count is not coverage, in its sharpest form yet: the ledger
  said PASS and the phase did none of its work.

**Two findings confirmed by hand, without a model** — see `FINDINGS_r24.md`.

## Closed 2026-09-06T05:47:09Z

**45 of 45 phases reported, 44 at full coverage, 273 rows over 268 tool-slots.**
`check_coverage.py` finds **no tool named in a phase and absent from its report**
in any of the 34 re-run reports. The one shortfall is phase 12 at 4 of 5.

Verdicts across the authoritative report for each phase:
**226 HELD, 43 BROKEN, 3 VAGUE** — 272 scored.

Three models and three quota walls to get there:

| leg | model | phases | ended by |
|---|---|---|---|
| r24 | OpenRouter `nemotron-3-super-120b-a12b:free` | 1-18 (5 later voided) | free-models-per-day, 18:22Z |
| r24b | OpenCode Zen `muse-spark-1.3-contributor-free` | 1-4, 10, 16, 18-22 | per-model rate limit, 23:10Z |
| r24c | OpenCode Zen `nemotron-3-ultra-free` | 23-45 | ran to completion, 0 rate limits |

The fixtures came through untouched — `Ad_Data.csv`, `BBCA_filing.pdf` and
`BBCA_instance.zip` all still match the md5s staged before launch.

**43 BROKEN rows are candidates, not defects.** Round 17 confirmed 2 of 9 and
round 23b ruled out 4 of 6; the two already confirmed here are in
`FINDINGS_r24.md`. Triage is the remaining work.
