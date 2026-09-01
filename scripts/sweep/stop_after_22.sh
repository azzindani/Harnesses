#!/usr/bin/env bash
# Cut round 23b after phase 22, on the user's call: the four starved phases are
# the work that has never been done, and the three fixed-tool phases behind them
# are already covered by verify_r23_fixes.sh (12/12 against the live server).
#
# Waits for the PHASE 32 banner rather than parsing phase 22's own rows line --
# the banner is the unambiguous "22 is finished" signal. The driver will have
# just begun typing 32's prompt, so the TUI is left dirty; a half-typed prompt
# is what made the pre-flight refuse to start earlier today. So this parks the
# session db and restarts the container, leaving it clean for the next round.
set -uo pipefail
cd /root/Harnesses/scripts/sweep || exit 1

DRIVER=$1
LOG=sweep_r23fix.log

while kill -0 "$DRIVER" 2>/dev/null; do
  if grep -q "^PHASE 32" "$LOG" 2>/dev/null; then
    echo "$(date -u +%FT%TZ) phase 22 complete, phase 32 starting -- cutting the round here"
    pkill -f "watch_round.sh 23fix" 2>/dev/null
    kill "$DRIVER" 2>/dev/null
    sleep 3
    pkill -P "$DRIVER" 2>/dev/null
    sleep 2
    docker stop harness-sweep >/dev/null 2>&1
    TS=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "/root/Harnesses/history/sweep/old-$TS"
    mv /root/Harnesses/history/sweep/state/opencode.db* "/root/Harnesses/history/sweep/old-$TS/" 2>/dev/null
    docker start harness-sweep >/dev/null 2>&1
    echo "$(date -u +%FT%TZ) driver stopped, TUI reset (db -> history/sweep/old-$TS)"
    exit 0
  fi
  sleep 20
done
echo "$(date -u +%FT%TZ) driver exited on its own before phase 32"
