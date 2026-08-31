#!/bin/bash
# Drive a sweep round through the live opencode session.
#
#   PLAN=phases_r12.tsv ./run_sweep.sh all        # every phase in the plan
#   PLAN=phases_r12.tsv ./run_sweep.sh 7,20,22    # named phases only
#
# Headless `opencode run` is not an option here: it ships the session
# elsewhere. This types into the tmux session that is already attached, which
# is also what lets a person watch it happen.
#
# Three things this driver learned the hard way, each of which cost a round:
#
#   the container      docker exec into a stopped container fails silently, the
#                      busy check sees no 'esc interrupt', wait_idle returns the
#                      minimum, and the missing report is indistinguishable from
#                      a model that gave up. Round 11 lost three phases to that.
#
#   the prompt         these prompts are ~3,500 characters and the input box
#                      takes them at about 100 chars/second. Typing, sleeping one
#                      second and pressing Enter submits whatever fraction has
#                      landed -- which reads downstream as a model that did a
#                      third of the phase and stopped.
#
#   the fixture        every phase re-checks it. A sweep that silently edits the
#                      dataset every later phase measures against is worse than
#                      no sweep.
set -uo pipefail
# The sweep drives its OWN opencode container, not the operator's. harness-sweep
# pins OPENCODE_MODEL empty in compose, so it always talks to the OpenRouter
# `lab` route and can never spend a paid opencode subscription. Override with
# SWEEP_CONTAINER=harness-opencode to go back to the shared one.
C=${SWEEP_CONTAINER:-harness-sweep}
SP="$(cd "$(dirname "$0")" && pwd)"
DATA=${DATA:-/root/Harnesses/data}
PLAN=${PLAN:-$SP/phases_r12.tsv}
LOG=${LOG:-$SP/sweep.log}
FIXTURE=${FIXTURE:-/root/Harnesses/project/Ad_Data.csv}
QUORUM=4

[ -f "$PLAN" ] || { echo "no plan at $PLAN"; exit 1; }
SEL="${1:?usage: [PLAN=phases_rNN.tsv] run_sweep.sh all | 1,4,17}"
WANTED=",${SEL},"
PRISTINE=$(md5sum "$FIXTURE" | cut -d' ' -f1)

send() {
  docker exec $C tmux send-keys -t main -l "$1"
  sleep 1
  docker exec $C tmux send-keys -t main Enter
}

# Everything except letters, digits and underscore. The input box wraps a long
# prompt across lines and puts a border glyph at each break, so "read_receipt"
# can be sitting in the box as "read_rec|eipt" -- flattening both sides is the
# only comparison that survives that.
flat() { tr -cd 'A-Za-z0-9_'; }

# A session sitting on a permission dialog is not idle, but it shows no 'esc
# interrupt' -- so wait_idle called it finished, the driver started retrying,
# and typed into a box that would never clear. Round 15 lost most of two phases
# to that before anyone looked at the pane. Blocked counts as busy; blocked_ask
# below is what tells a person it needs answering.
blocked_ask() { docker exec $C tmux capture-pane -p -t main 2>/dev/null | grep -q 'Permission required'; }

busy() {
  docker exec $C tmux capture-pane -p -t main 2>/dev/null | grep -qE 'esc interrupt|Permission required'
}

