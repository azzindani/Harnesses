# Round 23 ledger — "ask the same question after something else has run"

**Seven repos, 239 tools from `tools/list` on 26 live endpoints, 44 phases.**
The first round to include `MCP_Documents`. Driver: the opencode harness
(uninformed model), OpenRouter -> `nvidia/nemotron-3-super-120b-a12b:free`.
Plan `phases_r23.tsv`, axis `AXES[23]`, reports `report_r23_*.md` in
`/root/Harnesses/data`.

**Why this axis.** Round 22 asked one tool the same question twice in a row,
which catches only plain non-determinism. This asks it again after *another
tool has touched the same target*. Every server here holds state the caller
cannot see — a reader LRU, a loaded dataset, a workspace, an open workbook, a
cached model — and the technique found MCP_Documents' two worst defects:
`find()` returning 5 hits and then 3 after an unrelated `extract()`, and
`probe` reporting a document **12.9% smaller** once its pages had been read,
in the number whose whole job is stopping the caller asking for too much. Both
`success: true`, both invisible to a repeat call, neither reachable by CI. The
mirror case is equally unchecked: a reader that reports "no changes" after a
write that really landed.

**Fixtures, both staged fresh before the round.** `Ad_Data.csv` restored from
the pristine copy (md5 `9a16b9248526466960194df4eb7a3e90`, 16,834 rows) and
`BBCA_filing.pdf` — the 183-page IDX filing already committed to the public
MCP_Documents repo, so the private corpus is still referenced and never copied.
`probe` on it answers 183 pages / 1 scanned / 8 pages fit one response, which
is exactly the witness this axis wants.

**Ordering is deliberate.** docs-read and docs-edit are phases 5 and 6, right
after the File_System block. Round 22 lost its provider's daily quota on phase
33 of 42; the repo that has never been swept must not be what a quota runs out
before.

**Carried in from round 22, still unverified.** Five defects were fixed and
deployed and *nothing has re-tested the fixed code* — the re-test stopped at
phase 2 of 7 when two providers ran out of quota in one day. The phases that
exercise those tools are **3, 4** (fs_query total_found / delete op names),
**20** (math `solve` returning JSON numbers), **31** (docx set_font bold),
**37** (pptx set_font_all_slides bold, shapes_modified), **41** (xlsx
set_cell_style bold), **42** (xlsx set_data_validation duplicate rule). This
round exercises them all, and the axis's fs_extra notes ask the fs_query and
index questions directly without naming the fix. A model picking its own inputs
is not a verification, so treat a clean row here as evidence and not proof.

Fill in `verdict` as the round runs: **PASS** / **DEFECT ×n** / **UNFINISHED**
(rows written < tools) / **DRY** (no report). Re-runs take the unpassed only.
`ledger_update.py` writes only the `rows` and `verdict` cells and never
overwrites a verdict a person typed.

