#!/usr/bin/env bash
# shellcheck disable=SC2015
# `A && pass ... || fail ...` is not if-then-else in general. It is here:
# both reporters end in an explicit `return 0`, so the `|| fail` arm cannot run
# after `pass` has already run. Stated rather than restructured, because the
# one-line-per-assertion shape is what makes this file readable as a checklist.
# Round 28's fixes, checked against the DEPLOYED servers by direct MCP calls.
#
# Every assertion below picks inputs that hit the branch the fix ADDED. That is
# deliberate and it is the lesson of four previous rounds: a checker left to
# choose its own inputs picks the branch that did not change, and reports green.
#
#   ./verify_r28_fixes.sh
#
# Exits non-zero on the first failure. Ad_Data.csv is never written to.
#
# A tool result arrives as the JSON *string* result.content[0].text, so every
# quote on the wire is backslash-escaped. Match \" and not ", or the assertion
# reports a failure the server did not commit -- which is how the first run of
# this file scored three passing behaviours as broken.

set -uo pipefail

ENV_FILE=/root/Harnesses/.env
SESS=$(mktemp -d)
PASS=0
FAIL=0

get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA=$(get DATA_MCP_BASE_URL); DT=$(get DATA_MCP_TOKEN)
ML=$(get ML_MCP_BASE_URL);     MT=$(get ML_MCP_TOKEN)
OFFICE=$(get OFFICE_MCP_BASE_URL); OT=$(get OFFICE_MCP_TOKEN)
DOCS=$(get DOCS_MCP_BASE_URL); DOT=$(get DOCS_MCP_TOKEN)
FS_URL=$(get FS_MCP_URL);      FT=$(get FS_MCP_TOKEN)
MATH_URL=$(get MATH_MCP_URL);  MHT=$(get MATH_MCP_TOKEN)
BROWSER_URL=$(get BROWSER_MCP_URL); BT=$(get BROWSER_MCP_TOKEN)

pass() { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; return 0; }
fail() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; printf '       %s\n' "${2:0:400}"; return 0; }
has()  { grep -qF -- "$2" <<<"$1"; }

# An assertion about what a REFUSAL says has to read only the refusal. Every
# tool on this fleet echoes the arguments it was given, so grepping the whole
# envelope for an argument name matches a success too: `pivot_table` returns the
# string "agg_func" whether it refused the value or accepted it. Five assertions
# below were written that way. Each was correct on the day it was written, and
# each would have gone on passing if the behaviour regressed to silently
# accepting and echoing -- which is the defect it exists to catch.
msg() {
  python3 -c '
import json, sys
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if line.startswith("data:"):
        line = line[5:].strip()
    if not line.startswith("{"):
        continue
    try:
        body = json.loads(json.loads(line)["result"]["content"][0]["text"])
    except Exception:
        continue
    print(" ".join(str(body.get(k, "")) for k in ("error", "hint")))
    break
' <<<"$1"
}

# Pair with msg() whenever the property is "refused, and the refusal said X".
refused() { has "$1" '\"success\": false'; }

