#!/usr/bin/env bash
# Re-check every fix made after round 19b, against the live endpoints.
#
#     ./verify_r19b.sh
#
# Copy this per round rather than extending it: a check naming a specific fix's
# string stops meaning anything once that fix is old. verify_r18.sh still
# stands on its own and both should pass.
#
# Round 19b's three phases were run from a Claude Code session's own MCP mounts
# because both sweep providers were out of quota, which means the model that
# drove them is the model that wrote the round-18 fixes. That is fine for
# confirming a known fix and useless for discovery. These checks are the
# discovery-independent half: they call the endpoints directly and assert the
# exact behaviour each commit introduced.
#
# Covers:
#   e1cd4ee  Office  sort_sheet moved the header into the data, +6 siblings
#   1456214  Office  a bad colour named half its own value
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)

DIR=/workspace/data/r19b_check
HOST=/root/Harnesses/data/r19b_check
XB="$OFF_BASE/xlsx-basic/mcp"
XN="$OFF_BASE/xlsx-new/mcp"
PD="$OFF_BASE/pptx-design/mcp"
PN="$OFF_BASE/pptx-new/mcp"
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

# The tool's own payload, unwrapped from the MCP envelope.
body() {
  call "$1" "$2" "$3" "$4" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    print(json.loads(json.loads(raw)["result"]["content"][0]["text"]) and
          json.loads(raw)["result"]["content"][0]["text"])
except Exception:
    print("")
' 2>/dev/null
}

field() {  # field <url> <tok> <tool> <args> <key>
  body "$1" "$2" "$3" "$4" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
try:
    print(json.loads(raw).get('$5', ''))
except Exception:
    print('')
" 2>/dev/null
}

