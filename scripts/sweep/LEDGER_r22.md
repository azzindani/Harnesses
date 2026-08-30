# Round 22 ledger — "the answer as data, after the runtime moved"

Six repos, 226 tools from `tools/list` on 24 live endpoints, 42 phases.
Driver: the opencode harness (uninformed model). Plan `phases_r22.tsv`, axis
`AXES[22]`, reports `report_r22_*.md` in `/root/Harnesses/data`.

**Two models, because the first ran out of quota mid-round.** Phases 1–32 ran on
OpenRouter → `nvidia/nemotron-3-super-120b-a12b:free`, log `sweep_r22.log`. At
05:10:33Z, on phase 33, OpenRouter began returning
`AI_APICallError: Rate limit exceeded: free-models-per-day-high-balance` to every
request. On screen this looks like nothing at all: the driver types the prompt,
the box will not clear, and it logs "typed in full but would not submit" — the
same shape as a modal holding focus. **A dead provider is only visible in
`/root/.local/share/opencode/log/opencode.log`; the pane never says why.**
Phases 33–42 and the re-runs continue on OpenCode Zen →
`opencode/muse-spark-1.2-contributor-free` (no API key), log `sweep_r22b.log`.
Switched by setting `OPENCODE_MODEL` in `Harnesses/.env` and recreating the
container — the entrypoint then writes a config with no `lab` provider block at
all and pins the model on the command line, which does override the resumed
session's recorded choice.

Nemotron's reports for the four re-run phases are kept in
`data/r22_nemotron_backup/`; the driver deletes a report before re-running it.

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
| 1 | filesystem: fs_write, part 1 | `report_r22_fs_write_1.md` | 8 | 8 | PASS |
| 2 | filesystem: fs_write, part 2 | `report_r22_fs_write_2.md` | 8 |  | RUNNING |
| 3 | filesystem: fs_read modes and fs_query | `report_r22_fs_read.md` | 7 | 7 | PASS |
| 4 | filesystem: fs_index, fs_manage, fs_archive | `report_r22_fs_actions.md` | 8 | 13 | PASS |
| 5 | data-basic, part 1 | `report_r22_data_basic_1.md` | 5 | 5 | PASS |
| 6 | data-basic, part 2 | `report_r22_data_basic_2.md` | 4 | 4 | PASS |
| 7 | data-ingest, part 1 | `report_r22_data_ingest_1.md` | 5 | 5 | PASS |
| 8 | data-ingest, part 2 | `report_r22_data_ingest_2.md` | 5 | 5 | PASS |
| 9 | data-medium, part 1 | `report_r22_data_medium_1.md` | 6 | 6 | PASS |
| 10 | data-medium, part 2 | `report_r22_data_medium_2.md` | 5 | 5 | PASS |
| 11 | data-statistics, part 1 | `report_r22_data_statistics_1.md` | 6 | 6 | PASS |
| 12 | data-statistics, part 2 | `report_r22_data_statistics_2.md` | 6 | 6 | PASS |
| 13 | data-transform, part 1 | `report_r22_data_transform_1.md` | 5 | 5 | PASS |
| 14 | data-transform, part 2 | `report_r22_data_transform_2.md` | 5 | 5 | PASS |
| 15 | data-visual, part 1 | `report_r22_data_visual_1.md` | 6 | 6 | PASS |
| 16 | data-visual, part 2 | `report_r22_data_visual_2.md` | 6 | 6 | PASS |
| 17 | data-workspace | `report_r22_data_workspace.md` | 6 | 6 | PASS |
| 18 | math | `report_r22_math.md` | 8 | 8 | NOT REACHED |
| 19 | browser, part 1 | `report_r22_browser_1.md` | 7 | 7 | PASS |
| 20 | browser, part 2 | `report_r22_browser_2.md` | 6 | 6 | PASS |
| 21 | ml-basic, part 1 | `report_r22_ml_basic_1.md` | 6 | 6 | PASS |
| 22 | ml-basic, part 2 | `report_r22_ml_basic_2.md` | 5 | 5 | PASS |
| 23 | ml-medium, part 1 | `report_r22_ml_medium_1.md` | 6 | 6 | PASS |
| 24 | ml-medium, part 2 | `report_r22_ml_medium_2.md` | 6 | 6 | PASS |
| 25 | ml-advanced, part 1 | `report_r22_ml_advanced_1.md` | 5 | 5 | PASS |
| 26 | ml-advanced, part 2 | `report_r22_ml_advanced_2.md` | 5 | 5 | PASS |
| 27 | office-docx-basic, part 1 | `report_r22_office_docx_basic_1.md` | 8 | 8 | PASS |
| 28 | office-docx-basic, part 2 | `report_r22_office_docx_basic_2.md` | 7 | 7 | PASS |
| 29 | office-docx-layout | `report_r22_office_docx_layout.md` | 7 | 7 | PASS |
| 30 | office-docx-new | `report_r22_office_docx_new.md` | 7 | 7 | PASS |
| 31 | office-docx-tables, part 1 | `report_r22_office_docx_tables_1.md` | 5 | 5 | PASS |
| 32 | office-docx-tables, part 2 | `report_r22_office_docx_tables_2.md` | 4 | 4 | PASS |
| 33 | office-pptx-basic, part 1 | `report_r22_office_pptx_basic_1.md` | 5 | 5 | PASS |
| 34 | office-pptx-basic, part 2 | `report_r22_office_pptx_basic_2.md` | 5 | 5 | PASS |
| 35 | office-pptx-design | `report_r22_office_pptx_design.md` | 8 | 8 | PASS |
| 36 | office-pptx-new | `report_r22_office_pptx_new.md` | 6 | 6 | PASS |
| 37 | office-xlsx-basic, part 1 | `report_r22_office_xlsx_basic_1.md` | 7 | 7 | PASS |
| 38 | office-xlsx-basic, part 2 | `report_r22_office_xlsx_basic_2.md` | 7 | 7 | PASS |
| 39 | office-xlsx-charts | `report_r22_office_xlsx_charts.md` | 5 | 5 | PASS |
| 40 | office-xlsx-formulas, part 1 | `report_r22_office_xlsx_formulas_1.md` | 5 | 6 | PASS |
| 41 | office-xlsx-formulas, part 2 | `report_r22_office_xlsx_formulas_2.md` | 4 | 4 | PASS |
| 42 | office-xlsx-new | `report_r22_office_xlsx_new.md` | 6 | 6 | PASS |