# One failed `docker exec` is not a dead session. Under load the exec itself can
# fail while tmux is perfectly healthy, and the old single-shot check turned
# that into a container restart -- which really did end the session it was
# wrongly reporting on. Three tries, half a second apart.
alive() {
  docker ps --filter "name=^${C}$" --filter status=running --format '{{.Names}}' | grep -q "^${C}$" || return 1
  local i
  for i in 1 2 3; do
    docker exec $C tmux has-session -t main 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

ensure_alive() {
  alive && return 0
  echo "    harness container or tmux session is down — restarting" | tee -a "$LOG"
  # --no-recreate: without it, compose rebuilds a container whose config it
  # thinks has drifted, which SIGTERMs a session that may have been fine.
  (cd /root/Harnesses && docker compose up -d --no-recreate $C) >/dev/null 2>&1
  for _ in $(seq 1 20); do sleep 3; alive && { echo "    session back up" | tee -a "$LOG"; sleep 10; return 0; }; done
  echo "    COULD NOT REVIVE $C — STOPPING" | tee -a "$LOG"
  return 1
}

# The model answering nothing at all is not the same as the model refusing, and
# both look like an empty report. One trivial prompt before the round starts
# tells the two apart while it is still cheap to stop.
#
# Counting occurrences rather than testing for presence: the pane still shows the
# prompt, and the prompt contains the word being looked for. The first version of
# this check matched its own question and reported a dead provider as healthy,
# which is precisely the failure it exists to catch.
#
# Each probe carries its own nonce word. Retrying with the same word would count
# the FIRST attempt's question -- still on screen -- toward the second attempt's
# total, so the check would pass on a provider that never answered: exactly the
# failure the ">= 2" exists to prevent, reintroduced by the retry.
_probe() {
  local word="$1"
  docker exec $C tmux send-keys -t main C-u; sleep 2
  send "Reply with exactly the word $word and nothing else."
  for _ in $(seq 1 20); do
    sleep 4
    busy || break
  done
  local seen
  seen=$(docker exec $C tmux capture-pane -p -t main | grep -oi "$word" | wc -l)
  [ "$seen" -ge 2 ]
}

# A modal dialog holding focus swallows every keystroke, and the pane then looks
# exactly like a provider that answered nothing -- same symptom, opposite fix.
# Round 16 lost 20 consecutive launches and about nine hours to an opencode
# "Status / 23 MCP Servers" dialog that a container recreate left open: each
# probe typed into the dialog, `busy` never saw `esc interrupt`, and the driver
# blamed the provider every time. The provider was answering in 167ms.
#
# So a failed probe is no longer conclusive. Dismiss whatever holds focus and
# probe once more before declaring the provider dead.
#
# The nonce carries this run's PID, so it is unique per launch and not just per
# probe. A fixed word would be counted off the *previous* launch's pane: the
# supervisor relaunches the driver every couple of minutes, and in the failure
# this guard exists to catch nothing scrolls, so last launch's question and
# answer sit there ready to be miscounted as this one's. That reads as a healthy
# provider precisely when the provider is dead.
provider_ok() {
  local tag="PONG${$: -4}"
  _probe "${tag}A" && return 0
  echo "    no answer — dismissing anything holding focus and retrying" | tee -a "$LOG"
  docker exec $C tmux send-keys -t main Escape; sleep 3
  if _probe "${tag}B"; then
    echo "    a dialog had focus; dismissed, and the provider is answering" | tee -a "$LOG"
    return 0
  fi
  return 1
}

# A modal with focus hides the input box completely and swallows C-u, so this
# used to spin out all 15 tries and report "the input box will not clear" -- a
# message about a box too full, for a box that was not even on screen. That
# fires before send_prompt types anything, so send_prompt's own dialog recovery
# never got a chance to run; a test that opened the ctrl+p palette and expected
# recovery caught it failing here instead.
#
# One Escape per iteration dismisses whatever is on top. It is safe: this is
# only called when the session is idle, and with nothing on top Escape at worst
# clears the input, which is what C-u is doing anyway.
box_ready() {
  for _ in $(seq 1 15); do
    docker exec $C tmux capture-pane -p -t main 2>/dev/null | grep -q 'Ask anything' && return 0
    docker exec $C tmux send-keys -t main Escape 2>/dev/null
    docker exec $C tmux send-keys -t main C-u 2>/dev/null
    sleep 2
  done
  return 1
}

# Poll for the tail of the prompt rather than sampling once, and only press
# Enter when the last characters are on screen -- then confirm the model
# actually started, because typing the prompt and submitting it are two
# different things that fail separately.
send_prompt() {
  local text="$1" probe waited arrived submitted
  probe=$(printf '%s' "$text" | flat | tail -c 20)
  for attempt in 1 2 3; do
    if ! box_ready; then
      echo "    the input box will not clear (attempt $attempt)" | tee -a "$LOG"
      sleep 5
      continue
    fi
    docker exec $C tmux send-keys -t main -l "$text"
    waited=0
    arrived=0
    submitted=0
    # ARRIVAL_WINDOW was 90s, chosen when a prompt took ~33s to appear at about
    # 100 chars/sec. It no longer does. Measured across round 16's own log: 68
    # successful deliveries with a **median of 78s** and a maximum of 90 -- eight
    # of them landing on the ceiling exactly -- against **37 failures to arrive**.
    # Half of every prompt was finishing within twelve seconds of the timeout, so
    # any jitter dropped the phase, and the driver then blamed load, the
    # provider, or a dropped keystroke depending on which branch it hit. The
    # window was the bug in all of them.
    #
    # Throughput roughly halved (~45 chars/sec now); more MCP servers and a newer
    # TUI are both plausible and neither is worth chasing while the fix is a
    # number. 240s leaves real margin without letting a genuinely wedged session
    # sit for long -- box_ready and the submit check still bound the rest.
    while [ "$waited" -lt "${ARRIVAL_WINDOW:-240}" ]; do
      sleep 3; waited=$((waited + 3))
      case "$(docker exec $C tmux capture-pane -p -t main 2>/dev/null | flat)" in
        *"$probe"*) arrived=1; break ;;
      esac
    done
    # One send-keys Enter used to be the whole of "delivered": press it, log
    # success, return. Nothing checked that the model started. A starved TUI
    # drops the keystroke, the complete prompt sits in the box, busy() never
    # sees "esc interrupt", wait_idle returns its ~105s minimum and the phase
    # writes no report -- which is indistinguishable from a model that refused.
    # Round 16 died this way at phase 22: three such phases in a row tripped
    # the DRY guard with the entire prompt still legible on screen. Checking
    # that the prompt left the box does not work, since a submitted prompt is
    # still on screen as the conversation's first message; busy() is the
    # signal, and it turns true within ~5s of a real submit even under load.
    if [ "$arrived" -eq 1 ]; then
      for _ in 1 2 3 4 5 6; do
        docker exec $C tmux send-keys -t main Enter
        sleep 5
        if busy; then submitted=1; break; fi
      done
    fi
    # Three different faults produce the identical picture here -- a complete
    # prompt sitting in the box that will not go -- and they need opposite
    # responses, so the log has to say which:
    #
    #   the container is gone   `docker exec` fails silently, busy() is false,
    #                           and nothing above notices. Needs a restart, and
    #                           reporting it as a keystroke problem sent me
    #                           hunting a healthy provider for hours.
    #   a modal has focus       a dialog swallows Enter. Needs one Escape.
    #                           Round 16 lost 20 launches and ~9 hours to an
    #                           unnoticed "Status / 23 MCP Servers" dialog,
    #                           blamed on the provider every single time.
    #   the box is starved      the TUI cannot process the keystroke. Only
    #                           waiting fixes it.
    #
    # Escape is safe to send with a prompt in the box: worst case it clears the
    # input, and the next attempt retypes from scratch anyway.
    if [ "$arrived" -eq 1 ] && [ "$submitted" -eq 0 ]; then
      if ! alive; then
        echo "    the harness session is gone (attempt $attempt) — not a dropped keystroke" | tee -a "$LOG"
        ensure_alive || return 1
      else
        docker exec $C tmux send-keys -t main Escape
        sleep 3
        for _ in 1 2 3; do
          docker exec $C tmux send-keys -t main Enter
          sleep 5
          if busy; then submitted=1; break; fi
        done
        [ "$submitted" -eq 1 ] &&
          echo "    a dialog had focus; dismissed it and the prompt went (attempt $attempt)" | tee -a "$LOG"
      fi
    fi
    if [ "$submitted" -eq 1 ]; then
      echo "    prompt delivered in ${waited}s (attempt $attempt)" | tee -a "$LOG"
      return 0
    fi
    # State what was checked, not what it must therefore be. The previous
    # wording ended "so the box is starved (load N)" and printed that at load
    # 2.28 on an idle box -- asserting a cause the evidence contradicted, which
    # is worse than saying nothing. Liveness and the dialog really were ruled
    # out above; load is a number the reader can weigh.
    if [ "$arrived" -eq 1 ]; then
      echo "    typed in full but would not submit (attempt $attempt) — session alive, dialog ruled out," \
        "load $(cut -d' ' -f1 /proc/loadavg)" | tee -a "$LOG"
    else
      echo "    the prompt never finished arriving in ${ARRIVAL_WINDOW:-240}s (attempt $attempt) — retyping" |
        tee -a "$LOG"
    fi
    docker exec $C tmux send-keys -t main C-u
    sleep 5
  done
  echo "    COULD NOT DELIVER THE PROMPT — skipping this phase" | tee -a "$LOG"
  return 1
}

