#!/usr/bin/env bash
set -uo pipefail
E=/root/Harnesses/.env
g() { grep "^$1=" "$E" | head -1 | cut -d= -f2-; }
DATA=$(g DATA_MCP_BASE_URL); DT=$(g DATA_MCP_TOKEN)
F=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; F=$((F+1)); }
sid_for() {
  local hdr; hdr=$(mktemp)
  curl -s --max-time 30 -X POST "$1" -H "Authorization: Bearer $DT" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v","version":"1"}}}' -D "$hdr" >/dev/null
  local s; s=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}'); rm -f "$hdr"
  curl -s --max-time 20 -X POST "$1" -H "Authorization: Bearer $DT" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $s" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  echo "$s"
}
listing() { local u="$1" s; s=$(sid_for "$u"); curl -s --max-time 30 -X POST "$u" -H "Authorization: Bearer $DT" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $s" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'; }

echo "the three round-25 findings, on the deployed server"
L=$(listing "$DATA/transform/mcp")
for a in sum mean count min max median std first last; do
  grep -q "agg: sum mean count min max median std first last" <<<"$L" && { [ "$a" = "sum" ] && pass "resample documents all nine aggregations"; break; } || { [ "$a" = "sum" ] && fail "resample still lists five"; break; }
done
grep -q 'equal row counts' <<<"$L" && pass "concat_datasets states the equal-row-count constraint" || fail "concat constraint still unstated"
grep -q 'one_hot is capped' <<<"$L" && pass "feature_engineering flags the one_hot cap" || fail "one_hot cap still unstated"

echo
echo "and the behaviour behind the sentences"
S=$(sid_for "$DATA/transform/mcp")
R=$(curl -s --max-time 180 -X POST "$DATA/transform/mcp" -H "Authorization: Bearer $DT" -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $S" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"resample_timeseries\",\"arguments\":{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"date_column\":\"Date\",\"value_columns\":[\"spends\"],\"freq\":\"M\",\"agg_func\":\"median\"}}}")
grep -q '\\"success\\": true' <<<"$R" && pass "agg_func=median works, as the sentence now says" || fail "median refused"

echo
[ "$F" -eq 0 ] && echo "ALL PASSED" || echo "$F FAILED"
exit "$F"
