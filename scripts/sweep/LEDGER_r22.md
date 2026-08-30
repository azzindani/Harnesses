# Round 22 ledger — "the answer as data, after the runtime moved"

Six repos, 226 tools from `tools/list` on 24 live endpoints, 42 phases.
Driver: the opencode harness (uninformed model), OpenRouter →
`nvidia/nemotron-3-super-120b-a12b:free`. Plan `phases_r22.tsv`, axis `AXES[22]`,
reports `report_r22_*.md` in `/root/Harnesses/data`.

**Why this axis.** Rounds 20 and 21 proved the tools answer — 207 calls, one
defect — and that what is left is whether the answer is *right*. Between round 21
and this one all six repos moved from Python 3.12 to 3.14 and from third-party
`fastmcp` 2.x to the official MCP SDK. CI proves every tool still answers and the
e2e job proves transport, auth and one real call each. Neither can see a value
that changed **shape** in the move: a float arriving as a string, a `NaN` where
JSON has no token for one, a warning text or an object repr leaked into a field.
So this round judges each response as **data**, not as prose.

**Math and Web_Browser are back in the harness** after four rounds out. Both
migrated with the others, so both are in scope; browser's five-round zero is
partly that a success-checking sweep dismisses all 13 of its tools for answering
`ok` rather than `success`, which the axis now names explicitly.

Fill in `verdict` as the round runs: **PASS** / **DEFECT ×n** / **UNFINISHED**
(rows written < tools) / **DRY** (no report). Re-runs take the unpassed only.

| phase | label | report | tools | rows | verdict |
|---|---|---|---:|---|---|
| 1 | filesystem: fs_write, part 1 | `report_r22_fs_write_1.md` | 8 | | |
| 2 | filesystem: fs_write, part 2 | `report_r22_fs_write_2.md` | 8 | | |
| 3 | filesystem: fs_read modes and fs_query | `report_r22_fs_read.md` | 7 | | |
| 4 | filesystem: fs_index, fs_manage, fs_archive | `report_r22_fs_actions.md` | 8 | | |
| 5 | data-basic, part 1 | `report_r22_data_basic_1.md` | 5 | | |
| 6 | data-basic, part 2 | `report_r22_data_basic_2.md` | 4 | | |
| 7 | data-ingest, part 1 | `report_r22_data_ingest_1.md` | 5 | | |
| 8 | data-ingest, part 2 | `report_r22_data_ingest_2.md` | 5 | | |
| 9 | data-medium, part 1 | `report_r22_data_medium_1.md` | 6 | | |
| 10 | data-medium, part 2 | `report_r22_data_medium_2.md` | 5 | | |
| 11 | data-statistics, part 1 | `report_r22_data_statistics_1.md` | 6 | | |
| 12 | data-statistics, part 2 | `report_r22_data_statistics_2.md` | 6 | | |
| 13 | data-transform, part 1 | `report_r22_data_transform_1.md` | 5 | | |
| 14 | data-transform, part 2 | `report_r22_data_transform_2.md` | 5 | | |
| 15 | data-visual, part 1 | `report_r22_data_visual_1.md` | 6 | | |
| 16 | data-visual, part 2 | `report_r22_data_visual_2.md` | 6 | | |
| 17 | data-workspace | `report_r22_data_workspace.md` | 6 | | |
| 18 | math | `report_r22_math.md` | 8 | 8 | **CANARY — PASS**, 1 to verify: `solve` returns solutions as strings `"-2"`, `"2"` |
| 19 | browser, part 1 | `report_r22_browser_1.md` | 7 | | |
| 20 | browser, part 2 | `report_r22_browser_2.md` | 6 | | |
| 21 | ml-basic, part 1 | `report_r22_ml_basic_1.md` | 6 | | |
| 22 | ml-basic, part 2 | `report_r22_ml_basic_2.md` | 5 | | |
| 23 | ml-medium, part 1 | `report_r22_ml_medium_1.md` | 6 | | |
| 24 | ml-medium, part 2 | `report_r22_ml_medium_2.md` | 6 | | |
| 25 | ml-advanced, part 1 | `report_r22_ml_advanced_1.md` | 5 | | |
| 26 | ml-advanced, part 2 | `report_r22_ml_advanced_2.md` | 5 | | |
| 27 | office-docx-basic, part 1 | `report_r22_office_docx_basic_1.md` | 8 | | |
| 28 | office-docx-basic, part 2 | `report_r22_office_docx_basic_2.md` | 7 | | |
| 29 | office-docx-layout | `report_r22_office_docx_layout.md` | 7 | | |
| 30 | office-docx-new | `report_r22_office_docx_new.md` | 7 | | |
| 31 | office-docx-tables, part 1 | `report_r22_office_docx_tables_1.md` | 5 | | |
| 32 | office-docx-tables, part 2 | `report_r22_office_docx_tables_2.md` | 4 | | |
| 33 | office-pptx-basic, part 1 | `report_r22_office_pptx_basic_1.md` | 5 | | |
| 34 | office-pptx-basic, part 2 | `report_r22_office_pptx_basic_2.md` | 5 | | |
| 35 | office-pptx-design | `report_r22_office_pptx_design.md` | 8 | | |
| 36 | office-pptx-new | `report_r22_office_pptx_new.md` | 6 | | |
| 37 | office-xlsx-basic, part 1 | `report_r22_office_xlsx_basic_1.md` | 7 | | |
| 38 | office-xlsx-basic, part 2 | `report_r22_office_xlsx_basic_2.md` | 7 | | |
| 39 | office-xlsx-charts | `report_r22_office_xlsx_charts.md` | 5 | | |
| 40 | office-xlsx-formulas, part 1 | `report_r22_office_xlsx_formulas_1.md` | 5 | | |
| 41 | office-xlsx-formulas, part 2 | `report_r22_office_xlsx_formulas_2.md` | 4 | | |
| 42 | office-xlsx-new | `report_r22_office_xlsx_new.md` | 6 | | |

