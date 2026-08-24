#!/usr/bin/env bash
# Re-check every tool fixed for the n=1 axis, against the live endpoints.
#
# Technique 8 from reference_what_finds_defects: re-sweep the tools you just
# changed. Direct curl rather than the opencode harness, because this needs to
# confirm a deployment, not exercise a model -- and the provider has been
# unreliable all week.
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA_BASE=$(get DATA_MCP_BASE_URL); DATA_TOK=$(get DATA_MCP_TOKEN)
ML_BASE=$(get ML_MCP_BASE_URL);     ML_TOK=$(get ML_MCP_TOKEN)
OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)

DIR=/workspace/data/n1_verify
PASS=0; FAIL=0

# call <url> <token> <tool> <json-args>  -> prints the tool's result text
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

# check <label> <url> <token> <tool> <args> <grep-pattern-that-must-appear>
check() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" want="$6"
  local out
  out=$(call "$url" "$tok" "$tool" "$args")
  if grep -qE "$want" <<<"$out"; then
    printf 'PASS  %-42s %s\n' "$label" "matched /$want/"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-42s wanted /%s/\n' "$label" "$want"
    printf '      %.400s\n' "$out"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== data_analyst ==="
check "statistical_tests ttest n=1" "$DATA_BASE/medium/mcp" "$DATA_TOK" statistical_tests \
  "{\"file_path\":\"$DIR/one_row.csv\",\"test_type\":\"ttest\",\"column_a\":\"clicks\",\"column_b\":\"impressions\"}" \
  '"success":false.*at least 2 values'
check "statistical_test pearson n=1" "$DATA_BASE/statistics/mcp" "$DATA_TOK" statistical_test \
  "{\"file_path\":\"$DIR/one_row.csv\",\"test\":\"pearson\",\"column_a\":\"clicks\",\"column_b\":\"impressions\"}" \
  '"success":false.*complete pairs = 1'
check "statistical_test shapiro n=1" "$DATA_BASE/statistics/mcp" "$DATA_TOK" statistical_test \
  "{\"file_path\":\"$DIR/one_row.csv\",\"test\":\"shapiro_wilk\",\"column_a\":\"spends\"}" \
  'Shapiro-Wilk needs at least 3'
check "check_outliers n=1" "$DATA_BASE/statistics/mcp" "$DATA_TOK" check_outliers \
  "{\"file_path\":\"$DIR/one_row.csv\",\"open_after\":false}" \
  '"outlier_count_iqr":null'
check "check_outliers .csv output_path" "$DATA_BASE/statistics/mcp" "$DATA_TOK" check_outliers \
  "{\"file_path\":\"$DIR/five_rows.csv\",\"output_path\":\"$DIR/wanted.csv\",\"open_after\":false}" \
  'Output extension changed'
check "detect_anomalies n=1" "$DATA_BASE/medium/mcp" "$DATA_TOK" detect_anomalies \
  "{\"file_path\":\"$DIR/one_row.csv\",\"output_path\":\"$DIR/anom.csv\"}" \
  '"iqr_outliers":null'
check "extended_stats n=1 labels" "$DATA_BASE/statistics/mcp" "$DATA_TOK" extended_stats \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  '"skewness_label":null'
check "extended_stats n=1 shapiro" "$DATA_BASE/statistics/mcp" "$DATA_TOK" extended_stats \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  'undetermined: Shapiro-Wilk needs'
check "regression_analysis n=1" "$DATA_BASE/statistics/mcp" "$DATA_TOK" regression_analysis \
  "{\"file_path\":\"$DIR/one_row.csv\",\"y_col\":\"clicks\",\"x_cols\":[\"impressions\"]}" \
  'residual degrees of freedom'
check "smart_impute all-null" "$DATA_BASE/transform/mcp" "$DATA_TOK" smart_impute \
  "{\"file_path\":\"$DIR/all_null.csv\",\"output_path\":\"$DIR/imputed.csv\",\"open_after\":false}" \
  '"columns_skipped":1'
check "run_cleaning_pipeline all-null" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/all_null.csv\",\"ops\":[{\"op\":\"fill_nulls\",\"column\":\"spend\",\"strategy\":\"median\"}],\"output_path\":\"$DIR/cleaned.csv\"}" \
  'ops_with_no_effect'
check "generate_distribution_plot n=1" "$DATA_BASE/visual/mcp" "$DATA_TOK" generate_distribution_plot \
  "{\"file_path\":\"$DIR/one_row.csv\",\"output_path\":\"$DIR/dist.html\",\"open_after\":false}" \
  'not a distribution'

echo
echo "=== machine_learning ==="
check "detect_outliers n=1" "$ML_BASE/medium/mcp" "$ML_TOK" detect_outliers \
  "{\"file_path\":\"$DIR/one_row.csv\",\"columns\":[\"spends\"]}" \
  '"outlier_count":null'
check "detect_outliers std n=1" "$ML_BASE/medium/mcp" "$ML_TOK" detect_outliers \
  "{\"file_path\":\"$DIR/one_row.csv\",\"columns\":[\"spends\"],\"method\":\"std\"}" \
  'first exceeds 3 at n=11'
check "anomaly_detection n=1" "$ML_BASE/medium/mcp" "$ML_TOK" anomaly_detection \
  "{\"file_path\":\"$DIR/one_row.csv\",\"feature_columns\":[\"spends\",\"clicks\"]}" \
  '"success":false.*at least 2'
check "check_data_quality n=1" "$ML_BASE/medium/mcp" "$ML_TOK" check_data_quality \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  '"constant_columns":\[\]'
check "check_data_quality skips listed" "$ML_BASE/medium/mcp" "$ML_TOK" check_data_quality \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  'checks_skipped'

echo
echo "=== office ==="
check "read_cell on a formula" "$OFF_BASE/xlsx-basic/mcp" "$OFF_TOK" read_cell \
  "{\"file_path\":\"$DIR/formula.xlsx\",\"sheet_name\":\"Data\",\"cell_address\":\"B5\"}" \
  'formula_uncalculated'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
