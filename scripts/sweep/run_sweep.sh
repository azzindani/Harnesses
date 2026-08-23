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

busy() { docker exec $C tmux capture-pane -p -t main 2>/dev/null | grep -q 'esc interrupt'; }

alive() {
  docker ps --filter "name=^${C}$" --filter status=running --format '{{.Names}}' | grep -q "^${C}$" \
    && docker exec $C tmux has-session -t main 2>/dev/null
}

ensure_alive() {
  alive && return 0
  echo "    harness container or tmux session is down — restarting" | tee -a "$LOG"
  (cd /root/Harnesses && docker compose up -d $C) >/dev/null 2>&1
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
# Enter when the last characters are on screen.
send_prompt() {
  local text="$1" probe waited
  probe=$(printf '%s' "$text" | flat | tail -c 20)
  for attempt in 1 2 3; do
    if ! box_ready; then
      echo "    the input box will not clear (attempt $attempt)" | tee -a "$LOG"
      sleep 5
      continue
    fi
    docker exec $C tmux send-keys -t main -l "$text"
    waited=0
    while [ "$waited" -lt 90 ]; do
      sleep 3; waited=$((waited + 3))
      case "$(docker exec $C tmux capture-pane -p -t main 2>/dev/null | flat)" in
        *"$probe"*)
          docker exec $C tmux send-keys -t main Enter
          echo "    prompt delivered in ${waited}s (attempt $attempt)" | tee -a "$LOG"
          return 0 ;;
      esac
    done
    echo "    the prompt never finished arriving in 90s (attempt $attempt) — retyping" | tee -a "$LOG"
    docker exec $C tmux send-keys -t main C-u
    sleep 5
  done
  echo "    COULD NOT DELIVER THE PROMPT — skipping this phase" | tee -a "$LOG"
  return 1
}

wait_idle() {
  sleep 45
  local max=${1:-200} quiet=0
  for i in $(seq 1 "$max"); do
    if busy; then quiet=0; else
      quiet=$((quiet + 1))
      [ "$quiet" -ge "$QUORUM" ] && { echo "    idle after ~$((45 + i * 15))s"; return 0; }
    fi
    sleep 15
  done
  echo "    TIMED OUT"; return 1
}

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

  send '/new'; sleep 12
  if ! send_prompt "$lead $prompt"; then
    echo "    rows: not attempted (the prompt never reached the session)" | tee -a "$LOG"
    echo | tee -a "$LOG"
    continue
  fi
  wait_idle "$ticks" | tee -a "$LOG"

  after=$(grep -c '^| ' "$DATA/$report" 2>/dev/null || echo 0)
  echo "    rows: $((after > 0 ? after - 1 : 0)) of $count" | tee -a "$LOG"
  if [ "$after" -le 1 ] && ! alive; then
    echo "    the session died during this phase — the empty report is not the model's doing" | tee -a "$LOG"
  fi

  now=$(md5sum "$DATA/Ad_Data.csv" | cut -d' ' -f1)
  [ "$now" != "$PRISTINE" ] && { echo "    FIXTURE MUTATED — STOPPING" | tee -a "$LOG"; exit 1; }
  echo | tee -a "$LOG"
done < "$PLAN"

echo "SWEEP COMPLETE $(date -u +%FT%TZ)" | tee -a "$LOG"
