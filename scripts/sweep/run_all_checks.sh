#!/usr/bin/env bash
# Every checker in this directory, against the deployed fleet, in one pass.
#
#   ./run_all_checks.sh [output-dir]
#
# Exits non-zero if any checker does. Each one reports its tally in its own
# words, so the summary quotes whichever line it uses rather than imposing a
# format on fifteen files written across as many rounds.
#
# Deliberately NOT included: run_sweep.sh (the container-based sweep driver),
# refresh_tools.sh, monitor_round.sh, watch_round.sh, chain_r24c.sh,
# stop_after_22.sh. Those drive or observe a round; they do not check anything.
#
# A run takes about a minute and a half. Ad_Data.csv is checked before and
# after: it is the designated fixture and nothing here may write to it.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
OUT="${1:-$(mktemp -d)}"
mkdir -p "$OUT"
: >"$OUT/rc.tsv"

FIXTURE=/root/Harnesses/data/Ad_Data.csv
MD5_BEFORE=$(md5sum "$FIXTURE" | cut -d' ' -f1)

run() { # run <name> <command...>
  local name="$1"; shift
  local start end rc
  start=$(date +%s)
  timeout 1800 "$@" >"$OUT/$name.log" 2>&1
  rc=$?
  end=$(date +%s)
  printf '%s\t%s\t%s\n' "$name" "$rc" "$((end - start))" >>"$OUT/rc.tsv"
}

# The two fleet-wide probes first: they are the ones that would catch a broken
# deploy, and there is no point running twelve fixture checks against a fleet
# that is not answering.
run unknown_arg_sweep  python3 unknown_arg_sweep.py "$OUT/unknown_arg.tsv"
run dispatch_probe     python3 dispatch_probe.py
run verify_r29_enums   bash verify_r29_enums.sh
run verify_r28_fixes   bash verify_r28_fixes.sh
run verify_r27_fixes   bash verify_r27_fixes.sh
run verify_r25_fixes   bash verify_r25_fixes.sh
run verify_r24_shipped bash verify_r24_shipped.sh
run verify_r24_fixes   bash verify_r24_fixes.sh
run verify_r23_fixes   bash verify_r23_fixes.sh
run verify_r19b        bash verify_r19b.sh
run verify_r18         bash verify_r18.sh
run verify_r17         bash verify_r17.sh
run verify_r16b        bash verify_r16b.sh
run verify_n1          bash verify_n1.sh
run verify_vocab       bash verify_vocab.sh

MD5_AFTER=$(md5sum "$FIXTURE" | cut -d' ' -f1)

FAILED=0
echo "=============================================================="
printf '%-20s %5s %5s  %s\n' CHECKER EXIT SECS RESULT
echo "--------------------------------------------------------------"
while IFS=$'\t' read -r name rc secs; do
  summary=$(grep -aoE "PASSED [0-9]+ +FAILED [0-9]+|ALL [A-Z].*|ALL [0-9]+ [a-z].*|FAILED: .*|all [a-z].* passed|PASS=[0-9]+ FAIL=[0-9]+|[0-9]+ passed, [0-9]+ failed|[0-9]+ CHECK\(S\) FAILED" \
      "$OUT/$name.log" | tail -1)
  [ -z "$summary" ] && summary=$(tail -1 "$OUT/$name.log" | cut -c1-70)
  printf '%-20s %5s %5s  %s\n' "$name" "$rc" "$secs" "$summary"
  [ "$rc" -ne 0 ] && FAILED=$((FAILED + 1))
done <"$OUT/rc.tsv"
echo "--------------------------------------------------------------"

if [ "$MD5_BEFORE" = "$MD5_AFTER" ]; then
  echo "Ad_Data.csv  $MD5_AFTER  unchanged"
else
  echo "Ad_Data.csv  *** MODIFIED ***  $MD5_BEFORE -> $MD5_AFTER"
  FAILED=$((FAILED + 1))
fi
echo "logs: $OUT"

# Put the exchange back the way it was found.
#
# A full run writes about 100MB into /root/Harnesses/data -- trained models,
# rendered charts, their sidecars, the per-checker fixture directories, and
# `.mcp_versions`, the fleet's snapshot store, which every destructive write
# appends to and nothing ever trims. That directory is served read-only at
# files.<domain>, so the residue is not just disk: it is what a person sees
# when they open the file browser, and after enough rounds the fixtures are
# lost in it.
#
# Every checker here builds its own inputs -- verified by quarantining all 59
# non-fixture entries and re-running: 15/15 still passed. So the only things
# that must survive a run are the source fixtures listed below.
#
# `KEEP_OUTPUT=1 ./run_all_checks.sh` skips this, for when a failure needs the
# artifacts inspected.
FIXTURES="Ad_Data.csv Ad_Data.csv.mcp_receipt.json v27_rates.csv BBCA_filing.pdf v27_open.docx r28d .gitkeep"
if [ "${KEEP_OUTPUT:-0}" = "1" ]; then
  echo "output kept (KEEP_OUTPUT=1): $(du -sh /root/Harnesses/data | cut -f1)"
else
  removed=0
  for entry in $(ls -A /root/Harnesses/data); do
    case " $FIXTURES " in *" $entry "*) continue ;; esac
    case "$entry" in report_*.md) continue ;; esac
    rm -rf -- "/root/Harnesses/data/${entry:?}" && removed=$((removed + 1))
  done
  echo "exchange: $removed generated entr(ies) cleared, $(du -sh /root/Harnesses/data | cut -f1) of fixtures kept"
fi

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "$FAILED checker(s) failed. Read the log before filing anything: three of"
  echo "these have failed on their own staleness -- missing fixtures, a renamed"
  echo "argument, an escaped quote -- and reported it as the fleet's problem."
  exit 1
fi
echo
echo "ALL 15 CHECKERS PASSED"
