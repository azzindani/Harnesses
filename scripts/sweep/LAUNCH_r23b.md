# Round 23b — seven phases, two reasons

Same axis, same plan file numbering, new report prefix. `phases_r23b.tsv` is
`phases_r23.tsv` regenerated with `--report-prefix report_r23b_`; the phase
numbers are byte-identical, verified by diff, so a phase number means the same
thing in both rounds.

```sh
cd /root/Harnesses/scripts/sweep
setsid nohup env PLAN=$PWD/phases_r23b.tsv LOG=$PWD/sweep_r23b.log ARRIVAL_WINDOW=420 \
  ./run_sweep.sh 4,5,7,22,32,36,38 >> $PWD/sweep_r23b.nohup 2>&1 </dev/null &
echo $!; ps -o pid,sid -p <pid>      # SID must equal PID
setsid nohup ./watch_round.sh 23b <driver-pid> sweep_r23b.log >> watch_r23b.log 2>&1 </dev/null &
```

## Which phases and why

| phase | server | reason |
|---|---|---|
| 4 | filesystem: fs_index, fs_manage, fs_archive | **starved** — r23 report was 2 fused rows, both `TODO` |
| 5 | docs-read | **starved** — 1 of 7 tools, axis answer left "Not yet known". The seventh repo is why round 23 existed. |
| 7 | data-basic, part 1 | **starved** — 1 tool, no axis answer |
| 22 | browser, part 2 | **starved** — header row only, zero tools |
| 32 | office-docx-new | **fix** — `batch_create_from_template` no longer doubles `.docx` |
| 36 | office-pptx-basic, part 2 | **fix** — `diff_versions` now counts slide adds/removes |
| 38 | office-pptx-new | **fix** — `create_from_docx` warns on a 0-slide deck |

The four starved phases died inside OpenRouter's silent daily quota on
2026-08-31 (phases 26-35 fell to muse-spark's, 36-44 finished on
nemotron-3-ultra). Nothing about them is a finding; they simply never ran.

## The three fixes are already verified without a model

`verify_r23_fixes.sh` calls the three tools directly over MCP and asserts the
exact strings the fixes introduced. It needs no model, cannot be defeated by a
provider outage, and runs in seconds. **Run it first.** A model picking its own
inputs picks the branch the fix did not change — that was 4-for-4 in one round —
so the sweep's job on phases 32/36/38 is finding what the fix broke *elsewhere*,
not confirming the fix.

## Provider

`SWEEP_MODEL=` is blank in `/root/Harnesses/.env`, so `harness-sweep` builds the
`lab` provider from `PROVIDER_BASE_URL` + `MODEL_NAME` = OpenRouter ->
`nvidia/nemotron-3-super-120b-a12b:free`. Backup at `.env.bak.pre_r23b`.

Confirmed 2026-09-01T00:15Z: fresh session (previous `opencode.db` parked at
`history/sweep/old-20260901T001449Z`), PONG answered, footer reads
`nvidia/nemotron-3-super-120b-a12b:free lab`, **0 rate-limit lines**. The daily
quota has reset.

**A model switch needs a new session, not new config.** On 2026-08-31 both
`SWEEP_MODEL` + recreate *and* the `/models` picker left the log still serving
the dead model, because a stuck retry was bound to the old session. Stop the
container, move `history/sweep/state/opencode.db*` aside, restart, then confirm
with `grep -oE 'modelID=[^ ]*'` on the container's `opencode.log` — **never the
footer**, which showed the new name on a reply the old model served.

## The rest of LAUNCH_r23.md still applies

Pre-flight, the modal-with-focus failure mode, `pgrep -f` matching your own
command line, stopping the watcher at the end. Two additions from r23:

* **`mcp-office` was rebuilt for this round.** Never rebuild an MCP container
  against a live sweep; that is why the build finished before the launch.
* **Rows fuse without a trailing newline.** `blocks.py` now tells the model to
  end every appended row with `\n` and to read the file back. r23 lost the row
  count on five phases to this; r23b is the first round with the rule in the
  prompt.
