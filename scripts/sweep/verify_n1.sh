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
HOST_DIR=/root/Harnesses/data/n1_verify
PASS=0; FAIL=0

# The fixtures. This script used to assume they were already there, having been
# made by hand during the round that wrote it. They are not there any more, so
# every assertion failed with "File not found" and the run reported 28 defects
# that did not exist. A checker that cannot make its own inputs is not runnable.
# /root/Harnesses/data is the exchange the containers see as /workspace/data.
setup_fixtures() {
  mkdir -p "$HOST_DIR"
  printf 'clicks,impressions,spends\n12,340,5.5\n' > "$HOST_DIR/one_row.csv"
  # Placed here so the rest of the function can assume the writes land.
  printf 'clicks,impressions,spends\n12,340,5.5\n9,220,4.0\n30,900,11.5\n7,150,3.25\n21,610,8.75\n' \
    > "$HOST_DIR/five_rows.csv"
  # `spend` entirely null and one column that is not, so exactly one is skipped.
  printf 'name,spend\nA,\nB,\nC,\n' > "$HOST_DIR/all_null.csv"
  printf 'name,spends\nA,7\nB,7\nC,7\n' > "$HOST_DIR/const_seed.csv"
  python3 - "$HOST_DIR/formula.xlsx" <<'PY'
import sys
from openpyxl import Workbook

wb = Workbook()
ws = wb.active
ws.title = "Data"
for row, value in enumerate([4, 8, 15, 16], start=1):
    ws.cell(row=row, column=2, value=value)
# openpyxl stores the formula and never evaluates it, which is exactly the
# state read_cell has to report rather than hand back as a value.
ws["B5"] = "=SUM(B1:B4)"
wb.save(sys.argv[1])
PY
  # Half these tools write their output back into this directory, and the
  # servers run as uid 999 (app). A directory root has just made is not theirs
  # to write, which surfaced as eleven "[Errno 13] Permission denied" failures
  # that read like tool defects and were nothing of the kind.
  chown -R 999:999 "$HOST_DIR" 2>/dev/null || chmod -R a+rwX "$HOST_DIR" 2>/dev/null || true
  chmod 2775 "$HOST_DIR" 2>/dev/null || true
}
setup_fixtures

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
    | tr -d '\r' | grep '^data:' | sed 's/^data: //' | decode
}

# The tool's result, decoded and compacted.
#
# Every pattern in this file is written against compact, unescaped JSON --
# `"success":false`, `"rows_used":1`. What comes off the wire is the result as a
# JSON *string*, so each quote is backslash-escaped, and the servers now
# pretty-print, so each colon is followed by a space. Neither pattern can match
# that, and grepping the raw envelope would have failed all 31 assertions on
# formatting while reporting them as behaviour.
#
# Fixed once here rather than by rewriting 31 patterns: decode the string, then
# collapse `": "` to `":"`. The alternative -- teaching every pattern to spell
# `\\?"key\\?": ?value` -- is how verify_vocab ended up with two assertions that
# silently stopped matching.
decode() {
  python3 -c '
import json, sys
for line in sys.stdin.read().splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    try:
        text = obj["result"]["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        text = json.dumps(obj)
    print(json.dumps(json.loads(text), separators=(",", ":")) if text.lstrip().startswith("{") else text)
    break
' 2>/dev/null
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

# check_file <label> <host-path> <grep-pattern> <expect: yes|no>
# Several of the round-13 follow-up fixes are about what lands on disk rather
# than what comes back in the response -- that is how eight of the ten were
# found. /root/Harnesses/data is the same bind mount the servers write to, so
# the file can be read straight from the host.
check_file() {
  local label="$1" path="$2" want="$3" expect="$4" hit=no
  [ -f "$path" ] && grep -qE "$want" "$path" && hit=yes
  if [ "$hit" = "$expect" ]; then
    printf 'PASS  %-42s file %s /%s/\n' "$label" "$expect" "$want"
    PASS=$((PASS + 1))
  else
    printf 'FAIL  %-42s wanted %s /%s/ in %s\n' "$label" "$expect" "$want" "$path"
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

# --- the ten found by re-running the phases, 2026-08-24 --------------------
#
# Eight of these were only visible by reading the artifact, not the response.
# Where that is true the check reads the file.

echo
echo "=== follow-ups: response and artifact must agree ==="

HOST=/root/Harnesses/data/n1_verify

check "extended_stats cv is not NaN" "$DATA_BASE/statistics/mcp" "$DATA_TOK" extended_stats \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  '"cv":(null|-?[0-9])'
check "correlation_heatmap says n" "$DATA_BASE/visual/mcp" "$DATA_TOK" generate_correlation_heatmap \
  "{\"file_path\":\"$DIR/one_row.csv\",\"output_path\":\"$DIR/hm.html\",\"open_after\":false}" \
  '"rows_used":1'
check "pairwise_plot says n" "$DATA_BASE/visual/mcp" "$DATA_TOK" generate_pairwise_plot \
  "{\"file_path\":\"$DIR/one_row.csv\",\"output_path\":\"$DIR/pw.html\",\"open_after\":false}" \
  '"rows_used":1'
check "run_eda does not score a clean row 0" "$DATA_BASE/visual/mcp" "$DATA_TOK" run_eda \
  "{\"file_path\":\"$DIR/one_row.csv\",\"output_path\":\"$DIR/eda.html\",\"open_after\":false}" \
  '"quality_score":(8[1-9]|9[0-9]|100)'
check "customize_chart refuses a textless note" "$DATA_BASE/visual/mcp" "$DATA_TOK" customize_chart \
  "{\"chart_path\":\"$DIR/hm.html\",\"annotations\":[{\"x\":0,\"y\":1}]}" \
  '"success":false.*no text'

# normalize must not zero a constant column -- it rewrites the caller's file.
cp -f "$HOST/const_seed.csv" "$HOST/const.csv" 2>/dev/null || printf 'name,spends\nA,7\nB,7\nC,7\n' > "$HOST/const.csv"
check "apply_patch reports the no-op" "$DATA_BASE/basic/mcp" "$DATA_TOK" apply_patch \
  "{\"file_path\":\"$DIR/const.csv\",\"ops\":[{\"op\":\"normalize\",\"column\":\"spends\",\"method\":\"minmax\"}]}" \
  '"ops_with_no_effect":\[\{'
check_file "normalize left the 7s alone" "$HOST/const.csv" '^A,7$' yes
check_file "normalize wrote no zeros" "$HOST/const.csv" '^A,0' no

# detect_anomalies must not write False flags for a column it would not judge.
check "detect_anomalies count is null" "$DATA_BASE/medium/mcp" "$DATA_TOK" detect_anomalies \
  "{\"file_path\":\"$DIR/one_row.csv\",\"output_path\":\"$DIR/anom.csv\"}" \
  '"anomaly_count":null'
check_file "no _iqr_flag column written" "$HOST/anom.csv" '_iqr_flag' no
check_file "no _anomaly_score column written" "$HOST/anom.csv" '_anomaly_score' no

check "check_data_quality qualifies its score" "$ML_BASE/medium/mcp" "$ML_TOK" check_data_quality \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  'score_note.*could not run'
check "zero_inflated is not charged at n=1" "$ML_BASE/medium/mcp" "$ML_TOK" check_data_quality \
  "{\"file_path\":\"$DIR/one_row.csv\"}" \
  '"alerts_count":0'

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
