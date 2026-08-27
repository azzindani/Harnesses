#!/usr/bin/env bash
# Re-check every tool fixed after round 16, against the live endpoints.
#
#     ./verify_r16b.sh
#
# Technique 8 from reference_what_finds_defects: re-sweep the tools you just
# changed. Direct curl rather than the opencode harness, because this confirms a
# DEPLOYMENT rather than exercising a model.
#
# Why this exists alongside the r16b sweep, which covers the same tools. The
# sweep re-runs round 16's AXIS ("open the file it wrote"). That is the right
# question for judging the fleet and the wrong one for judging a fix: the model
# picks its own inputs, and across the phases checked it picked the branch the
# fix did NOT change every single time -- a 2D chart for a 3D-axis fix,
# run_preprocessing with zero ops, add_table on a document that had paragraphs.
# Each phase passed, and none of them touched the changed code. So these checks
# name the exact string each fix introduced, and build the state that used to
# fail.
#
# Copy this per axis rather than extending it: a check naming a specific fix's
# string stops meaning anything once that fix is old.
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA_BASE=$(get DATA_MCP_BASE_URL); DATA_TOK=$(get DATA_MCP_TOKEN)
ML_BASE=$(get ML_MCP_BASE_URL);     ML_TOK=$(get ML_MCP_TOKEN)
OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)

DIR=/workspace/data/r16b_verify          # as the servers see it
HOST=/root/Harnesses/data/r16b_verify    # the same bytes, as this script sees them
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
# Patterns must tolerate both JSON styles: the Office servers pretty-print
# ("success": true) and the payload also arrives escaped inside the MCP
# envelope (\"success\": true). Hence the \\? and the optional space.
check() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" want="$6" out
  out=$(call "$url" "$tok" "$tool" "$args")
  if grep -qE "$want" <<<"$out"; then
    printf 'PASS  %-46s /%s/\n' "$label" "$want"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-46s wanted /%s/\n' "$label" "$want"
    printf '      %.500s\n' "$out"; FAIL=$((FAIL + 1))
  fi
}

# check_absent — the fix must NOT say this. A coercion fix that turns every
# string into a number is a worse bug than the one it replaces, so the
# must-not direction needs asserting too.
check_absent() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" bad="$6" out
  out=$(call "$url" "$tok" "$tool" "$args")
  if grep -qE "$bad" <<<"$out"; then
    printf 'FAIL  %-46s must NOT match /%s/\n' "$label" "$bad"
    printf '      %.500s\n' "$out"; FAIL=$((FAIL + 1))
  else
    printf 'PASS  %-46s absent /%s/\n' "$label" "$bad"; PASS=$((PASS + 1))
  fi
}

# check_file <label> <host-path> <pattern> <yes|no>
check_file() {
  local label="$1" path="$2" want="$3" expect="$4" hit=no
  [ -f "$path" ] && grep -qE "$want" "$path" && hit=yes
  if [ "$hit" = "$expect" ]; then
    printf 'PASS  %-46s file %s /%s/\n' "$label" "$expect" "$want"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-46s wanted %s /%s/ in %s\n' "$label" "$expect" "$want" "$path"; FAIL=$((FAIL + 1))
  fi
}