ok_()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad_()  { printf 'FAIL  %s\n      got: %.240s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

want()  { local v; v=$(field "$2" "$3" "$4" "$5" "$6"); grep -qE "$7" <<<"$v" && ok_ "$1" || bad_ "$1" "$v"; }
deny()  { local v; v=$(field "$2" "$3" "$4" "$5" "$6"); grep -qE "$7" <<<"$v" && bad_ "$1" "$v" || ok_ "$1"; }

rm -rf "$HOST"; mkdir -p "$HOST"; chgrp 999 "$HOST" 2>/dev/null; chmod g+w "$HOST"

echo "=== e1cd4ee — sort_sheet moved the header into the data ==="
call "$XN" "$OFF_TOK" create_workbook "{\"output_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\"}" >/dev/null
call "$XB" "$OFF_TOK" set_range \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"start_cell\":\"A1\",\"data\":[[\"name\",\"qty\"],[\"beta\",2],[\"alpha\",3],[\"gamma\",1]]}" >/dev/null
# The two ordinary calls that used to corrupt the file: insert a row, then sort.
call "$XB" "$OFF_TOK" insert_row "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"row_index\":1}" >/dev/null
call "$XB" "$OFF_TOK" sort_sheet "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"column\":\"A\"}" >/dev/null
# Read the FILE back, not the response -- the old bug reported success:true.
AFTER=$(call "$XB" "$OFF_TOK" read_cell_range \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"range_address\":\"A1:B5\"}")
if grep -q '"cell": "A2"[^}]*' <<<"$AFTER" && python3 - "$AFTER" <<'PY'
import json, sys
env = json.loads(sys.argv[1])
rows = json.loads(env["result"]["content"][0]["text"])["data"]
flat = {c["cell"]: c["value"] for row in rows for c in row}
sys.exit(0 if flat.get("A2") == "name" and flat.get("B2") == "qty" else 1)
PY
then ok_ "the header survives insert_row + sort_sheet"
else bad_ "the header survives insert_row + sort_sheet" "$AFTER"; fi

want "a header name as column= is answered, not raised" "$XB" "$OFF_TOK" sort_sheet \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"column\":\"qty\"}" error 'qty'
deny "…and does not leak IndexError" "$XB" "$OFF_TOK" sort_sheet \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"column\":\"qty\"}" error 'list index out of range'
want "…and its hint says LETTER" "$XB" "$OFF_TOK" sort_sheet \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"column\":\"qty\"}" hint 'LETTER|letter'

echo
echo "=== the response no longer contradicts itself about a snapshot ==="
want "set_cell A0 still says nothing was written" "$XB" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"cell_address\":\"A0\",\"value\":\"x\"}" hint 'Nothing was written'
deny "…and no longer advertises a backup" "$XB" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"cell_address\":\"A0\",\"value\":\"x\"}" backup '.'
# The disk is the real check: three failed calls used to leave three .bak files.
BEFORE_BAKS=$(ls "$HOST/.mcp_versions"/*.bak 2>/dev/null | wc -l)
for addr in A0 B0 C0; do
  call "$XB" "$OFF_TOK" set_cell \
    "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\",\"cell_address\":\"$addr\",\"value\":\"x\"}" >/dev/null
done
AFTER_BAKS=$(ls "$HOST/.mcp_versions"/*.bak 2>/dev/null | wc -l)
[ "$BEFORE_BAKS" -eq "$AFTER_BAKS" ] \
  && ok_ "three failed calls leave no new .bak on disk ($AFTER_BAKS)" \
  || bad_ "three failed calls leave no new .bak on disk" "was $BEFORE_BAKS, now $AFTER_BAKS"

echo
echo "=== every hint names a tool that exists ==="
deny "add_sheet no longer points at a delete_sheet" "$XB" "$OFF_TOK" add_sheet \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\"}" hint 'delete[ _]sheet|delete the existing sheet'
want "…and names one that is really here" "$XB" "$OFF_TOK" add_sheet \
  "{\"file_path\":\"$DIR/s.xlsx\",\"sheet_name\":\"Data\"}" hint 'rename_sheet|list_sheets'

echo
echo "=== no heap address reaches a client ==="
printf 'this is not an image' > "$HOST/fake.png"
chgrp 999 "$HOST/fake.png" 2>/dev/null; chmod g+r "$HOST/fake.png"
call "$PN" "$OFF_TOK" create_presentation "{\"output_path\":\"$DIR/d.pptx\",\"title\":\"r19b\"}" >/dev/null
deny "a corrupt PNG does not leak an object repr" "$PD" "$OFF_TOK" add_image_to_all_slides \
  "{\"file_path\":\"$DIR/d.pptx\",\"image_path\":\"$DIR/fake.png\"}" error '0x[0-9a-f]{6}'
want "…and says the contents are not an image" "$PD" "$OFF_TOK" add_image_to_all_slides \
  "{\"file_path\":\"$DIR/d.pptx\",\"image_path\":\"$DIR/fake.png\"}" error 'not a readable image'
deny "…and does not tell you to restore anything" "$PD" "$OFF_TOK" add_image_to_all_slides \
  "{\"file_path\":\"$DIR/d.pptx\",\"image_path\":\"$DIR/fake.png\"}" hint 'restore_version'

echo
echo "=== 1456214 — a bad colour named half its own value ==="
deny "color_hex=red no longer leaks the int() parse" "$PD" "$OFF_TOK" set_font_all_slides \
  "{\"file_path\":\"$DIR/d.pptx\",\"color_hex\":\"red\"}" error 'base 16'
want "…and names the argument" "$PD" "$OFF_TOK" set_font_all_slides \
  "{\"file_path\":\"$DIR/d.pptx\",\"color_hex\":\"red\"}" error 'color_hex'
# The must-not-overreach direction: a real colour must still apply.
want "a valid colour still applies" "$PD" "$OFF_TOK" set_font_all_slides \
  "{\"file_path\":\"$DIR/d.pptx\",\"color_hex\":\"#FF0000\",\"font_name\":\"Arial\"}" op 'set_font_all_slides'

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
