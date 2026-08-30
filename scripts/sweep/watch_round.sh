#!/bin/bash
# Keep a round's ledger current while the driver runs, and stop when it stops.
#
#     setsid nohup ./watch_round.sh 22 <driver-pid> >> watch_r22.log 2>&1 </dev/null &
#
# A round restarted onto a second driver log -- a provider running out of quota
# mid-round is the usual reason -- names every log after the pid, oldest first:
#
#     setsid nohup ./watch_round.sh 22 <pid> sweep_r22.log sweep_r22b.log ...
#
# The LAST one named is the one watched for the round's end, because that is
# the one the live driver is writing; all of them are passed to the ledger, so
# the phases the first driver finished keep their verdicts.
#
# Must be launched with setsid, exactly like run_sweep.sh: a Claude Code
# background task gets reaped mid-round with nothing in any log to explain it,
# which is how the first attempt at this died eleven minutes in.
#
# Liveness is checked by PID, not by matching a command line, for two reasons
# that have each cost time:
#
#   the anchor    `ps -eo args` prints "/bin/bash ./run_sweep.sh ...", so a
#                 pattern anchored with ^bash never matches and the watcher
#                 reports a healthy driver as gone.
#   the self-match  this script's own command line contains whatever pattern it
#                 would grep for, so the naive fix reports a dead driver as
#                 alive -- wrong in the opposite direction, and silently.
set -uo pipefail
SP="$(cd "$(dirname "$0")" && pwd)"
ROUND=${1:?usage: watch_round.sh <round> <driver-pid> [log ...]}
DPID=${2:?usage: watch_round.sh <round> <driver-pid> [log ...]}
shift 2
LOGS=("$@")
[ ${#LOGS[@]} -eq 0 ] && LOGS=("sweep_r${ROUND}.log")
LOG="$SP/${LOGS[-1]}"
LEDGER_ARGS=()
for name in "${LOGS[@]}"; do LEDGER_ARGS+=(--log "$name"); done
EVERY=${EVERY:-300}
# 108 x 5 min = 9 hours. A bound, not a schedule: the round ends this loop long
# before it, and nothing here should outlive the round it is reporting on. One
# tail -F once survived 27 hours.
MAX=${MAX:-108}

for i in $(seq 1 "$MAX"); do
  python3 "$SP/ledger_update.py" --round "$ROUND" "${LEDGER_ARGS[@]}" || true
  if grep -qE 'SWEEP COMPLETE|WROTE NOTHING — STOPPING|FIXTURE MUTATED|not starting the round' "$LOG" 2>/dev/null; then
    echo "round $ROUND ended (log says so) after $i checks"
    break
  fi
  if ! kill -0 "$DPID" 2>/dev/null; then
    echo "driver pid $DPID is gone after $i checks — the round did not finish on its own"
    break
  fi
  sleep "$EVERY"
done

python3 "$SP/ledger_update.py" --round "$ROUND" "${LEDGER_ARGS[@]}"
echo "--- final log tail ---"
tail -30 "$LOG"