## Re-run under Muse Spark — phases 3, 10, 20, 32, 33–42

Fourteen phases, launched 05:27:25Z, log `sweep_r22b.log`.

| phase | why it is being re-run |
|---|---|
| 3 | nemotron passed all 7 tools but **shallowly**: 3 of 7 rows recorded the cross-check as N/A, and `fs_query *.csv` reported `total_found > returned` without the report ever saying what `truncated` was — the field that carried the directory-order bug. A pass that skipped the check is not a pass on this axis. |
| 10 | UNFINISHED, 4 of 5 tools |
| 20 | UNFINISHED, 1 of 6 tools |
| 32 | UNFINISHED, 1 of 4 tools |
| 33–42 | never reached; the quota ran out on 33 |

Verdicts to carry forward regardless of the re-run, from the nemotron phases
that did finish — these are for a human to check against the code, not for the
sweep to re-answer:

* **phase 2** — `delete_request` and `delete_tree_request` both answer
  `op: "delete_pending"`, so `op` cannot tell the two apart.
* **phase 18 (math, canary)** — `solve` returns its roots as strings `"-2"`,
  `"2"` rather than JSON numbers.

## Re-test after fixes — phases 2, 3, 18, 29, 35, 39, 40

Five defects were confirmed from the round's reports, fixed in four repos, and
the servers redeployed. These seven phases are the ones that exercise the fixed
tools; log `sweep_r22c.log`, reports backed up in `data/r22_prefix_backup/`.

