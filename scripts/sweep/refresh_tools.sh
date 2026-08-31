#!/usr/bin/env bash
# Rebuild the round's tools file from tools/list on every live endpoint.
#
# The house rule this enforces: the sweep's tool list comes from the servers,
# never from a list the sweep model writes for itself. Asked once to "list the
# tools then call each", the model listed some, called none, and reported a
# clean pass over 19 tools it never touched.
#
#     ./refresh_tools.sh > tools_r15.tsv
#
# Two tab-separated columns, server and tool, sorted the way make_plan.py wants
# them: server groups in a fixed order, tools in the order the server reports.
# Writes a per-endpoint count to stderr so a silently empty mount is visible
# rather than becoming a phase that exercises nothing.
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA_BASE=$(get DATA_MCP_BASE_URL); DATA_TOK=$(get DATA_MCP_TOKEN)
ML_BASE=$(get ML_MCP_BASE_URL);     ML_TOK=$(get ML_MCP_TOKEN)
OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)
FS_URL=$(get FS_MCP_URL);           FS_TOK=$(get FS_MCP_TOKEN)
MATH_URL=$(get MATH_MCP_URL);       MATH_TOK=$(get MATH_MCP_TOKEN)
BROW_URL=$(get BROWSER_MCP_URL);    BROW_TOK=$(get BROWSER_MCP_TOKEN)
DOCS_BASE=$(get DOCS_MCP_BASE_URL); DOCS_TOK=$(get DOCS_MCP_TOKEN)

FAILED=0

# One MCP session, then tools/list. The servers speak streamable HTTP, so the
# reply arrives as SSE `data:` lines even when Accept allows plain JSON.
list_tools() {
  local url="$1" tok="$2" hdr sid
  hdr=$(mktemp)
  curl -s --max-time 30 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"refresh","version":"1"}}}' \
    -D "$hdr" >/dev/null
  sid=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdr"
  [ -z "$sid" ] && return 1
  curl -s --max-time 30 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s --max-time 60 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    | tr -d '\r' | grep '^data:' | sed 's/^data: //' \
    | python3 -c 'import json,sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        payload = json.loads(line)
    except ValueError:
        continue
    for tool in payload.get("result", {}).get("tools", []):
        print(tool["name"])
'
}

emit() {
  local label="$1" url="$2" tok="$3" names n
  names=$(list_tools "$url" "$tok")
  n=$(printf '%s' "$names" | grep -c . )
  # An endpoint that answers with zero tools is a deployment fault, not an
  # empty server -- every mount here has tools. Say so instead of writing a
  # phase that would exercise nothing.
  if [ "$n" -eq 0 ]; then
    echo "  $label: NO TOOLS -- endpoint down, token rejected, or mount renamed" >&2
    FAILED=$((FAILED + 1))
    return
  fi
  echo "  $label: $n" >&2
  printf '%s\n' "$names" | while read -r t; do [ -n "$t" ] && printf '%s\t%s\n' "$label" "$t"; done
}

# Documents leads the file, and therefore the plan. It is the seventh repo and
# the only one no sweep has ever reached, so it must not be what a provider's
# daily quota runs out before: round 22 died on phase 33 of 42.
for m in read edit; do
  emit "docs-$m" "$DOCS_BASE/$m/mcp" "$DOCS_TOK"
done
for m in basic ingest medium statistics transform visual workspace; do
  emit "data-$m" "$DATA_BASE/$m/mcp" "$DATA_TOK"
done
emit "filesystem" "$FS_URL" "$FS_TOK"
# math and browser were dropped from the harness for rounds 18-21 (1 and 0
# defects in five rounds each) and are back for round 22: both moved to Python
# 3.14 and the official SDK with everyone else, so both are in scope for an
# axis about what that migration left behind.
emit "math" "$MATH_URL" "$MATH_TOK"
emit "browser" "$BROW_URL" "$BROW_TOK"
for m in basic medium advanced; do
  emit "ml-$m" "$ML_BASE/$m/mcp" "$ML_TOK"
done
for m in docx-basic docx-layout docx-new docx-tables \
         pptx-basic pptx-design pptx-new \
         xlsx-basic xlsx-charts xlsx-formulas xlsx-new; do
  emit "office-$m" "$OFF_BASE/$m/mcp" "$OFF_TOK"
done

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED endpoint(s) reported no tools -- do not start a round on this list" >&2
  exit 1
fi
