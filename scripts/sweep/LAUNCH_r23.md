# Launching round 23

Everything below is prepared and checked. Nothing here has been run — the round
waits on the OpenRouter free-models daily quota resetting.

Round 23 is `AXES[23]`, *"ask the same question after something else has run"*:
44 phases, **239 tools on 26 endpoints, all seven repos**, `MCP_Documents`
included for the first time. Ledger `LEDGER_r23.md`, plan `phases_r23.tsv`,
reports `report_r23_*.md`.

---

## Already done

| | |
|---|---|
| tools list | `tools_r23.tsv`, from `tools/list` on all 26 mounts. 239 tools, every endpoint answered. Diff against `tools_r22.tsv` is **exactly the 13 new docs tools** — nothing disappeared. |
| axis | `AXES[23]` in `axes.py`, with per-File_System notes for all four FS phases |
| plan | `phases_r23.tsv`, 44 phases, `--max-tools 8`, `--report-prefix report_r23_` |
| ledger | `LEDGER_r23.md`, 44 rows, `ledger_update.py` verified against it |
| data | `/root/Harnesses/data` wiped to `.gitkeep` (462 entries, 2.6 GB, freed 1 GB of a 90%-full disk). 258 reports from rounds 14–22 plus both r22 backup dirs archived to `archive/reports_r14_r22.tar.gz` first. |
| fixtures | `Ad_Data.csv` restored from the pristine copy, md5 `9a16b9248526466960194df4eb7a3e90`, 16,834 rows. `BBCA_filing.pdf` staged and **verified through the deployed docs server**: 183 pages, 1 scanned, `pages_that_fit_one_response: 8`. |
| provider | `.env` — `OPENCODE_MODEL` commented out, so the harness builds the `lab` provider from `PROVIDER_BASE_URL` + `MODEL_NAME` = OpenRouter → `nvidia/nemotron-3-super-120b-a12b:free`. `FREE_FALLBACK=0`, `IDLE_EXEMPT=opencode`, `MCP_DISABLED=folio` (so docs is registered; harness-opencode already lists all 27 servers). Backup at `.env.bak.r22final`. |
| lint | shellcheck, `py_compile`, `ruff --select=E,F` all clean — the three gates Harnesses CI runs |

**Prompts are longer this round**: median 6,622 chars against round 22's 5,825,
max 7,107. At ~45 chars/sec that is ~160s to type, so keep
`ARRIVAL_WINDOW=420` — three times the worst case, and the same value round 22
ran at.

---

## 1. Pre-flight

```sh
df -h /                                             # was 89% after the cleanup
docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'mcp-|math|harness-opencode'
md5sum /root/Harnesses/data/Ad_Data.csv             # 9a16b9248526466960194df4eb7a3e90
ls /root/Harnesses/data                             # .gitkeep, Ad_Data.csv, BBCA_filing.pdf and nothing else
docker stats --no-stream harness-opencode           # idle CPU should be ~14%, not ~55%
```

A starved TUI reads exactly like a dead provider. If idle CPU is high,
`docker restart harness-opencode` before starting, not after nine phases.

## 2. Put the model on OpenRouter — the one manual step

`.env` is already right, but the container is still running the OpenCode Zen
model round 22 ended on, and **`--model` does not reliably switch a resumed
session** (measured both ways: it took once and did not take twice).

```sh
cd /root/Harnesses && docker compose up -d --force-recreate harness-opencode
```

Then, in the TUI (ttyd on 7681, or `docker exec -it harness-opencode tmux attach -t main`):

* `/models`, filter for `nemotron-3-super`, Enter.
* **Confirm in the log, not the footer** — the footer showed the old name on a
  new reply:

```sh
docker exec harness-opencode sh -c \
  'tail -n 200 /root/.local/share/opencode/log/opencode.log' | grep -io 'nemotron[^ "]*' | sort | uniq -c
```

Send one throwaway prompt first so there is something in the log to grep.

## 3. Launch

`setsid nohup`, never a Claude Code background task — a background task gets
reaped mid-phase with nothing in the log to explain it.

```sh
cd /root/Harnesses/scripts/sweep
setsid nohup env PLAN=$PWD/phases_r23.tsv LOG=$PWD/sweep_r23.log ARRIVAL_WINDOW=420 \
  ./run_sweep.sh all >> $PWD/sweep_r23.nohup 2>&1 </dev/null &
echo $!            # driver pid
ps -o pid,sid -p <pid>     # SID must equal PID, or it is not detached
```

Consider running **5,6 first** as a canary — the docs phases are the point of
this round and nothing has ever driven that server from a model that did not
write it. Round 22 canaried phase 18 the same way. Then `all`, which re-runs 5
and 6; pass a fresh `--report-prefix` if you want to keep the canary's reports,
because **the driver `rm -f`s each report before its phase**.

## 4. Watch

```sh
setsid nohup ./watch_round.sh 23 <driver-pid> sweep_r23.log \
  >> watch_r23.log 2>&1 </dev/null &
tail -f sweep_r23.log
```

Read the pane read-only; do not type into the session while the driver owns it,
and never edit `run_sweep.sh` while it runs (bash reads scripts lazily).

## 5. If a phase types in full and will not submit

Three causes, in the order they cost time:

1. **A modal has focus.** opencode's "Status / N MCP Servers" dialog swallows
   text and Enter alike and reads exactly like a dead provider — 20 launches and
   ~9 idle hours once. `docker exec harness-opencode tmux send-keys -t main Escape`.
2. **OpenRouter's quota is gone, silently.** Nothing on screen, ever. The only
   evidence:
   ```sh
   docker exec harness-opencode sh -c \
     'tail -n 500 /root/.local/share/opencode/log/opencode.log' | grep -i 'rate limit'
   ```
   Recovery is to uncomment `OPENCODE_MODEL` in `.env` with one of OpenCode
   Zen's free models, recreate, and pick it in `/models`. **Zen's quota is per
   MODEL, not per account**, so a second Zen model answers immediately when the
   first says "retrying in 16h". A new provider writes a **second log** — pass
   both to `ledger_update.py`/`watch_round.sh`, oldest first, or the phase the
   quota died on stays `RUNNING` forever.
3. **The container is gone or starved.** `docker stats`, then restart.

## 6. Don't

* Don't run heavy local compute while the round is live — full pytest pushed
  this 4-core box to load 8.59 and cost three phases.
* Don't rebuild any MCP container against a live sweep.
* Don't reuse a `--report-prefix` on a re-run.
* Don't let `pgrep -f` match your own command line:
  `ps -eo pid,args | grep -E "bash \./run_sweep\.sh"`.
* Stop the watcher when the round ends — `TaskStop` **and** a kill by PID. One
  `tail -F` survived 27 hours.

## 7. What this round owes round 22

Five defects were fixed and deployed after round 22 and **none of the fixed code
has been re-tested** — that re-test stopped at phase 2 of 7 when both providers
ran out of quota on the same day. The phases that exercise those tools are
**3, 4, 20, 31, 37, 41, 42**, and this round's File_System notes ask the
`fs_query` total/truncation question directly without naming the fix.

That is evidence, not proof: a model picking its own inputs picks the branch the
fix did not change (4-for-4 in one round). A `verify_r22.sh` calling those eight
tools directly over MCP and asserting the exact strings the fixes introduced
would settle it in seconds, needs no model, and cannot be defeated by a provider
outage. It does not exist yet.