| defect | repo | phase(s) that exercise it |
|---|---|---|
| `set_font_all_slides` / `set_font_style` reported success and left bold unchanged; `bold` could only ever be turned ON | Microsoft_Office (pptx_design) | 35 |
| same fault, `set_font` bold AND italic | Microsoft_Office (docx_layout) | 29 |
| same fault twice in one expression, `set_cell_style` | Microsoft_Office (xlsx_charts) | 39 |
| `shapes_modified` counted shapes VISITED, not changed | Microsoft_Office (pptx_design) | 35 |
| `set_data_validation` appended a duplicate rule instead of replacing | Microsoft_Office (xlsx_formulas) | 40 |
| `fs_query(content=)` `total_found` was a count over the first 500 of 1,843 files, reported as exact | File_System | 3 |
| `delete_request` and `delete_tree_request` both answered `op: "delete_pending"` | File_System | 2 |
| `solve` returned integer roots as strings `"-2"`, `"2"` | Math | 18 |

**Verdicts these replace**, from the first run, so nothing is lost by blanking
the cells:

* **2** — PASS; the two `delete_*_request` ops shared one `op` value, and
  `total_size_kb: 0.5` for 559 bytes confirmed the sub-kilobyte rounding fix
  holds.
* **3** — PASS (muse-spark re-run). It also settled the `fs_read total_lines`
  question left open by nemotron: `Ad_Data.csv` has no trailing newline, so
  `wc -l` undercounts by one and the tool's 16,835 is correct. A false positive.
* **18** — CANARY, PASS, with `solve` returning strings.
* **29, 35, 39, 40** — PASS on row count; 35 and 40 carried the FINDING rows
  quoted above, which is how the defects were found at all.

**A third model.** OpenCode Zen's free tier ran out mid-phase-2 of this
re-test, at 07:49Z, with `AI_APICallError: Rate limit exceeded` and a status bar
reading `Free usage exceeded, subscribe to Go [retrying in 16h 9m]`. Unlike
OpenRouter's silent exhaustion, this one IS visible in the pane.

**The quota is per MODEL, not per account**: `opencode/nemotron-3-ultra-free`
answered immediately on the same account. So the recovery from an exhausted
OpenCode Zen model is to pick another one, not to wait.

**Switch it through `/models` in the TUI, not with `--model`.** The flag did not
take: the footer stayed on Muse Spark through a container recreate, a `--model`
change in `.env`, AND a `/new` session, because the model picked in the TUI is
recorded on the session row and inherited by every session after it. Only the
picker actually moved it. (The earlier lab -> opencode switch DID take on the
command line, so the flag is not reliable either way -- use the picker and
confirm in the footer.)

Phases 2-40 of this re-test therefore run on `opencode/nemotron-3-ultra-free`,
log `sweep_r22d.log`.

**A note on schema.** `bold` and `italic` are now `"true"` / `"false"` / `""`
rather than booleans, because a bool cannot express "turn it off" — `False` is
indistinguishable from unset, which is exactly what the defect was. A caller
sending a JSON boolean now gets a refusal naming the quoted form. Phases 29, 35
and 39 will show that refusal if the model reaches for the boolean first; a
recovery on the second try is the schema working, not a defect.

### Re-test STOPPED 2026-08-30 ~08:02Z, at phase 2 of 7

OpenCode Zen's `muse-spark` quota ran out first (16h retry); the re-test was
relaunched on `opencode/nemotron-3-ultra-free`, ran phase 2, and was then
stopped by hand to wait for the quotas to reset. `harness-opencode` is stopped.

**The seven reports in `data/` for phases 2, 3, 18, 29, 35, 39, 40 are PRE-FIX
results**, restored from `data/r22_prefix_backup/` — phase 2's was deleted by
the driver at phase start and never rewritten, so it was put back. Read them as
the evidence that found the defects, NOT as verification that the fixes work.
**Nothing in this round has yet re-tested the fixed code.**

To resume: start `harness-opencode`, confirm the model in the log (the footer
lies), then

    cd /root/Harnesses/scripts/sweep
    setsid nohup env PLAN=$PWD/phases_r22.tsv LOG=$PWD/sweep_r22e.log \
      ./run_sweep.sh 2,3,18,29,35,39,40 > sweep_r22e.nohup 2>&1 </dev/null &
    setsid nohup ./watch_round.sh 22 <pid> sweep_r22.log sweep_r22b.log \
      sweep_r22c.log sweep_r22d.log sweep_r22e.log >> watch_r22.log 2>&1 </dev/null &

Blank the verdict cells for those seven phases first, or `ledger_update.py` will
not touch them.
