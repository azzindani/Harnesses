#!/usr/bin/env bash
# Re-check every fix made during round 17, against the live endpoints.
#
#     ./verify_r17.sh
#
# Why this exists instead of re-running the phases that found the defects.
#
# Round 17's axis is "hand the file to a different server". That is the right
# question for judging the fleet and the wrong one for judging a fix: the model
# picks its own inputs, and in the r16b pass it picked the branch the fix did
# NOT change four times out of four -- a 2D chart for a 3D-axis fix, a
# run_preprocessing call with zero ops, add_table on a document that already
# had paragraphs. Every one of those phases passed without executing a line of
# the changed code. Re-running phase 22 for the z-axis fix would very likely
# build another 2D chart and report green.
#
# So these checks name the exact string each fix introduced and build the state
# that used to fail. Direct curl rather than the opencode harness, because this
# confirms a DEPLOYMENT rather than exercising a model.
#
# Copy this per round rather than extending it: a check naming a specific fix's
# string stops meaning anything once that fix is old.
#
# Covers, in order:
#   97eeaf7  json_safe        Infinity/NaN made a whole payload unparseable
#   dacd79f  z_label          a 3D chart could not label its third axis
#   9e884fa / cc14af0 / 566a191   token_estimate was a literal, never measured
#   e7ec243  hint_for_message a hint that argued with the error above it
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA_BASE=$(get DATA_MCP_BASE_URL); DATA_TOK=$(get DATA_MCP_TOKEN)
ML_BASE=$(get ML_MCP_BASE_URL);     ML_TOK=$(get ML_MCP_TOKEN)
OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)

DIR=/workspace/data/r17_verify          # as the servers see it
HOST=/root/Harnesses/data/r17_verify    # the same bytes, as this script sees them
PASS=0; FAIL=0

call() {
  local url="$1" tok="$2" tool="$3" args="$4" hdr sid
  hdr=$(mktemp)
  curl -s -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
    -D "$hdr" >/dev/null
  sid=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdr"
  [ -z "$sid" ] && { echo "NO_SESSION"; return 1; }
  curl -s -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
    | tr -d '\r' | grep '^data:' | sed 's/^data: //'
}

# check <label> <url> <tok> <tool> <args> <pattern-that-must-appear>
# Patterns must tolerate both JSON styles: some servers pretty-print
# ("success": true) and the payload also arrives escaped inside the MCP
# envelope (\"success\": true). Hence the \\? and the optional space.
check() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" want="$6" out
  out=$(call "$url" "$tok" "$tool" "$args")
  if grep -qE "$want" <<<"$out"; then
    printf 'PASS  %-52s /%s/\n' "$label" "$want"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s wanted /%s/\n' "$label" "$want"
    printf '      %.400s\n' "$out"; FAIL=$((FAIL + 1))
  fi
}

check_absent() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" bad="$6" out
  out=$(call "$url" "$tok" "$tool" "$args")
  if grep -qE "$bad" <<<"$out"; then
    printf 'FAIL  %-52s must NOT match /%s/\n' "$label" "$bad"
    printf '      %.400s\n' "$out"; FAIL=$((FAIL + 1))
  else
    printf 'PASS  %-52s absent /%s/\n' "$label" "$bad"; PASS=$((PASS + 1))
  fi
}

check_file() {
  local label="$1" path="$2" want="$3" expect="$4" hit=no
  [ -f "$path" ] && grep -qE "$want" "$path" && hit=yes
  if [ "$hit" = "$expect" ]; then
    printf 'PASS  %-52s file %s /%s/\n' "$label" "$expect" "$want"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s wanted %s /%s/ in %s\n' "$label" "$expect" "$want" "$path"; FAIL=$((FAIL + 1))
  fi
}

# The one assertion Python cannot make about itself.
#
# Python's json encoder writes Infinity/NaN as bare tokens by extension, and its
# decoder accepts them again, so a payload carrying them round-trips perfectly
# inside Python and every test in these repos is Python. `parse_constant` is the
# hook that turns that silent acceptance into a failure -- it is what a
# JavaScript, Go or Rust client does natively.
#
# This unwraps the MCP envelope first, because the envelope itself is valid JSON
# whatever the tool put inside it: the tool's own dict arrives as a STRING in
# result.content[0].text, so a strict parse of the outer object proves nothing.
check_strict_json() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" out
  out=$(call "$url" "$tok" "$tool" "$args")
  if printf '%s' "$out" | python3 -c '
import json, sys

def boom(tok):
    raise ValueError("non-JSON constant: " + tok)

raw = sys.stdin.read().strip()
if not raw:
    print("empty response"); sys.exit(1)