| phase | label | report | tools | rows | verdict |
|---|---|---|---:|---|---|
| 1 | filesystem: fs_write, part 1 | `report_r23_fs_write_1.md` | 8 | 8 | PASS |
| 2 | filesystem: fs_write, part 2 | `report_r23_fs_write_2.md` | 8 | 10 | PASS |
| 3 | filesystem: fs_read modes and fs_query | `report_r23_fs_read.md` | 7 | 30 | PASS |
| 4 | filesystem: fs_index, fs_manage, fs_archive | `report_r23_fs_actions.md` | 8 | 1 | **UNFINISHED** (1/8) |
| 5 | docs-read | `report_r23_docs_read.md` | 7 | 1 | **UNFINISHED** (1/7) |
| 6 | docs-edit | `report_r23_docs_edit.md` | 6 | 1 | **UNFINISHED** (1/6) |
| 7 | data-basic, part 1 | `report_r23_data_basic_1.md` | 5 | 1 | **UNFINISHED** (1/5) |
| 8 | data-basic, part 2 | `report_r23_data_basic_2.md` | 4 | 4 | PASS |
| 9 | data-ingest, part 1 | `report_r23_data_ingest_1.md` | 5 | 5 | PASS |
| 10 | data-ingest, part 2 | `report_r23_data_ingest_2.md` | 5 | 5 | PASS |
| 11 | data-medium, part 1 | `report_r23_data_medium_1.md` | 6 | 6 | PASS |
| 12 | data-medium, part 2 | `report_r23_data_medium_2.md` | 5 | 1 | **UNFINISHED** (1/5) |
| 13 | data-statistics, part 1 | `report_r23_data_statistics_1.md` | 6 | 6 | PASS |
| 14 | data-statistics, part 2 | `report_r23_data_statistics_2.md` | 6 | 6 | PASS |
| 15 | data-transform, part 1 | `report_r23_data_transform_1.md` | 5 | 6 | PASS |
| 16 | data-transform, part 2 | `report_r23_data_transform_2.md` | 5 | 6 | PASS |
| 17 | data-visual, part 1 | `report_r23_data_visual_1.md` | 6 | 6 | PASS |
| 18 | data-visual, part 2 | `report_r23_data_visual_2.md` | 6 | 6 | PASS |
| 19 | data-workspace | `report_r23_data_workspace.md` | 6 | 6 | PASS |
| 20 | math | `report_r23_math.md` | 8 | 8 | PASS |
| 21 | browser, part 1 | `report_r23_browser_1.md` | 7 | 7 | PASS |
| 22 | browser, part 2 | `report_r23_browser_2.md` | 6 |  | **DRY** |
| 23 | ml-basic, part 1 | `report_r23_ml_basic_1.md` | 6 | 1 | **UNFINISHED** (1/6) |
| 24 | ml-basic, part 2 | `report_r23_ml_basic_2.md` | 5 | 5 | PASS |
| 25 | ml-medium, part 1 | `report_r23_ml_medium_1.md` | 6 | 7 | PASS |
| 26 | ml-medium, part 2 | `report_r23_ml_medium_2.md` | 6 | 6 | PASS |
| 27 | ml-advanced, part 1 | `report_r23_ml_advanced_1.md` | 5 | 5 | PASS |
| 28 | ml-advanced, part 2 | `report_r23_ml_advanced_2.md` | 5 | 5 | PASS |
| 29 | office-docx-basic, part 1 | `report_r23_office_docx_basic_1.md` | 8 | 8 | PASS |
| 30 | office-docx-basic, part 2 | `report_r23_office_docx_basic_2.md` | 7 | 8 | PASS |
| 31 | office-docx-layout | `report_r23_office_docx_layout.md` | 7 | 7 | PASS |
| 32 | office-docx-new | `report_r23_office_docx_new.md` | 7 | 7 | PASS |
| 33 | office-docx-tables, part 1 | `report_r23_office_docx_tables_1.md` | 5 | 5 | PASS |
| 34 | office-docx-tables, part 2 | `report_r23_office_docx_tables_2.md` | 4 | 4 | PASS |
| 35 | office-pptx-basic, part 1 | `report_r23_office_pptx_basic_1.md` | 5 | 5 | PASS |
| 36 | office-pptx-basic, part 2 | `report_r23_office_pptx_basic_2.md` | 5 | 10 | PASS |
| 37 | office-pptx-design | `report_r23_office_pptx_design.md` | 8 | 9 | PASS |
| 38 | office-pptx-new | `report_r23_office_pptx_new.md` | 6 | 9 | PASS |
| 39 | office-xlsx-basic, part 1 | `report_r23_office_xlsx_basic_1.md` | 7 | 14 | PASS |
| 40 | office-xlsx-basic, part 2 | `report_r23_office_xlsx_basic_2.md` | 7 | 9 | PASS |
| 41 | office-xlsx-charts | `report_r23_office_xlsx_charts.md` | 5 | 8 | PASS |
| 42 | office-xlsx-formulas, part 1 | `report_r23_office_xlsx_formulas_1.md` | 5 | 8 | PASS |
| 43 | office-xlsx-formulas, part 2 | `report_r23_office_xlsx_formulas_2.md` | 4 | 5 | PASS |
| 44 | office-xlsx-new | `report_r23_office_xlsx_new.md` | 6 | 6 | PASS |