# A root-owned 755 fixture directory makes every write tool return
# "[Errno 13] Permission denied" on a path it reads from perfectly well. That
# cost a whole pass once; set the group and the bit up front.
rm -rf "$HOST"; mkdir -p "$HOST"; chgrp 999 "$HOST" 2>/dev/null; chmod g+w "$HOST"
printf 'name,qty\na,1\nb,2\na,3\nc,4\nb,5\n' > "$HOST/dupes.csv"
printf 'name,qty\na,1\na,1\nb,2\n' > "$HOST/restore_me.csv"
chgrp 999 "$HOST"/*.csv 2>/dev/null; chmod g+w "$HOST"/*.csv

echo "=== office-xlsx-basic — 6019e06, a write that misstated what it did ==="
check "create_workbook" "$OFF_BASE/xlsx-new/mcp" "$OFF_TOK" create_workbook \
  "{\"output_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\"}" 'success\\?": ?true'
check "set_cell stores a number as a number" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"cell_address\":\"A1\",\"value\":\"16833\"}" \
  'stored_type\\?": ?\\?"number'
# The must-not direction: leading zeros are identifiers, not numbers.
check "set_cell keeps 007 as text" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" set_cell \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"cell_address\":\"A2\",\"value\":\"007\"}" \
  'stored_type\\?": ?\\?"text'
check "set_range coerces each value" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" set_range \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"start_cell\":\"D1\",\"data\":[[\"12\",\"x\"]]}" \
  'success\\?": ?true'
check "copy_sheet discloses drawings carried" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" copy_sheet \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S\",\"new_name\":\"S2\"}" 'drawings_copied'
check "rename_sheet discloses refs retargeted" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" rename_sheet \
  "{\"file_path\":\"$DIR/b.xlsx\",\"sheet_name\":\"S2\",\"new_name\":\"S3\"}" 'references_updated'

echo
echo "=== office-xlsx-basic — find_duplicates counted after truncating ==="
check "create_from_csv" "$OFF_BASE/xlsx-new/mcp" "$OFF_TOK" create_from_csv \
  "{\"csv_path\":\"$DIR/dupes.csv\",\"output_path\":\"$DIR/d.xlsx\"}" 'success\\?": ?true'
check "find_duplicates separates cap from count" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" find_duplicates \
  "{\"file_path\":\"$DIR/d.xlsx\",\"sheet_name\":\"Data\",\"column\":\"A\"}" 'max_duplicates_returned'

echo
echo "=== office-docx-basic — 6d481b4, a snapshot path with no way back ==="
check "the .mcp_versions guard names the route" "$OFF_BASE/docx-basic/mcp" "$OFF_TOK" read_document \
  "{\"file_path\":\"$DIR/.mcp_versions/x_2026-01-01T00-00-00-000000Z.docx.bak\"}" \
  'restore_version and diff_versions take that timestamp'

echo
echo "=== office-docx-tables — d5ffe2b, a document with a table is not empty ==="
check "create_document" "$OFF_BASE/docx-new/mcp" "$OFF_TOK" create_document \
  "{\"output_path\":\"$DIR/t.docx\"}" 'success\\?": ?true'
check "add_table (first, into a truly empty doc)" "$OFF_BASE/docx-tables/mcp" "$OFF_TOK" add_table \
  "{\"file_path\":\"$DIR/t.docx\",\"after_paragraph_index\":0,\"rows\":2,\"cols\":2,\"data\":[[\"A\",\"B\"],[\"C\",\"D\"]]}" 'success\\?": ?true'
# Now the body holds a table and still no paragraphs -- the branch that used to
# call the file empty and append at the far end.
check "add_table -1 places before the table" "$OFF_BASE/docx-tables/mcp" "$OFF_TOK" add_table \
  "{\"file_path\":\"$DIR/t.docx\",\"after_paragraph_index\":-1,\"rows\":1,\"cols\":2,\"data\":[[\"E\",\"F\"]]}" \
  'before the existing content'
check_absent "…and no longer calls the doc empty" "$OFF_BASE/docx-tables/mcp" "$OFF_TOK" add_table \
  "{\"file_path\":\"$DIR/t.docx\",\"after_paragraph_index\":-1,\"rows\":1,\"cols\":2,\"data\":[[\"G\",\"H\"]]}" \
  'document (is|was) empty'

echo
echo "=== data-basic — 020763a, a restore that ran when asked a question ==="
# restore_version can only report which snapshot it defaulted to if a snapshot
# exists; with none, the honest answer is "no backups found" and the check would
# be measuring the wrong thing.
check "apply_patch (creates the snapshot)" "$DATA_BASE/basic/mcp" "$DATA_TOK" apply_patch \
  "{\"file_path\":\"$DIR/restore_me.csv\",\"ops\":[{\"op\":\"drop_duplicates\"}]}" \
  'changed_file\\?": ?true'
check "restore_version says it chose by default" "$DATA_BASE/basic/mcp" "$DATA_TOK" restore_version \
  "{\"file_path\":\"$DIR/restore_me.csv\"}" 'newest_by_default'

echo
echo "=== data-visual — 2902ae0, 3D axis titles plotly never reads ==="
check "generate_3d_chart" "$DATA_BASE/visual/mcp" "$DATA_TOK" generate_3d_chart \
  "{\"file_path\":\"$DIR/dupes.csv\",\"chart_type\":\"scatter_3d\",\"x_column\":\"qty\",\"y_column\":\"qty\",\"z_column\":\"qty\",\"output_path\":\"$DIR/c3d.html\",\"open_after\":false}" \
  'success\\?": ?true'
check "customize_chart accepts 3D labels" "$DATA_BASE/visual/mcp" "$DATA_TOK" customize_chart \
  "{\"chart_path\":\"$DIR/c3d.html\",\"x_label\":\"XL\",\"y_label\":\"YL\",\"output_path\":\"$DIR/c3d_c.html\"}" \
  'success\\?": ?true'
# The whole point: for a 3D figure the titles must land under layout.scene,
# because plotly never reads them from the top-level layout.
check_file "3D titles land under layout.scene" "$HOST/c3d_c.html" '"scene"' yes
check_file "…and the label is actually in there" "$HOST/c3d_c.html" 'XL' yes

echo
echo "=== ml-medium — 205bd8c, a created file with no provenance ==="
check "run_preprocessing" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/dupes.csv\",\"ops\":[{\"op\":\"drop_duplicates\"}],\"output_path\":\"$DIR/pre.csv\"}" 'success\\?": ?true'
# The receipt must be filed against the OUTPUT. Reading the INPUT's receipt was
# the pre-fix behaviour and proves nothing.
check "the output file has its own receipt" "$ML_BASE/medium/mcp" "$ML_TOK" read_receipt \
  "{\"file_path\":\"$DIR/pre.csv\"}" 'created from'

echo
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