wait_idle() {
  sleep 45
  local max=${1:-200} quiet=0 said_blocked=0
  for i in $(seq 1 "$max"); do
    # Say it once, loudly. A phase parked on a permission prompt used to look
    # exactly like a phase thinking hard, for as long as the tick budget lasted.
    if [ "$said_blocked" -eq 0 ] && blocked_ask; then
      said_blocked=1
      echo "    WAITING ON A PERMISSION PROMPT — answer it in the session" | tee -a "$LOG"
    fi
    if busy; then quiet=0; else
      quiet=$((quiet + 1))
      [ "$quiet" -ge "$QUORUM" ] && { echo "    idle after ~$((45 + i * 15))s"; return 0; }
    fi
    sleep 15
  done
  echo "    TIMED OUT"; return 1
}

# How many table lines a report holds, header included -- the caller subtracts
# one. Two separate faults lived in the one-liner this replaces
# (`grep -c '^| ' f 2>/dev/null || echo 0`):
#
#   only one table style   Models write the rows both as `| tool | ... |` and as
#                          `tool | ... `, and anchoring on a leading pipe sees
#                          only the first. Ten of round 16's 66 reports were in
#                          the second style, every one of them complete and
#                          correct. Each cost its phase a SECOND full attempt
#                          redoing work already done, logged "nothing was
#                          written", and counted toward the three-in-a-row
#                          abort -- so a round could have been stopped dead by
#                          three good reports in a row.
#
#   grep -c exits 1 on 0   It prints "0" AND returns non-zero, so `|| echo 0`
#                          appended a second line and the variable became
#                          "0\n0". That is not an integer: `[ "$after" -gt 1 ]`
#                          failed with "integer expression expected" and the
#                          `rows:` arithmetic died with it, which is why the
#                          rows line simply vanished from the log for exactly
#                          those phases rather than printing a wrong number.
#
# Match a line carrying at least two pipes after an optional leading one, then
# drop markdown separator rows (|---|---|), which are decoration and would
# inflate the count by one for any model that writes them.
count_rows() {
  grep -E '^[[:space:]]*\|?[^|]*\|[^|]*\|' "$1" 2>/dev/null |
    grep -cvE '^[[:space:]|:*-]+$'
}

