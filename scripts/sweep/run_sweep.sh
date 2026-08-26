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
C=harness-opencode
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
provider_ok() {
  docker exec $C tmux send-keys -t main C-u; sleep 2
  send 'Reply with exactly the word PONG and nothing else.'
  for _ in $(seq 1 20); do
    sleep 4
    busy || break
  done
  local seen
  seen=$(docker exec $C tmux capture-pane -p -t main | grep -oi 'pong' | wc -l)
  [ "$seen" -ge 2 ]
}

box_ready() {
  for _ in $(seq 1 15); do
    docker exec $C tmux capture-pane -p -t main 2>/dev/null | grep -q 'Ask anything' && return 0
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
    while [ "$waited" -lt 90 ]; do
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
    if [ "$submitted" -eq 1 ]; then
      echo "    prompt delivered in ${waited}s (attempt $attempt)" | tee -a "$LOG"
      return 0
    fi
    if [ "$arrived" -eq 1 ]; then
      echo "    typed in full but would not submit (attempt $attempt) — the session is dropping keys" | tee -a "$LOG"
    else
      echo "    the prompt never finished arriving in 90s (attempt $attempt) — retyping" | tee -a "$LOG"
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

DRY=0   # consecutive phases that wrote nothing

echo "SWEEP $(basename "$PLAN") $(date -u +%FT%TZ) — phases $SEL" | tee -a "$LOG"

ensure_alive || exit 1
if provider_ok; then
  echo "provider answering" | tee -a "$LOG"
else
  echo "PROVIDER RETURNED NOTHING TO A ONE-WORD PROMPT — not starting the round" | tee -a "$LOG"
  echo "(every phase would write an empty report that looks like a model refusing)" | tee -a "$LOG"
  exit 2
fi

while IFS=$'\t' read -r num label report ticks count prompt; do
  [ -z "$num" ] && continue
  case "$SEL" in
    all) ;;
    *) case "$WANTED" in *",$num,"*) ;; *) continue ;; esac ;;
  esac

  before=$(grep -c '^| ' "$DATA/$report" 2>/dev/null || echo 0)
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
    after=$(grep -c '^| ' "$DATA/$report" 2>/dev/null || echo 0)
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
