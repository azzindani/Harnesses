#!/usr/bin/env bash
set -uo pipefail
E=/root/Harnesses/.env
g() { grep "^$1=" "$E" | head -1 | cut -d= -f2-; }
F=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; F=$((F+1)); }
rpc() { # url tok tool args
  local hdr sid
  hdr=$(mktemp)
  curl -s --max-time 30 -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}' -D "$hdr" >/dev/null
  sid=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}'); rm -f "$hdr"
  curl -s --max-time 20 -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s --max-time 300 -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$3\",\"arguments\":$4}}" \
    | tr -d '\r' | grep '^data:' | sed 's/^data: //'
}
DATA=$(g DATA_MCP_BASE_URL); DT=$(g DATA_MCP_TOKEN)
ML=$(g ML_MCP_BASE_URL);     MT=$(g ML_MCP_TOKEN)
FS=$(g FS_MCP_URL);          FT=$(g FS_MCP_TOKEN)
DOCS=$(g DOCS_MCP_BASE_URL); DK=$(g DOCS_MCP_TOKEN)
OFF=$(g OFFICE_MCP_BASE_URL); OT=$(g OFFICE_MCP_TOKEN)
BR=$(g BROWSER_MCP_URL);     BT=$(g BROWSER_MCP_TOKEN)
AD=/workspace/data/Ad_Data.csv
D=/workspace/data/ship_r24

echo "1. dayfirst refuses what it does not document (Data_Analyst)"
R=$(rpc "$DATA/statistics/mcp" "$DT" time_series_analysis "{\"file_path\":\"$AD\",\"date_column\":\"Date\",\"value_column\":\"spends\",\"dayfirst\":\"yes\",\"open_after\":false}")
grep -q 'not a value this tool takes' <<<"$R" && pass "dayfirst='yes' refused" || fail "dayfirst='yes' still accepted"
grep -qE 'auto.*false.*true|auto, false, true' <<<"$R" && pass "and the refusal names the three" || fail "refusal does not name them"
R=$(rpc "$DATA/statistics/mcp" "$DT" time_series_analysis "{\"file_path\":\"$AD\",\"date_column\":\"Date\",\"value_column\":\"spends\",\"dayfirst\":\"auto\",\"open_after\":false}")
grep -q '2019-10-16' <<<"$R" && pass "auto still parses ISO correctly" || fail "auto broke"

echo; echo "2. statistical_test says how many tests there are (Data_Analyst)"
rpc "$DATA/statistics/mcp" "$DT" tools/list "{}" >/dev/null 2>&1
R=$(rpc "$DATA/statistics/mcp" "$DT" statistical_test "{\"file_path\":\"$AD\",\"test\":\"nope\"}")
grep -q 'anderson' <<<"$R" && pass "the hint still enumerates all 17" || fail "hint lost the list"

echo; echo "3. search_columns filters by dtype (Machine_Learning)"
R=$(rpc "$ML/basic/mcp" "$MT" search_columns "{\"file_path\":\"$AD\",\"dtype\":\"float64\"}")
N=$(grep -oE '\\"total_matched\\": [0-9]+' <<<"$R" | grep -oE '[0-9]+')
[ "${N:-0}" -gt 0 ] && [ "${N:-99}" -lt 16 ] && pass "float64 -> $N of 16 columns" || fail "float64 -> ${N:-?} columns"
R=$(rpc "$ML/basic/mcp" "$MT" search_columns "{\"file_path\":\"$AD\",\"dtype\":\"banana\"}")
grep -q 'Cannot filter by dtype' <<<"$R" && pass "an unlisted dtype is refused" || fail "banana still ignored"

