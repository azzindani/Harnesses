#!/usr/bin/env bash
# Round 27's eight findings, asserted against the DEPLOYED servers.
#
# The standing lesson, now 4-for-4: an axis re-run cannot prove a fix. A model
# picks its own inputs and picks the branch the fix did not change -- every
# `dayfirst` tool in round 25 came back HELD having been called only with the
# valid value, so the refusal branch the fix added was never once exercised.
# This script picks the inputs deliberately. It is what settles it.
set -uo pipefail
E=/root/Harnesses/.env
g() { grep "^$1=" "$E" | head -1 | cut -d= -f2-; }
DATA=$(g DATA_MCP_BASE_URL);  DT=$(g DATA_MCP_TOKEN)
ML=$(g ML_MCP_BASE_URL);      MT=$(g ML_MCP_TOKEN)
OFF=$(g OFFICE_MCP_BASE_URL); OT=$(g OFFICE_MCP_TOKEN)
DOCS=$(g DOCS_MCP_BASE_URL);  DOT=$(g DOCS_MCP_TOKEN)
FS=$(g FS_MCP_URL);           FT=$(g FS_MCP_TOKEN)
MATH=$(g MATH_MCP_URL);       MAT=$(g MATH_MCP_TOKEN)
BROW=$(g BROWSER_MCP_URL);    BT=$(g BROWSER_MCP_TOKEN)

F=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; F=$((F+1)); }

sid_for() {
  local hdr; hdr=$(mktemp)
  curl -s --max-time 30 -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"v27","version":"1"}}}' -D "$hdr" >/dev/null
  local s; s=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}'); rm -f "$hdr"
  curl -s --max-time 20 -X POST "$1" -H "Authorization: Bearer $2" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $s" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  echo "$s"
}
# call <url> <token> <tool> <json args>
call() {
  local u="$1" t="$2" tool="$3" args="$4" s
  s=$(sid_for "$u" "$t")
  curl -s --max-time 240 -X POST "$u" -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $s" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}"
}
listing() {
  local u="$1" t="$2" s; s=$(sid_for "$u" "$t")
  curl -s --max-time 60 -X POST "$u" -H "Authorization: Bearer $t" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "mcp-session-id: $s" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
}
# Results arrive as the JSON *string* result.content[0].text, so every quote in
# it is backslash-escaped. Grep bare tokens, never `"success": false`.
has() { grep -q "$2" <<<"$1"; }

echo "=== finding 1: an argument no tool declares is refused, on all seven repos ==="
declare -a PROBES=(
  "data-basic|$DATA/basic/mcp|$DT|inspect_dataset|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"zzz\":1}"
  "data-transform|$DATA/transform/mcp|$DT|aggregate_dataset|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"mode\":\"groupby\",\"group_by\":[\"campaign_platform\"],\"agg_func\":\"mean\"}"
  "data-statistics|$DATA/statistics/mcp|$DT|validate_dataset|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"strictness\":\"paranoid\"}"
  "data-visual|$DATA/visual/mcp|$DT|export_data|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"format\":\"csv\",\"zzz\":1}"
  "data-medium|$DATA/medium/mcp|$DT|value_counts|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"column\":\"campaign_platform\",\"zzz\":1}"
  "data-ingest|$DATA/ingest/mcp|$DT|list_sheets|{\"file_path\":\"/workspace/data/none.xlsx\",\"zzz\":1}"
  "data-workspace|$DATA/workspace/mcp|$DT|list_workspace_files|{\"zzz\":1}"
  "ml-basic|$ML/basic/mcp|$MT|inspect_dataset|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"zzz\":1}"
  "ml-medium|$ML/medium/mcp|$MT|detect_outliers|{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"zzz\":1}"
  "math|$MATH|$MAT|calculate|{\"expression\":\"1+1\",\"precision_mode\":\"exact\"}"
  "docs-read|$DOCS/read/mcp|$DOT|probe|{\"source\":\"/workspace/data/BBCA_filing.pdf\",\"zzz\":1}"
  "browser|$BROW|$BT|browse_datetime|{\"zzz\":1}"
  "filesystem|$FS|$FT|fs_read|{\"path\":\"/workspace/data/Ad_Data.csv\",\"encoding_hint\":\"utf-16\"}"
  "office-docx-basic|$OFF/docx-basic/mcp|$OT|get_document_outline|{\"file_path\":\"/workspace/data/none.docx\",\"zzz\":1}"
)
for probe in "${PROBES[@]}"; do
  IFS='|' read -r label url tok tool args <<<"$probe"
  R=$(call "$url" "$tok" "$tool" "$args")
  if has "$R" 'does not take'; then pass "$label $tool refuses the undeclared name"
  else fail "$label $tool still accepts it"; fi
done

echo
echo "=== finding 1b: a tool that takes NO arguments refuses them too ==="
R=$(call "$BROW" "$BT" browse_datetime '{"zzz":1}')
has "$R" 'browse_datetime does not take zzz' && pass "zero-parameter tool refuses an argument" || fail "zero-parameter tool still ignores arguments"

echo
echo "=== finding 7: apply_patch refuses output_path instead of eating the source ==="
BEFORE=$(md5sum /root/Harnesses/data/Ad_Data.csv | awk '{print $1}')
R=$(call "$DATA/basic/mcp" "$DT" apply_patch \
  '{"file_path":"/workspace/data/Ad_Data.csv","ops":[{"op":"drop_column","columns":["link_clicks"]}],"output_path":"/workspace/data/should_not_exist.csv"}')
