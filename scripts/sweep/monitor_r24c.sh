#!/usr/bin/env bash
# Round 24's end-condition watch, as a detached process rather than a Claude
# Code background task. Two of those were reaped in a row by the host's
# low-memory guard -- the same reason run_sweep.sh itself has always been
# launched with setsid. Writes one status line to STATUS and exits when the
# round ends, the driver dies, or nothing completes for ~48 minutes.
set -uo pipefail
SP="$(cd "$(dirname "$0")" && pwd)"
cd "$SP"
DPID=${1:?usage: monitor_r24c.sh <driver-pid>}
LOG=sweep_r24c.log
STATUS=$SP/STATUS_r24.txt
last=""; stall=0
for _ in $(seq 1 300); do
  if grep -qE 'SWEEP COMPLETE|WROTE NOTHING — STOPPING|FIXTURE MUTATED' "$LOG" 2>/dev/null; then
    echo "[$(date -u +%H:%M:%SZ)] ENDED: $(grep -oE 'SWEEP COMPLETE.*|WROTE NOTHING.*' "$LOG" | tail -1)" > "$STATUS"
    exit 0
  fi
  if ! kill -0 "$DPID" 2>/dev/null; then
    echo "[$(date -u +%H:%M:%SZ)] DRIVER GONE (pid $DPID) with no completion line" > "$STATUS"
    exit 0
  fi
  now=$(grep -cE '^    rows:' "$LOG" 2>/dev/null)
  if [ "$now" = "$last" ]; then stall=$((stall + 1)); else stall=0; last=$now; fi
  if [ "$stall" -ge 24 ]; then
    echo "[$(date -u +%H:%M:%SZ)] STALLED: no phase completed in ~48 min (phases done: $now)" > "$STATUS"
    exit 0
  fi
  echo "[$(date -u +%H:%M:%SZ)] running — $now phases complete in this leg" > "$STATUS"
  sleep 120
done
echo "[$(date -u +%H:%M:%SZ)] monitor hit its own bound; round still going" > "$STATUS"
