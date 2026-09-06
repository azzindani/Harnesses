#!/usr/bin/env bash
# Wait for the phase-23 canary to finish, then run the rest of round 24 without
# anyone watching it.
#
#     setsid nohup ./chain_r24c.sh >> chain_r24c.log 2>&1 </dev/null &
#
# Two drivers must never share the tmux session, so this waits for the canary's
# driver to exit before starting the main run rather than launching both.
#
# The canary exists because a switched model can close phases permanently with
# shallow evidence: check_coverage marks a thin report DONE and DONE is not
# revisited. If phase 23 comes back empty the model is not answering and the
# rest of the round is not worth spending, so this stops instead of proceeding.
set -uo pipefail
SP="$(cd "$(dirname "$0")" && pwd)"
cd "$SP"

CANARY_LOG=sweep_r24c_canary.log
MAIN_LOG=sweep_r24c.log
PLAN=$SP/phases_r24b.tsv
DATA=/root/Harnesses/data
REST=24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45

say() { echo "[$(date -u +%H:%M:%SZ)] $*"; }

say "waiting for the canary driver to exit"
for _ in $(seq 1 240); do
  ps -eo args | grep -qE "bash \./run_sweep\.sh 23$" || break
  sleep 15
done

ROWS=$(grep -oE 'rows: [0-9]+ of [0-9]+' "$CANARY_LOG" 2>/dev/null | tail -1)
say "canary finished — $ROWS"

REPORT=$DATA/report_r24b_ml_basic_1.md
if [ ! -s "$REPORT" ]; then
  say "ABORT: the canary wrote no report; the model is not answering"
  exit 1
fi
WROTE=$(grep -cE '^[^|]+\|.*\|' "$REPORT" 2>/dev/null || echo 0)
if [ "$WROTE" -lt 3 ]; then
  say "ABORT: the canary report has $WROTE rows; too thin to trust the model with 22 more phases"
  exit 1
fi
say "canary report has $WROTE rows — proceeding"

say "launching phases $REST"
setsid nohup env PLAN="$PLAN" LOG="$SP/$MAIN_LOG" ARRIVAL_WINDOW=480 \
  ./run_sweep.sh "$REST" >> "$SP/sweep_r24c.nohup" 2>&1 </dev/null &
sleep 5
DPID=$(ps -eo pid,args | grep -E "bash \./run_sweep\.sh $REST" | grep -v grep | awk '{print $1}' | head -1)
if [ -z "$DPID" ]; then
  say "ABORT: the driver did not start"
  exit 1
fi
say "driver pid $DPID (sid $(ps -o sid= -p "$DPID" | tr -d ' '))"

# Every log the round has written, so phases finished under an earlier model
# keep their verdicts. The LAST one named is the one watched for the end.
setsid nohup ./watch_round.sh 24 "$DPID" sweep_r24.log sweep_r24b.log "$MAIN_LOG" \
  >> watch_r24c.log 2>&1 </dev/null &
say "watcher started; nothing else needs a person until it ends"