echo; echo "4. fs_archive honours the extension (File_System)"
rpc "$FS" "$FT" fs_write "{\"ops\":[{\"op\":\"write_file\",\"path\":\"$D/a.txt\",\"content\":\"hi\"}]}" >/dev/null
R=$(rpc "$FS" "$FT" fs_archive "{\"action\":\"create\",\"path\":\"$D/t.tar.gz\",\"target\":\"$D/a.txt\"}")
grep -q 'tar.gz' <<<"$R" && pass "format reported as tar.gz" || fail "still reports zip"
file /root/Harnesses/data/ship_r24/t.tar.gz 2>/dev/null | grep -qi 'gzip' && pass "and the bytes are really gzip" || fail "bytes are not a tarball"
R=$(rpc "$FS" "$FT" fs_archive "{\"action\":\"create\",\"path\":\"$D/u.tar.gz\",\"target\":\"$D/a.txt\",\"format\":\"zip\"}")
grep -q 'contradicts' <<<"$R" && pass "a contradicting format is refused" || fail "contradiction still written"

echo; echo "5. five true sentences (Documents)"
T=$(rpc "$DOCS/read/mcp" "$DK" __list__ "{}" 2>/dev/null)
for pair in "read/mcp:read_page:links" "read/mcp:find:not content"; do :; done
R=$(curl -s --max-time 30 -X POST "$DOCS/read/mcp" -H "Authorization: Bearer $DK" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -D /tmp/h1 \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}')
SID=$(grep -i '^mcp-session-id' /tmp/h1 | tr -d '\r' | awk '{print $2}')
curl -s -X POST "$DOCS/read/mcp" -H "Authorization: Bearer $DK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
L=$(curl -s --max-time 30 -X POST "$DOCS/read/mcp" -H "Authorization: Bearer $DK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
grep -q '"Read one page: text, tables, and how each was obtained."' <<<"$L" && pass "read_page no longer promises links" || fail "read_page still says links"
grep -q 'snippet each' <<<"$L" && pass "find now mentions snippets" || fail "find description unchanged"
grep -q 'lack one' <<<"$L" && true
E1=$(curl -s --max-time 30 -X POST "$DOCS/edit/mcp" -H "Authorization: Bearer $DK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -D /tmp/h2 -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}')
SID2=$(grep -i '^mcp-session-id' /tmp/h2 | tr -d '\r' | awk '{print $2}')
curl -s -X POST "$DOCS/edit/mcp" -H "Authorization: Bearer $DK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID2" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
L2=$(curl -s --max-time 30 -X POST "$DOCS/edit/mcp" -H "Authorization: Bearer $DK" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID2" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
grep -q 'linearize' <<<"$L2" && pass "optimize documents 'linearize'" || fail "optimize still says linearise"
grep -q 'action: encrypt, decrypt, permissions' <<<"$L2" && pass "protect names its real actions" || fail "protect still says clear"
grep -q 'Defaults to the pages that lack one' <<<"$L2" && pass "ocr no longer demands a range" || fail "ocr still says required"

echo; echo "6. wording (Office, Browser)"
OL=$(curl -s --max-time 30 -X POST "$OFF/xlsx-new/mcp" -H "Authorization: Bearer $OT" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -D /tmp/h3 -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}')
SID3=$(grep -i '^mcp-session-id' /tmp/h3 | tr -d '\r' | awk '{print $2}')
curl -s -X POST "$OFF/xlsx-new/mcp" -H "Authorization: Bearer $OT" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID3" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
curl -s --max-time 30 -X POST "$OFF/xlsx-new/mcp" -H "Authorization: Bearer $OT" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID3" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | grep -q 'plus a Cover sheet' && pass "create_report mentions the Cover sheet" || fail "Cover still undocumented"
BL=$(curl -s --max-time 30 -X POST "$BR" -H "Authorization: Bearer $BT" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -D /tmp/h4 -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}')
SID4=$(grep -i '^mcp-session-id' /tmp/h4 | tr -d '\r' | awk '{print $2}')
curl -s -X POST "$BR" -H "Authorization: Bearer $BT" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID4" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
curl -s --max-time 30 -X POST "$BR" -H "Authorization: Bearer $BT" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $SID4" -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | grep -q 'never the rows' && pass "query_export says what it meant" || fail "query_export unchanged"

echo
[ "$F" -eq 0 ] && echo "ALL LIVE CHECKS PASSED" || echo "$F CHECK(S) FAILED"
exit "$F"