has "$R" 'does not take output_path' && pass "output_path refused by name" || fail "output_path still discarded"
AFTER=$(md5sum /root/Harnesses/data/Ad_Data.csv | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] && pass "the source file is untouched ($AFTER)" || fail "the source file was modified: $BEFORE -> $AFTER"
[ ! -f /root/Harnesses/data/should_not_exist.csv ] && pass "and nothing was written elsewhere" || fail "an unexpected file appeared"
L=$(listing "$DATA/basic/mcp" "$DT")
has "$L" 'in place' && pass "the description says it edits in place" || fail "description still silent about in-place"

echo
echo "=== findings 3 and 4: an infinity is counted, named, and cannot flip a verdict ==="
call "$DATA/transform/mcp" "$DT" feature_engineering \
  '{"file_path":"/workspace/data/Ad_Data.csv","derive":[{"name":"ctr","op":"arith","how":"div","column":"clicks","other":"impressions"}],"output_path":"/workspace/data/v27_rates.csv"}' >/dev/null
R=$(call "$DATA/basic/mcp" "$DT" read_column_stats '{"file_path":"/workspace/data/v27_rates.csv","column":"ctr"}')
has "$R" 'non_finite_count' && pass "read_column_stats reports non_finite_count" || fail "no non_finite_count"
has "$R" 'are infinite' && pass "and says why the statistics are null" || fail "nulls still unexplained"
R=$(call "$DATA/statistics/mcp" "$DT" extended_stats '{"file_path":"/workspace/data/v27_rates.csv","columns":["ctr"]}')
has "$R" 'likely normal' && fail "extended_stats STILL calls a zero-inflated ratio normal" || pass "no false normality verdict"
has "$R" 'p>1.00' && fail "an impossible p-value is still printed" || pass "no impossible p-value"
has "$R" 'non-normal' && pass "and it reports non-normal, which is the truth here" || fail "expected a non-normal verdict"
R=$(call "$DATA/statistics/mcp" "$DT" regression_analysis '{"file_path":"/workspace/data/v27_rates.csv","y_col":"ctr","x_cols":["spends","impressions"]}')
has "$R" 'this fit has 16834' && fail "the self-contradicting residual message is still there" || pass "no self-contradicting residual count"

echo
echo "=== findings 5 and 6: the leak is named, and can be dropped ==="
R=$(call "$ML/basic/mcp" "$MT" train_regressor '{"file_path":"/workspace/data/Ad_Data.csv","target_column":"clicks","model":"rfr"}')
has "$R" 'link_clicks' && has "$R" 'leakage' && pass "train_regressor names link_clicks as a leakage suspect" || fail "leakage still silent on a regression target"
has "$R" 'component_of_target' && pass "with containment as the stated reason" || fail "no component_of_target evidence"
has "$R" 'spends' && has "$R" 'alone_predicts_target' && fail "spends is falsely accused" || pass "spends and impressions are not accused"
R=$(call "$ML/basic/mcp" "$MT" train_regressor '{"file_path":"/workspace/data/Ad_Data.csv","target_column":"clicks","model":"rfr","exclude_columns":["link_clicks"]}')
has "$R" 'success' && ! has "$R" 'does not take' && pass "exclude_columns is a real parameter" || fail "exclude_columns not honoured"
has "$R" 'Feature set narrowed' && pass "and the narrowing is confirmed in progress" || fail "narrowing not reported"
R=$(call "$ML/basic/mcp" "$MT" train_regressor '{"file_path":"/workspace/data/Ad_Data.csv","target_column":"clicks","model":"rfr","feature_columns":["spends","nonexistent_col"]}')
has "$R" 'nonexistent_col' && pass "an unknown feature column is refused by name" || fail "unknown feature column not caught"

echo
echo "=== finding 2: the derive grammar arrives whole ==="
R=$(call "$DATA/transform/mcp" "$DT" feature_engineering \
  '{"file_path":"/workspace/data/Ad_Data.csv","derive":[{"name":"x","op":"arith","column":"clicks","other_column":"impressions"}],"dry_run":true}')
has "$R" "add|sub|mul|div" && pass "a missing key now brings the whole arith grammar" || fail "grammar still revealed one key at a time"
has "$R" 'other_column' && fail "the caller's own wrong key is still echoed back" || pass "the wrong key is not echoed back as if correct"
R=$(call "$DATA/transform/mcp" "$DT" list_derive_ops '{}')
has "$R" 'parse_date' && has "$R" 'compare' && pass "list_derive_ops returns every op" || fail "list_derive_ops missing or incomplete"

echo
echo "=== finding 8: no claim of an open that did not happen ==="
R=$(call "$OFF/docx-new/mcp" "$OT" create_from_text \
  '{"output_path":"/workspace/data/v27_open.docx","paragraphs":[{"text":"round 27","style":"Normal"}]}')
has "$R" 'success' && pass "the document is written" || fail "write failed"
has "$R" 'default app' && fail "still claims a headless container opened it" || pass "no false open claim"

echo
[ "$F" -eq 0 ] && echo "ALL PASSED" || echo "$F FAILED"
exit "$F"
