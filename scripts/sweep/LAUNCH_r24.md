# Round 24 — launch runbook

Axis `AXES[24]`, **"believe the description"**. 45 phases, 243 tools, 26 live
endpoints, seven repos. Everything below was done and checked on 2026-09-05;
what remains is the launch line.

```sh
cd /root/Harnesses/scripts/sweep
setsid nohup env PLAN=$PWD/phases_r24.tsv LOG=$PWD/sweep_r24.log ARRIVAL_WINDOW=480 \
  ./run_sweep.sh all >> $PWD/sweep_r24.nohup 2>&1 </dev/null &
echo $!                       # then: ps -o pid,sid -p <pid>   — SID must equal PID
setsid nohup ./watch_round.sh 24 <driver-pid> sweep_r24.log >> watch_r24.log 2>&1 </dev/null &
```

**`setsid nohup`, never a Claude Code background task** — a background Bash task
gets reaped mid-phase with nothing in the log to explain it. Watch with
`tail -f`, never by owning the process.

## Why ARRIVAL_WINDOW=480 and not 420

The driver types the prompt into tmux at ~45 chars/sec and polls for its tail
before pressing Enter; `ARRIVAL_WINDOW` is the ceiling on that arrival, not on
the answer. Round 23's prompts were 6,563–7,109 chars and ran at 420.

| round | min | median | max |
|---|---:|---:|---:|
| 23 | 6,563 | 6,625 | 7,109 |
| **24** | **7,115** | **7,176** | **7,681** |

8% longer, so 420 → 480 keeps the same margin. The standing lesson is that a
ceiling half your samples sit just under is itself the bug — 420 would put the
whole distribution inside 88% of the window.

## Done before launch

| step | state |
|---|---|
| `/root/Harnesses/data` wiped to fixtures | 221 entries / 920 MB removed, 4.6 MB left |
| round 23's 76 reports archived | `archive/reports_r23.tar.gz` |
| `Ad_Data.csv` pristine | md5 `9a16b9248526466960194df4eb7a3e90` |
| `BBCA_filing.pdf` pristine | md5 `e7ca79e6b91037cff193c89c7bd38849` |
| `BBCA_instance.zip` staged (new) | md5 `63297e12d6725aa55ba57a44629727eb` |
| `tools_r24.tsv` refreshed from `tools/list` | 243 tools, 26 endpoints, **no tool vanished** vs r23 (+4: `customize_dashboard`, `list_block_kinds`, `create_from_blocks`, `set_cell_style`) |
| `descriptions_r24.tsv` captured | all 243 descriptions — the round's grading key |
| `phases_r24.tsv` generated | 45 phases, no unsubstituted placeholder |
| `verify_r24_fixes.sh` | **26/26 PASS on the live fleet**, no model involved |
| `harness-sweep` recreated on a fresh session | old `opencode.db` parked in `history/sweep/old-20260905T145302Z` |
| provider probe | nonce echoed in **4.4s**; log shows 175 hits on `nvidia/nemotron-3-super-120b-a12b:free` and **0 rate-limit lines** |
| disk | 19 GB free after the wipe |

## The container is temporary, and that is the design

`harness-sweep` is a separate container from `harness-opencode` sharing the same
image and entrypoint, so a 45-phase coverage round can never spend the paid
opencode subscription that lives in the personal harness's `opencode.db`. Its
`OPENCODE_MODEL` is pinned empty in `docker-compose.yml` and `environment:`
beats `env_file:`, so it always builds the OpenRouter `lab` route from
`PROVIDER_BASE_URL` + `MODEL_NAME` no matter what `.env` says.

**New this round: `SWEEP_MCP_DISABLED=folio`.** The variable existed and was
unset, which registered folio in the sweep container. Folio is not one of the
seven repos under test, no phase in the plan names it, and it is off limits on
this box — so it is now hidden, and only it. 27 servers register: the 26
endpoints under test plus the `web` sidecar, which stays because it is the
research leg when browser is out.

Tear it down when the round closes: `docker compose stop harness-sweep`. Nothing
in it is worth keeping except the reports, and those are written to
`/workspace/data` on the shared mount, not inside the container.

## Provider

OpenRouter → `nvidia/nemotron-3-super-120b-a12b:free`, via `SWEEP_MODEL=` blank
in `/root/Harnesses/.env` (backup `.env.bak.pre_r24`). `FREE_FALLBACK=0` pins
the routing list so a silent substitution is visible.

**Quota exhaustion does not look like quota exhaustion.** OpenRouter is silent —
the driver logs "typed in full but would not submit", which is also what a modal
with focus and a starved TUI look like. Read the container's own log before
blaming any of them:

```sh
docker exec harness-sweep sh -c 'tail -n 500 /root/.local/share/opencode/log/opencode.log' \
  | grep -i 'rate limit'
```

Recovery is to switch model, not to wait: OpenCode Zen's free quota is per
model, so setting `SWEEP_MODEL` to one of its `*-free` ids answers immediately
on the same box. **A model switch needs a new session, not new config** — stop
the container, move `history/sweep/state/opencode.db*` aside, restart, and
confirm with `grep -oE 'modelID=[^ ]*'` on the container's log. Never the
footer, which has shown the new name on a reply the old model served.

## Traps that cost a round each

* **Never edit `run_sweep.sh` while it runs** — bash reads scripts lazily.
* **Do not type into the session while the driver owns it.** Read the pane only.
* **Always pass a NEW `--report-prefix` for a re-run.** The driver `rm -f`s each
  report before its phase, so reusing a prefix deletes rows already collected.
* **Killing the driver does not stop the model.** It finishes the phase
  unattended, so a restarted driver can find a *complete* report and delete it.
  Check before relaunching a phase.
* **`docker compose up -d --no-recreate`** mid-round; a recreate SIGTERMs the
  session and loses the phase. Do not rebuild an MCP container against a live
  sweep either.
* **`pgrep -f "<pattern>"` matches the checking command's own command line.**
  Use `ps -eo pid,args | grep -E "bash \./run_sweep\.sh"`, and count your own
  shells by parentage from the session's PID.
* **Stop the watcher when the round ends** — `TaskStop` *and* a kill by PID; the
  task record and the OS process outlive each other. One `tail -F` survived 27
  hours.
* **Do not run heavy local compute while the sweep is live.** Four cores; a full
  pytest + pyright pushed load to 8.59 and cost three phases. `nice -n 19`.

## Reading the result

`check_coverage.py` is the authority on whether a phase is done — row count is
not, because request+confirm pairs share a row. `strict_coverage.py` re-checks
that each tool owns the first column of a row; keep it a separate reporter,
since replacing the authority mid-round re-opens phases judged under the old
rule. Reports come in two table styles and anything anchored on a leading pipe
silently reads ~15% of them as empty.

This round has one extra grading step the others did not: **`descriptions_r24.tsv`
is the key.** A row whose "description quoted EXACTLY" column paraphrases can be
caught against it, and a phase whose rows all paraphrase did coverage, not the
axis.