# One session per endpoint, reused, like a real client.
call() {
  local url="$1" tok="$2" tool="$3" args="$4" key sid hdr body resp
  key=$(printf '%s' "$url" | md5sum | cut -c1-12)
  sid=$(cat "$SESS/$key" 2>/dev/null || true)
  if [ -z "$sid" ]; then
    hdr=$(mktemp)
    curl -s --max-time 120 -X POST "$url" -H "Authorization: Bearer $tok" \
      -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
      -D "$hdr" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify-r28","version":"28"}}}' >/dev/null
    sid=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}'); rm -f "$hdr"
    curl -s --max-time 120 -X POST "$url" -H "Authorization: Bearer $tok" \
      -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
      -H "mcp-session-id: $sid" -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
    printf '%s' "$sid" > "$SESS/$key"
  fi
  body=$(python3 -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$tool" "$args")
  resp=$(curl -s --max-time 300 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" -d "$body")
  printf '%s' "$resp"
}

A=/workspace/data/Ad_Data.csv
W=/workspace/data/r28v
echo "== setting up $W =="
call "$FS_URL" "$FT" fs_write "{\"ops\":[{\"op\":\"create_dir\",\"path\":\"$W\"}]}" >/dev/null
call "$FS_URL" "$FT" fs_write "{\"ops\":[{\"op\":\"copy\",\"src\":\"$A\",\"dst\":\"$W/ads.csv\"}]}" >/dev/null
C=$W/ads.csv

echo
echo "== 1, 6: check_outliers refuses a method it cannot read, and knows zscore =="
R=$(call "$DATA/statistics/mcp" "$DT" check_outliers "{\"file_path\":\"$C\",\"method\":\"definitely_not_a_method\"}")
has "$R" 'Unknown method' && pass "an unrecognised method is refused" || fail "still answering with a made-up method" "$R"
has "$R" 'iqr' && has "$R" 'std' && has "$R" 'both' && pass "the refusal names all three legal values" || fail "legal set missing" "$R"
has "$R" 'columns_with_outliers' && fail "it still returned an outlier verdict" "$R" || pass "no verdict is offered alongside the refusal"

R=$(call "$DATA/statistics/mcp" "$DT" check_outliers "{\"file_path\":\"$C\",\"method\":\"zscore\"}")
has "$R" '\"method\": \"std\"' && pass "zscore resolves to std (detect_anomalies' spelling)" || fail "zscore not resolved" "$R"
has "$R" 'outlier_count_std' && pass "and the 3-sigma scan actually ran" || fail "resolved but did not scan" "$R"

R=$(call "$DATA/medium/mcp" "$DT" detect_anomalies "{\"file_path\":\"$C\",\"method\":\"std\"}")
has "$R" '\"method\": \"zscore\"' && pass "and std resolves the other way at detect_anomalies" || fail "reverse alias missing" "$R"

echo
echo "== 2, 3: cross_tabulate reports what it did =="
R=$(call "$DATA/medium/mcp" "$DT" cross_tabulate "{\"file_path\":\"$C\",\"row_column\":\"campaign_platform\",\"col_column\":\"campaign_type\",\"normalize\":\"sideways\"}")
has "$R" 'Unknown normalize' && pass "a normalize it cannot read is refused" || fail "still coerced silently" "$R"
R=$(call "$DATA/medium/mcp" "$DT" cross_tabulate "{\"file_path\":\"$C\",\"row_column\":\"campaign_platform\",\"col_column\":\"campaign_type\",\"normalize\":\"rows\"}")
has "$R" '\"normalize\": \"index\"' && pass "the echo is the value used, not the value sent" || fail "echo still repeats the caller" "$R"
R=$(call "$DATA/medium/mcp" "$DT" cross_tabulate "{\"file_path\":\"$C\",\"row_column\":\"campaign_platform\",\"col_column\":\"campaign_type\",\"agg_func\":\"mean\"}")
has "$R" 'was not applied' && pass "a dropped agg_func is reported, not swallowed" || fail "agg_func still dropped in silence" "$R"

echo
echo "== 4: the hint names the argument that was wrong =="
R=$(call "$DATA/medium/mcp" "$DT" pivot_table "{\"file_path\":\"$C\",\"index\":[\"campaign_platform\"],\"values\":[\"spends\"],\"agg_func\":\"definitely_not_a_func\"}")
refused "$R" && has "$(msg "$R")" 'agg_func' && pass "pivot_table's refusal names agg_func" || fail "still blaming something else" "$R"
has "$R" 'file_path and column names' && fail "still sends the caller to check file_path" "$R" || pass "and no longer blames file_path"
R=$(call "$DATA/medium/mcp" "$DT" compute_aggregations "{\"file_path\":\"$C\",\"group_by\":[\"campaign_platform\"],\"agg_column\":\"spends\",\"agg_func\":\"average\"}")
has "$R" '\"agg_func\": \"mean\"' && pass "average resolves to mean" || fail "alias not resolved" "$R"
R=$(call "$DATA/medium/mcp" "$DT" pivot_table "{\"file_path\":\"$C\",\"index\":[\"campaign_platform\"],\"values\":[\"spends\"],\"agg_func\":\"median\"}")
has "$R" '\"success\": true' && pass "and the siblings accept the same words" || fail "median refused at pivot_table" "$R"

echo
echo "== 11: Shapiro says which sample it used, and the two endpoints agree =="
R=$(call "$DATA/statistics/mcp" "$DT" statistical_test "{\"file_path\":\"$C\",\"test\":\"shapiro_wilk\",\"column_a\":\"spends\"}")
has "$R" 'n_used' && has "$R" '16834' && pass "statistical_test discloses the subsample" || fail "still silent about sampling" "$R"
P1=$(python3 -c 'import sys,re; t=sys.stdin.read(); m=re.search(r"\\\\?\"p_value\\\\?\":\s*([0-9.eE+-]+)",t); print(m.group(1) if m else "")' <<<"$R")
R=$(call "$DATA/medium/mcp" "$DT" statistical_tests "{\"file_path\":\"$C\",\"test\":\"shapiro_wilk\",\"column_a\":\"spends\"}")
P2=$(python3 -c 'import sys,re; t=sys.stdin.read(); m=re.search(r"\\\\?\"p_value\\\\?\":\s*([0-9.eE+-]+)",t); print(m.group(1) if m else "")' <<<"$R")
[ -n "$P1" ] && [ "$P1" = "$P2" ] && pass "both endpoints now answer $P1" || fail "endpoints still disagree" "$P1 vs $P2"

echo
echo "== 15: dry_run carries the leakage warning =="
R=$(call "$ML/basic/mcp" "$MT" train_regressor "{\"file_path\":\"$C\",\"target_column\":\"clicks\",\"model\":\"rfr\",\"dry_run\":true}")
has "$R" 'leakage_suspects' && pass "dry_run returns leakage_suspects" || fail "dry_run still silent" "$R"
has "$R" 'link_clicks' && has "$R" 'component_of_target' && pass "and names link_clicks with its reason" || fail "no suspect named" "$R"
has "$R" 'would_train' && pass "while still saying what it would do" || fail "dry_run contract broken" "$R"

echo
echo "== 24, 16: task validated; drop_column speaks both dialects =="
R=$(call "$ML/advanced/mcp" "$MT" plot_learning_curve "{\"file_path\":\"$C\",\"target_column\":\"spends\",\"model\":\"lir\",\"task\":\"definitely_not_a_task\"}")
has "$R" 'Unknown task' && pass "plot_learning_curve refuses an unknown task" || fail "still fell through to regression" "$R"
R=$(call "$ML/medium/mcp" "$MT" run_preprocessing "{\"file_path\":\"$C\",\"ops\":[{\"op\":\"drop_column\",\"columns\":[\"age\"]}],\"output_path\":\"$W/pre.csv\"}")
has "$R" '\"success\": true' && pass "ml-medium takes the Data_Analyst spelling" || fail "columns still refused on ML" "$R"
R=$(call "$DATA/basic/mcp" "$DT" apply_patch "{\"file_path\":\"$W/pre.csv\",\"ops\":[{\"op\":\"drop_column\",\"column\":\"phase\"}],\"dry_run\":true}")
has "$R" '\"success\": true' && pass "and Data_Analyst takes the ML spelling" || fail "column still refused on DA" "$R"

echo
echo "== 7, 10, 22: filesystem grammar, paths, archive format =="
R=$(call "$FS_URL" "$FT" list_fs_ops '{"op":"copy"}')
has "$R" '\"src\"' && has "$R" '\"dst\"' && pass "list_fs_ops names copy's real fields" || fail "grammar still unreachable" "$R"
has "$R" 'example' && pass "with a worked example" || fail "no example" "$R"
R=$(call "$FS_URL" "$FT" fs_read "{\"path\":\"$W/does_not_exist.csv\"}")
refused "$R" && has "$(msg "$R")" "$W/does_not_exist.csv" && pass "fs_read reports the whole path it was given" || fail "still reports the basename" "$R"
R=$(call "$FS_URL" "$FT" fs_manage "{\"action\":\"disk_usage\",\"path\":\"$W/does_not_exist.csv\"}")
refused "$R" && has "$(msg "$R")" "$W/does_not_exist.csv" && pass "fs_manage disk_usage does too" || fail "disk_usage names no path" "$R"
call "$FS_URL" "$FT" fs_archive "{\"action\":\"create\",\"path\":\"$W/v.zip\",\"target\":\"$W\"}" >/dev/null
R=$(call "$FS_URL" "$FT" fs_archive "{\"action\":\"list\",\"path\":\"$W/v.zip\"}")
has "$R" '\"success\": true' && pass "listing a .zip infers the format" || fail "list still demands a format" "$R"

echo
echo "== 12, 13, 14: the envelope on the four repos that lacked it =="
for pair in "$MATH_URL|$MHT|calculate|{\"expression\":123}" \
            "$DOCS/read/mcp|$DOT|probe|{\"source\":123}" \
            "$DOCS/edit/mcp|$DOT|optimize|{\"source\":123}" \
            "$BROWSER_URL|$BT|browse_search|{\"query\":123}"; do
  IFS='|' read -r u t tool args <<<"$pair"
  R=$(call "$u" "$t" "$tool" "$args")
  # 'success' alone matched a success:true too, so this passed whether the type
  # error was refused inside the envelope or cheerfully accepted.
  refused "$R" && pass "$tool: a type error stays inside the contract" || fail "$tool: still a raw dump" "$R"
  has "$R" 'pydantic.dev' && fail "$tool: still sends the caller to the internet" "$R" || pass "$tool: no external URL"
done
R=$(call "$BROWSER_URL" "$BT" browse_datetime '{}')
has "$R" '\"success\"' && has "$R" '\"ok\"' && pass "browser carries both success and ok" || fail "browser envelope unchanged" "$R"
R=$(call "$MATH_URL" "$MHT" integrate '{"expression":"2*x","variable":"x","lower":"0","upper":"3"}')
has "$R" '\"result\": \"9\"' && pass "math integrate still integrates" || fail "integrate broken" "$R"

echo
echo "== 23, 20, 18, 21, 19: office =="
D=$W/v.docx
call "$OFFICE/docx-new/mcp" "$OT" create_from_text "{\"output_path\":\"$D\",\"paragraphs\":[{\"text\":\"seed\",\"style\":\"Normal\"}]}" >/dev/null
R=$(call "$OFFICE/docx-basic/mcp" "$OT" append_text "{\"file_path\":\"$D\",\"text\":\"x\",\"style\":\"Headng 1\"}")
has "$R" 'Unknown paragraph style' && pass "a style the document lacks is refused" || fail "still silently fell back to Normal" "$R"
has "$R" 'Heading 1' && pass "and the real name is suggested" || fail "no suggestion" "$R"
R=$(call "$OFFICE/docx-basic/mcp" "$OT" append_text "{\"file_path\":\"$D\",\"text\":\"heading\",\"style\":\"Heading 1\"}")
has "$R" '\"success\": true' && pass "a real style still applies" || fail "real style refused" "$R"

R=$(call "$OFFICE/docx-tables/mcp" "$OT" add_table "{\"file_path\":\"$D\",\"after_paragraph_index\":0,\"rows\":1,\"cols\":1,\"data\":[[\"first\"]]}")
has "$R" 'table_index' && pass "add_table returns the index it made" || fail "no index returned" "$R"
R=$(call "$OFFICE/docx-tables/mcp" "$OT" add_table "{\"file_path\":\"$D\",\"after_paragraph_index\":-1,\"rows\":1,\"cols\":1,\"data\":[[\"second\"]]}")
has "$R" 'renumber' && pass "and warns when it renumbers the others" || fail "silent renumber" "$R"

R=$(call "$OFFICE/xlsx-new/mcp" "$OT" create_invoice "{\"output_path\":\"$W/inv.xlsx\",\"company_name\":\"A\",\"client_name\":\"B\",\"invoice_number\":\"1\",\"items\":[{\"description\":\"x\",\"quantity\":2,\"unit_price\":500}],\"tax_rate\":0.1}")
has "$R" '\"tax\": 100' && has "$R" '\"total\": 1100' && pass "create_invoice reports tax and total" || fail "still only subtotal" "$R"
has "$R" 'no calculation engine' && pass "and says the cells hold uncalculated formulas" || fail "no note" "$R"

R=$(call "$OFFICE/docx-tables/mcp" "$OT" set_cell_style "{\"file_path\":\"$D\",\"table_index\":0,\"fill_color\":\"D9E2F3\",\"row\":0,\"col\":-1}")
has "$R" '\"success\": true' && pass "docx set_cell_style takes fill_color" || fail "spreadsheet spelling refused" "$R"

R=$(call "$OFFICE/docx-basic/mcp" "$OT" get_history "{\"file_path\":\"$D\"}")
TS=$(python3 -c 'import re,sys; t=sys.stdin.read(); m=re.search(r"\\\\?\"timestamp\\\\?\":\s*\\\\?\"([^\"\\\\]+)", t); print(m.group(1) if m else "")' <<<"$R")
if [ -n "$TS" ]; then
  R=$(call "$OFFICE/docx-basic/mcp" "$OT" diff_versions "{\"file_path\":\"$D\",\"timestamp_a\":\"$TS\"}")
  has "$R" 'formatting' && pass "diff_versions says what it did not compare" || fail "summary still overclaims" "$R"
else
  fail "diff_versions: no snapshot timestamp to compare against" "$R"
fi

R=$(call "$OFFICE/xlsx-charts/mcp" "$OT" add_chart "{\"file_path\":\"$W/inv.xlsx\",\"sheet_name\":\"Invoice\",\"type\":\"bar\",\"data_range\":\"A6:D7\",\"anchor_cell\":\"F2\"}")
has "$R" 'does not take type' && pass "the docstring's old 'type:' is still refused (r27 guard)" || fail "guard regressed" "$R"

echo
echo "== the fixture is untouched =="
MD5=$(md5sum /root/Harnesses/data/Ad_Data.csv | cut -d' ' -f1)
[ "$MD5" = "9a16b9248526466960194df4eb7a3e90" ] && pass "Ad_Data.csv md5 unchanged" || fail "THE FIXTURE WAS MODIFIED" "$MD5"

rm -rf "$SESS"
echo
echo "=================================================="
printf 'PASSED %d   FAILED %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL PASSED" || echo "SOME CHECKS FAILED"
exit $(( FAIL > 0 ))