env = json.loads(raw.splitlines()[0])
text = env["result"]["content"][0]["text"]
json.loads(text, parse_constant=boom)
' 2>/dev/null; then
    printf 'PASS  %-52s strict JSON parse accepted\n' "$label"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s strict JSON parse REJECTED\n' "$label"
    printf '      %.400s\n' "$out"; FAIL=$((FAIL + 1))
  fi
}

# token_estimate must describe the response carrying it.
#
# CLAUDE.md defines it as len(str(response)) // 4. That exact number cannot be
# reproduced from outside -- str() of a Python dict is not the JSON text on the
# wire -- so this checks the property that a hardcoded literal cannot have: the
# estimate has to track the payload's actual size. A constant 15 against a
# 205-character refusal gives a ratio near 3.4; a measured one sits near 4 by
# construction. The window is wide (2.0-8.0) on purpose: it is not trying to
# re-derive the formula, only to catch a number that was typed in.
check_measured() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" out
  out=$(call "$url" "$tok" "$tool" "$args")
  local verdict
  verdict=$(printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("FAIL empty response"); sys.exit(0)
try:
    env = json.loads(raw.splitlines()[0])
    text = env["result"]["content"][0]["text"]
    payload = json.loads(text)
except Exception as e:
    print("FAIL could not read payload: %s" % e); sys.exit(0)
te = payload.get("token_estimate")
if te is None:
    print("FAIL no token_estimate field"); sys.exit(0)
if not isinstance(te, int) or te <= 0:
    print("FAIL token_estimate is %r" % (te,)); sys.exit(0)
ratio = len(text) / te
if 2.0 <= ratio <= 8.0:
    print("PASS %d for %d chars (ratio %.1f)" % (te, len(text), ratio))
else:
    print("FAIL %d for %d chars (ratio %.1f, outside 2.0-8.0)" % (te, len(text), ratio))
' 2>/dev/null)
  case "$verdict" in
    PASS*) printf 'PASS  %-52s %s\n' "$label" "${verdict#PASS }"; PASS=$((PASS + 1)) ;;
    *)     printf 'FAIL  %-52s %s\n' "$label" "${verdict#FAIL }"; FAIL=$((FAIL + 1)) ;;
  esac
}

_token_estimate_of() {
  call "$1" "$2" "$3" "$4" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    env = json.loads(raw.splitlines()[0])
    print(json.loads(env["result"]["content"][0]["text"])["token_estimate"])
except Exception:
    print("")
' 2>/dev/null
}

# The hole the ratio check cannot close.
#
# A hardcoded literal is wrong BY CONSTRUCTION, but on a short enough response
# the constant happens to land inside any sane ratio window -- a literal 15
# against a 60-character reply gives exactly 4.0 and passes. Measured against
# the real pre-fix numbers the window catches the cases that mattered (15 for
# ~205, 20 for ~816) and would have missed a short one.
#
# So: call one tool twice, with arguments that produce very different response
# sizes. A measured estimate MUST change; a literal cannot. No window, no
# tuning, and it fails on any tool whose number is still typed in.
check_varies() {
  local label="$1" url="$2" tok="$3" tool="$4" args_a="$5" args_b="$6" a b
  a=$(_token_estimate_of "$url" "$tok" "$tool" "$args_a")
  b=$(_token_estimate_of "$url" "$tok" "$tool" "$args_b")
  if [ -z "$a" ] || [ -z "$b" ]; then
    printf 'FAIL  %-52s could not read token_estimate (a=%s b=%s)\n' "$label" "${a:-?}" "${b:-?}"
    FAIL=$((FAIL + 1)); return
  fi
  if [ "$a" != "$b" ]; then
    printf 'PASS  %-52s %s then %s — it tracks the payload\n' "$label" "$a" "$b"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s %s both times — this is a constant\n' "$label" "$a"; FAIL=$((FAIL + 1))
  fi
}

# A root-owned 755 fixture directory makes every write tool return
# "[Errno 13] Permission denied" on a path it reads from perfectly well.
rm -rf "$HOST"; mkdir -p "$HOST"; chgrp 999 "$HOST" 2>/dev/null; chmod g+w "$HOST"

