# Sweep prompts

The prompts the coverage sweep sends into the harness session, kept as source
rather than retyped each round.

For ten rounds these lived in a throwaway generator in a scratch directory. Each
round I rewrote it, which meant re-deriving the wording of the parts that were
working fine, and the round's own question was a constant pasted into all 39
prompts. Round 11 took a bad turn out of exactly that: a rule about running each
op twice was woven into four File_System prompts by hand, in four slightly
different phrasings.

So the split here is:

| file | changes | holds |
|---|---|---|
| `blocks.py` | rarely, when a rule changes for good | the preamble, the verification rule, the write-as-you-go rule, the File_System phase bodies |
| `axes.py` | once per round | the round's question, its report columns, its File_System notes |
| `make_plan.py` | almost never | splitting the tool list into phases and assembling the prompt |

## Running it

```sh
python3 make_plan.py --round 11 --tools tools_r11.tsv --out phases_r11.tsv
```

`--tools` is two tab-separated columns, server and tool:

```
data-medium	pivot_table
data-medium	sample_data
```

Take it from `tools/list` on each endpoint — `./refresh_tools.sh > tools_rNN.tsv`
does exactly that, one MCP session per mount, and refuses to write a list if any
endpoint answers with zero tools. **Never** from a list the sweep model writes
for itself — asked to "list the tools then call each", it once listed some,
called none, and reported a clean pass over 19 tools it never touched.

## Starting a round

1. Refresh the tools file: `./refresh_tools.sh > tools_rNN.tsv`, and diff it
   against the previous round's — a tool that silently disappeared from an
   endpoint is worth knowing about before the round, not after.
2. Add an entry to `AXES` in `axes.py`. The commented candidates at the bottom
   of that file are the leftovers from round 11, kept so the next round starts
   from evidence.
3. Regenerate the plan and run the driver.

Nothing else needs editing. If you find yourself changing `make_plan.py` to
express a round, the axis is probably trying to be two axes.

## What an axis is for

An axis is worth a round when it can be wrong in a way no test would catch —
something every tool claims implicitly and nothing checks. Round 11's was
`idempotentHint`, which had been assigned by category rather than measured; the
sweep found five tools whose second identical call wrote a second file.

## House rules

- No host, domain or token in any prompt. These go to a third-party model on
  every phase.
- No phase names more than eight tools. At sixteen the model reliably stops
  halfway; at eight, round 10 ran 38 of 39 phases on the first attempt.
- File_System is covered as named operations, not as six tool calls — its six
  tools carry a dozen operations each behind an `op`/`action` argument.

## Where a round runs — `harness-sweep`

The sweep drives its **own** opencode container, not the operator's. Same image
and entrypoint as `harness-opencode`, its own state directory, so a 45-phase
coverage round can never spend the paid subscription living in the personal
harness's `opencode.db`. `run_sweep.sh` defaults to it; `SWEEP_CONTAINER=` picks
another.

It is deliberately absent from `auth/server.py`'s `HARNESSES`, so the idle
sweeper cannot stop it mid-round and `IDLE_EXEMPT` is irrelevant to it. Two
variables are its own, and both exist so scoping the personal harness never
scopes the sweep:

| variable | empty means | why |
|---|---|---|
| `SWEEP_MODEL` | the OpenRouter `lab` route from `PROVIDER_*` + `MODEL_NAME` | set it to one of opencode's own `*-free` ids to ride out a quota day |
| `SWEEP_MCP_DISABLED` | nothing hidden | `.env`'s `MCP_DISABLED` scopes the *personal* harness; the sweep must see every repo under test |

Set `SWEEP_MCP_DISABLED=folio` — it is not one of the seven repos under test, no
phase names it, and empty otherwise registers it. That leaves 27 servers: the 26
endpoints plus the `web` sidecar, which stays because it is the research leg
when browser is out.

It is disposable. `docker compose rm -sf harness-sweep` between rounds costs
nothing: the reports are written to the shared `data/` mount, not inside it.
**Never delete the image** — `harness-opencode:latest` is shared with the
personal harness.

## Switching model mid-round

Every free tier here runs out, and the three failures look different:

* **OpenRouter is silent.** Nothing on screen; the driver logs "typed in full
  but would not submit", which is also what a modal and a starved TUI look like.
  The only evidence is inside the container:

      docker exec harness-sweep sh -c \
        'grep -i "rate limit" /root/.local/share/opencode/log/opencode.log' | tail -3

* **OpenCode Zen says so**, in the status bar: `Free usage exceeded, subscribe
  to Go [retrying in 12h 52m attempt #1]`.
* Sometimes the pane shows `Provider returned error [retrying in Ns attempt #5]`
  with the box idle.

**Zen's quota is per model, so recovery is to switch, not to wait** — round 25
went `nemotron-3-ultra-free` → `muse-spark-1.3-contributor-free` → OpenRouter's
`nemotron-3-super` in a day, and each switch answered immediately.

**A switch needs a new session, not new config.** Stop the container, move
`history/sweep/state/opencode.db*` aside, restart, and confirm with
`grep -oE 'modelID=[^ ]*'` on the container's log — **never the footer**, which
has shown a new name on a reply the old model served.

A fresh session is worth it for a second reason: an accumulated session is not
an uninformed caller. Round 25 re-asked round 24's question about descriptions
that had since been fixed, and the old session held 45 phases of the *old*
descriptions.

## monitor_round.sh — watching without owning the round

    setsid nohup ./monitor_round.sh <driver-pid> sweep_r25c.log >> m.log 2>&1 </dev/null &

Writes one line to `STATUS_<log stem>.txt` and exits when the round ends, the
driver dies, or nothing completes for ~48 minutes. `setsid`, like the driver,
because a Claude Code background task gets reaped by the host's low-memory guard
while the detached driver beside it never notices.

The log is an argument because round 25 needed three of these in a day, one per
provider switch; sed-copying the script per log left four near-identical files
free to drift apart.

## verify_n1.sh — confirming a round's fixes reached the endpoints

A round produces fixes; the fixes need a re-check, and that re-check should not
depend on a model. `verify_n1.sh` calls each tool fixed for round 13's n=1 axis
directly over MCP and greps its response for the thing that used to be wrong —
`"outlier_count_iqr":null` where a fence with no width once reported 0,
`residual degrees of freedom` where the caller once got scipy's
`'float' object has no attribute 'dtype'`.

Direct curl rather than the harness, for three reasons: it takes seconds
instead of an hour, it cannot be defeated by a provider outage (which cost two
rounds this month), and a grep for an exact string is a stronger check than a
model's prose verdict — see the note in reference_what_finds_defects about not
classifying verdicts with a regex.

    ./verify_n1.sh          # 18 checks, exits non-zero on the first mismatch

It reads its endpoints and tokens from `/root/Harnesses/.env` and its fixtures
from `data/n1_verify/`, which is the shared bind mount. **Create that directory
group-writable** — the servers run as uid 999, and a root-owned 755 directory
gives every write tool `[Errno 13] Permission denied` on a path it can read
from perfectly well:

    mkdir -p data/n1_verify && chgrp -R 999 data/n1_verify && chmod -R g+w data/n1_verify

Copy the pattern for the next axis rather than extending this file: a check that
names the specific string a specific fix introduced stops being meaningful once
that fix is old.

`verify_r24_shipped.sh` and `verify_r25_fixes.sh` are the current examples, and
round 25 showed exactly why they are not optional. Re-asking the axis on the
fixed tools flipped 12 of 16 from BROKEN to HELD — but every `dayfirst` tool was
called with `dayfirst=auto`, the *valid* value, so the refusal the fix added was
never exercised. Three for three. **A model picks its own inputs and picks the
branch the fix did not change.** The verify script settles that in seconds and
cannot be defeated by a provider outage.

What the sweep gives that the script cannot is the other half: whether the fix
broke anything nearby, and whether the new sentence actually helps an uninformed
caller. Round 25's best row is that half working —

    statistical_test | "17 available: an unknown 'test' lists them all."
    | called test=unknown_test | HELD | hint listing exactly 17 valid tests

— a model discovering all seventeen tests from the description alone, where
round 24 had found eleven of them invisible to every caller.
