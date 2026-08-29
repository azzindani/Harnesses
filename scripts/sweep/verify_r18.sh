#!/usr/bin/env bash
# Re-check every fix made after round 18, against the live endpoints.
#
#     ./verify_r18.sh
#
# Round 18's axis was "do what the hint told you to do". Re-running that axis
# over the fixed tools would judge the fleet, not the fix -- the model picks its
# own inputs, and in the r16b pass it picked the branch the fix had NOT changed
# four times out of four. So these checks make each tool fail in the EXACT way
# that produced the wrong hint, and assert the sentence the fix introduced.
#
# Copy this per round rather than extending it: a check naming a specific fix's
# string stops meaning anything once that fix is old.
#
# Covers:
#   a35e06f  Office  hint_for_error told you to undo a write that never happened
#   207291b  DA      the hint answered a different question than the error
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA_BASE=$(get DATA_MCP_BASE_URL); DATA_TOK=$(get DATA_MCP_TOKEN)
OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)

DIR=/workspace/data/r18_verify
HOST=/root/Harnesses/data/r18_verify
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
    -H "mcp-session-id: $sid" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
    | tr -d '\r' | grep -m1 '^data:' | sed 's/^data: //'
}

# The hint is the field under test, so read it rather than grepping the whole
# payload: an error that happens to contain the word would otherwise pass a
# check about the hint.
hint_of() {
  call "$1" "$2" "$3" "$4" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    env = json.loads(raw)
    print(json.loads(env["result"]["content"][0]["text"]).get("hint", ""))
except Exception:
    print("")
' 2>/dev/null
}

want() {  # want <label> <url> <tok> <tool> <args> <regex the HINT must match>
  local h; h=$(hint_of "$2" "$3" "$4" "$5")
  if grep -qE "$6" <<<"$h"; then
    printf 'PASS  %-52s hint ~ /%s/\n' "$1" "$6"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s wanted /%s/\n      got: %.220s\n' "$1" "$6" "$h"; FAIL=$((FAIL + 1))
  fi
}

deny() {  # the hint must NOT say this -- the whole point of both fixes
  local h; h=$(hint_of "$2" "$3" "$4" "$5")
  if grep -qE "$6" <<<"$h"; then
    printf 'FAIL  %-52s must NOT match /%s/\n      got: %.220s\n' "$1" "$6" "$h"; FAIL=$((FAIL + 1))
  else
    printf 'PASS  %-52s hint lacks /%s/\n' "$1" "$6"; PASS=$((PASS + 1))
  fi
}

rm -rf "$HOST"; mkdir -p "$HOST"; chgrp 999 "$HOST" 2>/dev/null; chmod g+w "$HOST"
printf 'name,qty\na,1\nb,2\na,3\n' > "$HOST/d.csv"
chgrp 999 "$HOST"/d.csv 2>/dev/null; chmod g+w "$HOST"/d.csv

echo "=== a35e06f — the hint told you to undo a write that never happened ==="
call "$OFF_BASE/xlsx-new/mcp" "$OFF_TOK" create_workbook \
  "{\"output_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\"}" >/dev/null
# Row 0 is rejected by openpyxl during coordinate validation, before the save.
XB="$OFF_BASE/xlsx-basic/mcp"
deny "set_cell no longer advises a restore" "$XB" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"cell_address\":\"A0\",\"value\":\"x\"}" 'restore_version'
want "…and says nothing was written" "$XB" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"cell_address\":\"A0\",\"value\":\"x\"}" 'Nothing was written'
deny "set_range likewise" "$XB" "$OFF_TOK" set_range \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"start_cell\":\"A0\",\"data\":[[\"x\"]]}" 'restore_version'
deny "insert_row likewise" "$XB" "$OFF_TOK" insert_row \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"row_index\":-1}" 'restore_version'
# The must-not-overreach direction: a snapshot path is also a ValueError and
# must keep the timestamp route, not the new argument answer.
want "a .mcp_versions path keeps the snapshot route" "$OFF_BASE/docx-basic/mcp" "$OFF_TOK" read_document \
  "{\"file_path\":\"$DIR/.mcp_versions/x_2026-01-01T00-00-00-000000Z.docx.bak\"}" 'get_history'
# And a valid write must still work at all. This one asserts the BODY, not the
# hint: a successful call has no hint, so a hint-shaped check here would match
# the empty string and pass no matter what the tool did.
body_want() {
  local label="$1" out; out=$(call "$2" "$3" "$4" "$5")
  if grep -qE "$6" <<<"$out"; then
    printf 'PASS  %-52s body ~ /%s/\n' "$label" "$6"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-52s wanted /%s/\n      got: %.220s\n' "$label" "$6" "$out"; FAIL=$((FAIL + 1))
  fi
}
body_want "a valid set_cell still writes" "$XB" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"cell_address\":\"B2\",\"value\":\"ok\"}" 'success\\?": ?true'

echo
echo "=== 207291b — the hint answered a different question than the error ==="
DT="$DATA_BASE/transform/mcp"
deny "filter_dataset: bad column not answered with ops" "$DT" "$DATA_TOK" filter_dataset \
  "{\"file_path\":\"$DIR/d.csv\",\"conditions\":[{\"column\":\"nope\",\"op\":\"equals\",\"value\":\"x\"}]}" 'Valid filter ops'
want "…and points back at the list in the error" "$DT" "$DATA_TOK" filter_dataset \
  "{\"file_path\":\"$DIR/d.csv\",\"conditions\":[{\"column\":\"nope\",\"op\":\"equals\",\"value\":\"x\"}]}" 'error above'

DB="$DATA_BASE/basic/mcp"
deny "apply_patch: bad FIELD not answered with the op list" "$DB" "$DATA_TOK" apply_patch \
  "{\"file_path\":\"$DIR/d.csv\",\"ops\":[{\"op\":\"drop_column\",\"column\":\"name\"}]}" '^Valid ops:'
# The narrowing must not go too far -- an unknown OP still wants the vocabulary.
want "…but an unknown OP still gets the op list" "$DB" "$DATA_TOK" apply_patch \
  "{\"file_path\":\"$DIR/d.csv\",\"ops\":[{\"op\":\"not_a_real_op\"}]}" '^Valid ops:'

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