# pandas parses the literals inf/-inf/nan into the same floats a division by
# zero produces, so the column arrives non-finite without depending on any
# tool's op vocabulary to build it. The original discovery route was
# apply_patch column_math over a zero denominator; this is the same value with
# fewer moving parts, and `den` keeps that route available by hand.
printf 'name,num,den,ratio\na,10,0,inf\nb,5,0,-inf\nc,7,2,3.5\nd,1,1,nan\n' > "$HOST/nonfinite.csv"
printf 'name,qty\na,1\nb,2\na,3\nc,4\nb,5\n' > "$HOST/plain.csv"
chgrp 999 "$HOST"/*.csv 2>/dev/null; chmod g+w "$HOST"/*.csv

echo "=== 97eeaf7 — Infinity/NaN are not JSON, and took the whole payload with them ==="
# The damage was never the one field. A non-Python client cannot parse ANY of a
# response containing a bare Infinity, so one divide-by-zero column took out the
# entire reply. Hence the strict-parse check alongside the field checks.
check_strict_json "data-basic read_column_stats parses strictly" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"column\":\"ratio\"}"
check_absent "…and puts no bare Infinity on the wire" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"column\":\"ratio\"}" '(^|[^"A-Za-z])-?Infinity([^"A-Za-z]|$)'
check_absent "…and no bare NaN either" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"column\":\"ratio\"}" '(^|[^"A-Za-z])NaN([^"A-Za-z]|$)'
# null, not a string and not a sentinel number: "mean": null says the mean could
# not be computed, "Infinity" invites printing it, 1e308 invites arithmetic.
check "…and reports the unusable statistic as null" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"column\":\"ratio\"}" 'null'
# The fix is a choke point installed on every DA server, not a patch to one
# module. The bug it replaced was a per-site fix that stopped at the first
# sibling, so the sibling servers are the point of these three.
check_strict_json "data-statistics extended_stats parses strictly" \
  "$DATA_BASE/statistics/mcp" "$DATA_TOK" extended_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"columns\":[\"ratio\"]}"
check_strict_json "data-medium extended_stats parses strictly" \
  "$DATA_BASE/medium/mcp" "$DATA_TOK" extended_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"columns\":[\"ratio\"]}"
check_strict_json "data-statistics scan_nulls_zeros parses strictly" \
  "$DATA_BASE/statistics/mcp" "$DATA_TOK" scan_nulls_zeros \
  "{\"file_path\":\"$DIR/nonfinite.csv\"}"
# The must-not direction: a sanitiser that flattens every float would be a worse
# bug than the one it replaced. A finite value must survive untouched.
check "…while a finite value is left alone" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"column\":\"num\"}" '"?max"?\\?": ?10'
# A text column must survive the sanitiser as text. json_safe checks isinstance
# str before the isfinite path precisely so a value like "nan" in a name column
# stays the caller's data rather than becoming null.
check "…and a text column still reports its values" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/nonfinite.csv\",\"column\":\"name\"}" 'success\\?": ?true'

echo
echo "=== dacd79f — a 3D chart had three axes and could label two ==="
check "generate_3d_chart" "$DATA_BASE/visual/mcp" "$DATA_TOK" generate_3d_chart \
  "{\"file_path\":\"$DIR/plain.csv\",\"chart_type\":\"scatter_3d\",\"x_column\":\"qty\",\"y_column\":\"qty\",\"z_column\":\"qty\",\"output_path\":\"$DIR/c3d.html\",\"open_after\":false}" \
  'success\\?": ?true'
# Pre-fix this returned "No customization parameters provided": the gate read
# `if x_label or y_label`, so a call carrying only z_label fell straight through
# to the refusal. z_label alone is the exact shape that failed.
check "customize_chart accepts z_label ALONE" "$DATA_BASE/visual/mcp" "$DATA_TOK" customize_chart \
  "{\"chart_path\":\"$DIR/c3d.html\",\"z_label\":\"ZED\",\"output_path\":\"$DIR/c3d_z.html\"}" \
  'success\\?": ?true'
check_file "…and the z title lands in the scene" "$HOST/c3d_z.html" 'zaxis' yes
check_file "…carrying the label itself" "$HOST/c3d_z.html" 'ZED' yes
# The trap I nearly shipped: z_label was inserted into a positional engine call
# ahead of color_scheme, which would have silently rebound every later argument.
# This is the check that would have caught it.
check "z_label together with color_scheme" "$DATA_BASE/visual/mcp" "$DATA_TOK" customize_chart \
  "{\"chart_path\":\"$DIR/c3d.html\",\"z_label\":\"ZED2\",\"color_scheme\":[\"#ab12cd\"],\"output_path\":\"$DIR/c3d_zc.html\"}" \
  'success\\?": ?true'
# A colour nothing else in a plotly bundle would contain, so finding it in the
# file proves this argument survived the call rather than matching boilerplate.
check_file "…and color_scheme still reached the chart" "$HOST/c3d_zc.html" '#ab12cd' yes
# The must-not direction: a 2D figure has no third axis, and answering "done"
# would be worse than refusing.
check "z_label on a 2D chart is refused by name" "$DATA_BASE/visual/mcp" "$DATA_TOK" generate_chart \
  "{\"file_path\":\"$DIR/plain.csv\",\"chart_type\":\"bar\",\"value_column\":\"qty\",\"category_column\":\"name\",\"output_path\":\"$DIR/c2d.html\"}" \
  'success\\?": ?true'
check "…with an error naming the missing z axis" "$DATA_BASE/visual/mcp" "$DATA_TOK" customize_chart \
  "{\"chart_path\":\"$DIR/c2d.html\",\"z_label\":\"NOPE\",\"output_path\":\"$DIR/c2d_z.html\"}" \
  'has no z axis to label'
# A tool that accepts a parameter must list it where it enumerates what it takes.
check "the empty-call hint enumerates z_label" "$DATA_BASE/visual/mcp" "$DATA_TOK" customize_chart \
  "{\"chart_path\":\"$DIR/c3d.html\",\"output_path\":\"$DIR/c3d_n.html\"}" \
  'x_label, y_label, z_label'

echo
echo "=== 9e884fa / cc14af0 / 566a191 — token_estimate was typed in, not measured ==="
# 587 hardcoded literals across three repos. Under-reporting is the direction
# that hurts: a client budgets its context from this number and admits the
# response on the strength of it. Error responses were the worst case, since
# their length is dominated by a variable-length message, so any constant is
# wrong by construction -- and making a message MORE specific silently made the
# lie bigger. Both an ordinary reply and a refusal are checked per repo.
check_measured "DA  read_column_stats (ordinary reply)" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/plain.csv\",\"column\":\"qty\"}"
check_measured "DA  read_column_stats (refusal)" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/plain.csv\",\"column\":\"no_such_column\"}"
check_measured "DA  inspect_dataset" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" inspect_dataset \
  "{\"file_path\":\"$DIR/plain.csv\"}"
check_measured "ML  inspect_dataset" \
  "$ML_BASE/basic/mcp" "$ML_TOK" inspect_dataset \
  "{\"file_path\":\"$DIR/plain.csv\"}"
check_measured "ML  restore_version (refusal, was 20 for ~100)" \
  "$ML_BASE/basic/mcp" "$ML_TOK" restore_version \
  "{\"file_path\":\"$DIR/plain.csv\"}"
check_measured "OFF create_workbook" \
  "$OFF_BASE/xlsx-new/mcp" "$OFF_TOK" create_workbook \
  "{\"output_path\":\"$DIR/w.xlsx\",\"sheet_name\":\"S\"}"
check_measured "OFF read_document (refusal, was 15 for ~205)" \
  "$OFF_BASE/docx-basic/mcp" "$OFF_TOK" read_document \
  "{\"file_path\":\"$DIR/.mcp_versions/x_2026-01-01T00-00-00-000000Z.docx.bak\"}"

# One tool, two response sizes, per repo. This is the check a literal cannot
# survive at any payload length -- see check_varies for why the ratio window
# alone was not enough.
check_varies "DA  read_column_stats varies with its answer" \
  "$DATA_BASE/basic/mcp" "$DATA_TOK" read_column_stats \
  "{\"file_path\":\"$DIR/plain.csv\",\"column\":\"qty\"}" \
  "{\"file_path\":\"$DIR/plain.csv\",\"column\":\"name\"}"
check_varies "ML  inspect_dataset varies with the dataset" \
  "$ML_BASE/basic/mcp" "$ML_TOK" inspect_dataset \
  "{\"file_path\":\"$DIR/plain.csv\"}" \
  "{\"file_path\":\"$DIR/nonfinite.csv\"}"
check_varies "OFF read_document varies with the failure" \
  "$OFF_BASE/docx-basic/mcp" "$OFF_TOK" read_document \
  "{\"file_path\":\"$DIR/.mcp_versions/x_2026-01-01T00-00-00-000000Z.docx.bak\"}" \
  "{\"file_path\":\"$DIR/does_not_exist.docx\"}"

echo
echo "=== e7ec243 — a hint that argued with the error above it ==="
# The error already said "snapshots are addressed by timestamp, use get_history
# then restore_version". The hint said "Check that file_path is a valid .docx
# file" -- and the file IS a valid .docx; it is only in a directory the tools
# refuse to open. `hint` is the field a caller acts on, so the response argued
# the caller out of the answer it had just handed them.
check "the hint names the snapshot route" "$OFF_BASE/docx-basic/mcp" "$OFF_TOK" read_document \
  "{\"file_path\":\"$DIR/.mcp_versions/x_2026-01-01T00-00-00-000000Z.docx.bak\"}" \
  'hint\\?": ?\\?"Call get_history'
check_absent "…and no longer blames the file format" "$OFF_BASE/docx-basic/mcp" "$OFF_TOK" read_document \
  "{\"file_path\":\"$DIR/.mcp_versions/x_2026-01-01T00-00-00-000000Z.docx.bak\"}" \
  'valid \.docx file'

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
