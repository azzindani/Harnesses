#!/usr/bin/env bash
# Does the driver's row counter see a report written in either table style?
#
#     ./test_count_rows.sh
#
# The counter this guards replaced one that anchored on a leading pipe. Models
# write the table BOTH ways -- "| tool | ... |" and "tool | ... " -- so a
# complete report in the second style read as "nothing was written": the phase
# burned a second full attempt redoing work it had already done correctly, and
# it counted toward the three-consecutive-empties abort, so a round could have
# been stopped dead by three good reports in a row. Ten of round 16's sixty-six
# reports were in that style.
#
# The same one-liner had a second fault: `grep -c` prints "0" AND exits 1 when
# it counts nothing, so `|| echo 0` appended a second line. The variable became
# "0\n0", `[ "$after" -gt 1 ]` failed with "integer expression expected", and
# the `rows:` line vanished from the log for exactly those phases -- absence
# rather than a wrong number, which is why it went unnoticed for a whole round.
#
# This is the third tool to carry that leading-pipe assumption (strict_coverage
# and check_coverage were the others), which is why it is a tracked test rather
# than a third one-off fix.
#
# Offline and container-free, so CI runs it. The real-corpus case is skipped
# where the reports are not on disk.
set -u
SP="$(cd "$(dirname "$0")" && pwd)"
DATA=${DATA:-/root/Harnesses/data}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract the function from the shipping script on every run. A retyped copy
# drifts, and this test would then pass against code nobody runs.
sed -n '/^count_rows() {/,/^}/p' "$SP/run_sweep.sh" > "$TMP/fn.sh"
[ -s "$TMP/fn.sh" ] || { echo "FAIL: could not extract count_rows from run_sweep.sh"; exit 1; }
# shellcheck disable=SC1090
. "$TMP/fn.sh"

# The counter as it was before the fix, so the comparison is demonstrated
# rather than remembered.
old_count() { grep -c '^| ' "$1" 2>/dev/null || echo 0; }

fail() { echo "FAIL: $*"; exit 1; }
pass=0

echo "=== case A: the style that was invisible (no leading pipe) ==="
cat > "$TMP/nolead.md" <<'EOF'
tool name | file it wrote | holds what was claimed? | notes
set_cell | /workspace/data/a.xlsx | Yes | stored as number
set_range | /workspace/data/a.xlsx | Yes | 3 rows
copy_sheet | /workspace/data/a.xlsx | Yes | chart came with it
EOF
o=$(old_count "$TMP/nolead.md"); n=$(count_rows "$TMP/nolead.md")
echo "    old: $(echo "$o" | tr '\n' ' ') | new: $n  (want 4 = header + 3 rows)"
[ "$n" = "4" ] || fail "new counter got $n, want 4"
[ "$(echo "$o" | head -1)" = "0" ] || fail "old counter was supposed to fail here; got $o"
echo "    the old counter really did read this complete report as empty"
pass=$((pass + 1))

echo
echo "=== case B: the style that already worked still works ==="
cat > "$TMP/lead.md" <<'EOF'
| tool name | file it wrote | holds what was claimed? | notes |
| set_cell | /workspace/data/a.xlsx | Yes | stored as number |
| set_range | /workspace/data/a.xlsx | Yes | 3 rows |
EOF
o=$(old_count "$TMP/lead.md"); n=$(count_rows "$TMP/lead.md")
echo "    old: $o | new: $n  (want 3 = header + 2 rows)"
[ "$n" = "3" ] || fail "regression: new counter got $n, want 3"
[ "$o" = "3" ] || fail "old counter got $o here, expected 3"
echo "    no regression on the style the old counter understood"
pass=$((pass + 1))

echo
echo "=== case C: a markdown separator row must not inflate the count ==="
cat > "$TMP/sep.md" <<'EOF'
| tool | file | ok? |
|------|------|-----|
| set_cell | a.xlsx | Yes |
EOF
n=$(count_rows "$TMP/sep.md")
echo "    new: $n  (want 2 = header + 1 row, separator excluded)"
[ "$n" = "2" ] || fail "separator row counted; got $n, want 2"
pass=$((pass + 1))

echo
echo "=== case D: the result must be a usable integer, not \"0\\n0\" ==="
: > "$TMP/empty.md"
for f in "$TMP/empty.md" "$TMP/does_not_exist.md"; do
  n=$(count_rows "$f")
  label=$(basename "$f")
  [ "$(printf '%s' "$n" | tr -d '[:space:]')" = "0" ] || fail "$label gave '$n', want 0"
  [ "$(printf '%s' "$n" | wc -l)" = "0" ] || fail "$label returned more than one line"
  # the exact expressions the driver runs on this value
  [ "$n" -gt 1 ] 2>/dev/null
  rc=$?
  [ "$rc" -le 1 ] || fail "$label: [ -gt ] errored ('integer expression expected')"
  got=$((n > 0 ? n - 1 : 0)) || fail "$label: the rows arithmetic failed"
  echo "    $label -> '$n', [ -gt ] rc=$rc, rows arithmetic = $got"
done
o=$(old_count "$TMP/empty.md")
[ "$(printf '%s' "$o" | wc -l)" -ge 1 ] || fail "old counter was supposed to return two lines here"
echo "    the old counter returned $(printf '%s' "$o" | tr '\n' '/') — two lines, which is what broke the log"
pass=$((pass + 1))

echo
echo "=== case E: real reports on disk — every one must be seen ==="
corpus=$(find "$DATA" -maxdepth 1 -name 'report_r1*.md' 2>/dev/null | wc -l)
if [ "$corpus" -lt 20 ]; then
  echo "    SKIPPED: only $corpus reports under $DATA (needs the sweep's own output)"
else
  missed_old=0; missed_new=0
  for f in "$DATA"/report_r1*.md; do
    [ -f "$f" ] || continue
    [ "$(old_count "$f" | head -1)" -lt 2 ] && missed_old=$((missed_old + 1))
    if [ "$(count_rows "$f")" -lt 2 ]; then
      missed_new=$((missed_new + 1)); echo "    still unseen: $(basename "$f")"
    fi
  done
  echo "    $corpus real reports: old counter missed $missed_old, new counter missed $missed_new"
  [ "$missed_old" -gt 0 ] || fail "the old counter missed none — this corpus cannot show the defect"
  [ "$missed_new" = "0" ] || fail "$missed_new real reports are still invisible"
  pass=$((pass + 1))
fi

echo
echo "=== case F: a genuinely empty report is still empty ==="
# The fix must not make every phase look successful; that would hide the
# failure the retry exists to catch.
printf 'I was unable to complete this phase.\n' > "$TMP/prose.md"
n=$(count_rows "$TMP/prose.md")
echo "    prose-only report -> $n (want 0, so the retry still fires)"
[ "$n" = "0" ] || fail "prose counted as a table row; got $n"
pass=$((pass + 1))

echo
echo "ALL $pass COUNT-ROWS CHECKS PASSED"