DRY=0   # consecutive phases that wrote nothing

echo "SWEEP $(basename "$PLAN") $(date -u +%FT%TZ) — phases $SEL" | tee -a "$LOG"

ensure_alive || exit 1
if provider_ok; then
  echo "provider answering" | tee -a "$LOG"
else
  echo "NO ANSWER TO A ONE-WORD PROMPT, TWICE — not starting the round" | tee -a "$LOG"
  echo "(every phase would write an empty report that looks like a model refusing)" | tee -a "$LOG"
  echo "(an Escape was sent between the two, so a dialog holding focus is ruled out;" | tee -a "$LOG"
  echo " look at the pane before blaming the model — quota exhaustion reads the same)" | tee -a "$LOG"
  exit 2
fi

while IFS=$'\t' read -r num label report ticks count prompt; do
  [ -z "$num" ] && continue
  case "$SEL" in
    all) ;;
    *) case "$WANTED" in *",$num,"*) ;; *) continue ;; esac ;;
  esac

  before=$(count_rows "$DATA/$report")
  {
    echo "=========================================================="
    echo "PHASE $num — $label   ($count tools)  had $before rows  [$(date -u +%H:%M:%SZ)]"
    echo "=========================================================="
  } | tee -a "$LOG"
  ensure_alive || exit 1

  # Start from an empty report so the row count means this run, not the last one.
  rm -f "$DATA/$report"

  lead="Start by calling the first tool right now. Do not reply with a plan, a summary of what you will do, or a question -- call the tools, then write the report."
  if [ "$before" -gt 1 ]; then
    lead="$lead An earlier attempt at this phase stopped after $((before - 1)) of $count tools, so pace yourself: keep each tool's check short and write its report row before moving to the next one."
  else
    lead="$lead Keep each tool's check short and write its report row before moving to the next one."
  fi

  after=0
  for try in 1 2; do
    [ "$try" -gt 1 ] && echo "    nothing was written — attempt $try" | tee -a "$LOG"
    # /new clears the session, and it does not do so instantly. A fixed sleep
    # raced it right after a container restart, when opencode is slow to come
    # up: the prompt was typed, send_prompt saw its own tail on screen and
    # pressed Enter, then /new completed and wiped it. The phase then looked
    # like a model that answered nothing. Wait for the session to go quiet and
    # for the empty box, rather than guessing how long it takes.
    send '/new'
    for _ in $(seq 1 20); do sleep 2; busy || break; done
    box_ready || echo "    the box did not settle after /new" | tee -a "$LOG"
    if ! send_prompt "$lead $prompt"; then
      echo "    the prompt never reached the session" | tee -a "$LOG"
      continue
    fi
    wait_idle "$ticks" | tee -a "$LOG"
    after=$(count_rows "$DATA/$report")
    [ "$after" -gt 1 ] && break
    ensure_alive || exit 1
  done

  echo "    rows: $((after > 0 ? after - 1 : 0)) of $count" | tee -a "$LOG"

  # A phase that writes nothing twice is almost never the model. Round 12 lost
  # seven phases in a row to a 25-minute provider outage, each in the minimum
  # 3.7 minutes, while the driver counted them done and moved on -- by the time
  # anyone looked, a quarter of the round had been consumed and would have to be
  # re-run anyway. Stop after three in a row and let a person look at it, rather
  # than spending the remaining phases discovering the same thing.
  if [ "$after" -le 1 ]; then
    if ! alive; then
      echo "    the session died during this phase — the empty report is not the model's doing" | tee -a "$LOG"
    fi
    DRY=$((DRY + 1))
    if [ "$DRY" -ge 3 ]; then
      echo "THREE PHASES IN A ROW WROTE NOTHING — STOPPING" | tee -a "$LOG"
      echo "(check the provider: docker exec $C tmux capture-pane -p -t main | tail)" | tee -a "$LOG"
      exit 3
    fi
  else
    DRY=0
  fi

  now=$(md5sum "$DATA/Ad_Data.csv" | cut -d' ' -f1)
  [ "$now" != "$PRISTINE" ] && { echo "    FIXTURE MUTATED — STOPPING" | tee -a "$LOG"; exit 1; }
  echo | tee -a "$LOG"
done < "$PLAN"

echo "SWEEP COMPLETE $(date -u +%FT%TZ)" | tee -a "$LOG"
