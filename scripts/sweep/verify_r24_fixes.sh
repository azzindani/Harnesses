#!/usr/bin/env bash
# Assert the user-review fixes over MCP, against the DEPLOYED servers.
#
#     ./verify_r24_fixes.sh
#
# No model, no quota, no tmux -- so a provider outage cannot turn this red and
# a model choosing its own inputs cannot turn it green. Round 22 shipped five
# fixes that a whole sweep round failed to re-test, because a model picking its
# own arguments picks the branch the fix did not change: 4-for-4 in one round.
# This calls the exact broken input and asserts the exact new string.
#
# Copy this per round rather than extending it. A check naming one fix's string
# stops meaning anything once that fix is old, and a verify script that has
# accumulated four rounds of them is green for reasons nobody reads.
#
# Bare-token greps throughout: a tool result arrives as the JSON *string*
# result.content[0].text, so "leakage_suspects" is on the wire as
# \"leakage_suspects\" and a pattern anchored on a quote matches nothing. That
# trap already hid two real defects behind green smoke runs.
#
# The three MCP containers all bind /root/Harnesses/data at /workspace/data, so
# the fixtures are written on the host and read back on the host -- what the
# tool wrote is checked as bytes, not only as a sentence in its response.
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
DATA=$(get DATA_MCP_BASE_URL);   DATA_TOK=$(get DATA_MCP_TOKEN)
ML=$(get ML_MCP_BASE_URL);       ML_TOK=$(get ML_MCP_TOKEN)
OFFICE=$(get OFFICE_MCP_BASE_URL); OFFICE_TOK=$(get OFFICE_MCP_TOKEN)

HOST_DIR=/root/Harnesses/data/verify_r24
DIR=/workspace/data/verify_r24
FAILED=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }

# One MCP session per mount, then a tools/call. The servers speak streamable
# HTTP, so replies arrive as SSE `data:` lines even when Accept allows JSON.
call() {
  local url="$1" tok="$2" tool="$3" args="$4" hdr sid
  hdr=$(mktemp)
  curl -s --max-time 30 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
    -D "$hdr" >/dev/null
  sid=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdr"
  if [ -z "$sid" ]; then echo "NO SESSION on $url"; return 1; fi
  curl -s --max-time 30 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s --max-time 300 -X POST "$url" -H "Authorization: Bearer $tok" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
    | tr -d '\r' | grep '^data:' | sed 's/^data: //'
}

# output_name comes back inside the escaped envelope: \"output_name\": \"x.html\"
name_of() { grep -o 'output_name[^,]*' <<<"$1" | head -1 | sed 's/[^A-Za-z0-9_.-]//g' | sed 's/^output_name//' || true; }

# ------------------------------------------------------------------ fixtures
rm -rf "$HOST_DIR"
mkdir -p "$HOST_DIR"
python3 - "$HOST_DIR" <<'PY'
import base64, random, sys
d = sys.argv[1]
random.seed(11)
# grade x purpose gives cross_tabulate two axes to swap; two numeric columns
# give correlation_analysis a matrix to compute pearson and spearman over.
rows = ["grade,purpose,amount,other,annual_income,total_payment,loan_status"]
for i in range(300):
    off = i % 4 == 0
    rows.append(
        f"{random.choice('ABC')},{random.choice(['debt', 'car', 'home'])},"
        f"{random.randint(1000, 9000)},{random.randint(1, 50)},"
        f"{random.gauss(60000, 15000):.2f},"
        f"{(random.uniform(0, 900) if off else random.uniform(4000, 30000)):.2f},"
        f"{'Charged Off' if off else 'Fully Paid'}"
    )
with open(f"{d}/fixture.csv", "w", encoding="utf-8") as fh:
    fh.write("\n".join(rows))
# A real 1x1 PNG, so python-docx is exercised rather than mocked.
with open(f"{d}/pic.png", "wb") as fh:
    fh.write(base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    ))
# What every chart tool in this fleet actually produces, and so the first thing
# a caller will hand to a tool that wants a picture.
with open(f"{d}/chart.html", "w", encoding="utf-8") as fh:
    fh.write("<html></html>")
PY
# The services write as uid 999; a directory root creates is not writable by
# them and the first tool that saves into it fails with Permission denied.
chown -R --reference=/root/Harnesses/data/.gitkeep "$HOST_DIR"
chmod -R g+w "$HOST_DIR"

echo "data:   $DATA"
echo "ml:     $ML"
echo "office: $OFFICE"
echo

# --- fix 1: two charts, two filenames ----------------------------------------
# A user review built four bar charts from one dataset and found one file. The
# helper existed and was used at 1 of 11 call sites; two value_counts on
# different columns overwrote each other under two successes.
echo "1. a chart's default filename varies with its arguments"

A=$(call "$DATA/medium/mcp" "$DATA_TOK" value_counts \
  "{\"file_path\":\"$DIR/fixture.csv\",\"columns\":[\"grade\"],\"open_after\":false}")
B=$(call "$DATA/medium/mcp" "$DATA_TOK" value_counts \
  "{\"file_path\":\"$DIR/fixture.csv\",\"columns\":[\"purpose\"],\"open_after\":false}")
NA=$(name_of "$A"); NB=$(name_of "$B")
if [ -n "$NA" ] && [ "$NA" != "$NB" ]; then pass "value_counts grade vs purpose: $NA != $NB"
else fail "value_counts collides: '$NA' vs '$NB'"; fi

C=$(call "$DATA/medium/mcp" "$DATA_TOK" cross_tabulate \
  "{\"file_path\":\"$DIR/fixture.csv\",\"row_column\":\"grade\",\"col_column\":\"purpose\",\"open_after\":false}")
D=$(call "$DATA/medium/mcp" "$DATA_TOK" cross_tabulate \
  "{\"file_path\":\"$DIR/fixture.csv\",\"row_column\":\"purpose\",\"col_column\":\"grade\",\"open_after\":false}")
NC=$(name_of "$C"); ND=$(name_of "$D")
if [ -n "$NC" ] && [ "$NC" != "$ND" ]; then pass "crosstab axes swapped: $NC != $ND"
else fail "crosstab collides: '$NC' vs '$ND'"; fi

P=$(call "$DATA/statistics/mcp" "$DATA_TOK" correlation_analysis \
  "{\"file_path\":\"$DIR/fixture.csv\",\"method\":\"pearson\",\"open_after\":false}")
S=$(call "$DATA/statistics/mcp" "$DATA_TOK" correlation_analysis \
  "{\"file_path\":\"$DIR/fixture.csv\",\"method\":\"spearman\",\"open_after\":false}")
NP=$(name_of "$P"); NS=$(name_of "$S")
if [ -n "$NP" ] && [ "$NP" != "$NS" ]; then pass "pearson vs spearman: $NP != $NS"
else fail "correlation collides: '$NP' vs '$NS'"; fi

# The other half of the rule, and the half a later pass could "fix" by mistake:
# a whole-dataset picture takes no column selection, so one file per dataset is
# the right answer and a discriminator there would rename an unchanged chart.
O=$(call "$DATA/statistics/mcp" "$DATA_TOK" check_outliers \
  "{\"file_path\":\"$DIR/fixture.csv\",\"open_after\":false}")
NO=$(name_of "$O")
if grep -q 'outliers' <<<"$NO" && ! grep -qE 'outliers_[a-z]' <<<"$NO"; then
  pass "check_outliers keeps its stable whole-dataset name: $NO"
else fail "check_outliers name is now argument-dependent: '$NO'"; fi

# Two calls, one filename, and the count on disk is the proof the response is not.
WROTE=$(find /root/Harnesses/data -maxdepth 1 -name 'fixture_value_counts*' | wc -l)
if [ "$WROTE" -ge 2 ]; then pass "$WROTE value_counts files on disk, not 1"
else fail "only $WROTE value_counts file(s) on disk -- the second overwrote the first"; fi
echo

# --- fix 2: the manifest says whether the probabilities are calibrated -------
# Every classifier here exposes predict_proba and nothing calibrates it. The
# key is reported as "none" rather than omitted: an absent key reads as "not
# applicable" when the truth is that it applies and the answer is none.
echo "2. split provenance records calibration"

call "$ML/basic/mcp" "$ML_TOK" train_classifier \
  "{\"file_path\":\"$DIR/fixture.csv\",\"target_column\":\"loan_status\",\"model\":\"rf\",\"output_path\":\"$DIR/model.pkl\"}" >/dev/null
MANIFEST=$(find "$HOST_DIR" -name '*.manifest.json' | head -1)
if [ -n "$MANIFEST" ]; then
  if grep -q '"calibration"' "$MANIFEST"; then pass "manifest carries a calibration field"
  else fail "manifest has no calibration field"; fi
  if grep -q '"calibration": *"none"' "$MANIFEST"; then pass "and reports it as none, not by omission"
  else fail "calibration is not none: $(grep -o '"calibration":[^,]*' "$MANIFEST" || true)"; fi
  if grep -q 'calibration_note' "$MANIFEST"; then pass "with the caveat beside it"
  else fail "no calibration_note beside an uncalibrated model"; fi
  for k in test_size random_state stratified cv_folds; do
    if grep -q "\"$k\"" "$MANIFEST"; then pass "split.$k still present"
    else fail "split.$k lost"; fi
  done
else
  fail "no manifest written next to the model"
fi
echo

# --- fix 3: a section can hold a picture, and a refusal is spoken aloud ------
# create_from_blocks got an image kind and create_from_sections was left as
# {heading, body}, so a caller attaching a chart to a section had the key
# dropped in silence. Both now share _add_image.
echo "3. create_from_sections places an image and says so"

IMG=$(call "$OFFICE/docx-new/mcp" "$OFFICE_TOK" create_from_sections \
  "{\"title\":\"Board Paper\",\"sections\":[{\"heading\":\"Volume\",\"body\":\"Cargo grew 7%.\",\"image\":\"$DIR/pic.png\"}],\"output_path\":\"$DIR/paper.docx\"}")
if grep -q 'images_placed' <<<"$IMG"; then pass "images_placed is on the response"
else fail "no images_placed field"; fi
if grep -qE 'images_placed[^0-9]*1' <<<"$IMG"; then pass "the png was placed"
else fail "the png was not placed: $(grep -o 'images_placed[^,]*' <<<"$IMG" || true)"; fi
if [ -s "$HOST_DIR/paper.docx" ]; then pass "the document was written"
else fail "no document on disk"; fi

HTM=$(call "$OFFICE/docx-new/mcp" "$OFFICE_TOK" create_from_sections \
  "{\"title\":\"Board Paper\",\"sections\":[{\"heading\":\"Volume\",\"body\":\"Cargo grew 7%.\",\"image\":\"$DIR/chart.html\"}],\"output_path\":\"$DIR/paper2.docx\"}")
if grep -q 'image not placed' <<<"$HTM"; then pass "an HTML chart is refused out loud"
else fail "an HTML chart was dropped in silence"; fi
if [ -s "$HOST_DIR/paper2.docx" ]; then pass "and a bad picture does not cost the caller the paper"
else fail "the document was lost with the picture"; fi
echo

# --- fix 4: silence is not a clean bill of health ---------------------------
# A feature that already contains the outcome is the defect a 0.99 accuracy
# hides. The suspects deliberately do NOT move quality_score -- a hint is not
# a measurement -- so both halves are asserted.
echo "4. leakage is named, or its absence is explained"

WITH=$(call "$ML/medium/mcp" "$ML_TOK" check_data_quality \
  "{\"file_path\":\"$DIR/fixture.csv\",\"target_column\":\"loan_status\"}")
if grep -q 'leakage_suspects' <<<"$WITH"; then pass "check_data_quality names suspects for a target"
else fail "no leakage_suspects with a target"; fi
if grep -q 'total_payment' <<<"$WITH"; then pass "and names the leaking column itself"
else fail "the leak is not named"; fi
if grep -q 'quality_score' <<<"$WITH"; then pass "quality_score still reported"
else fail "quality_score missing"; fi

WITHOUT=$(call "$ML/medium/mcp" "$ML_TOK" check_data_quality \
  "{\"file_path\":\"$DIR/fixture.csv\"}")
if grep -q 'leakage_check' <<<"$WITHOUT"; then pass "no target -> says the check did not run"
else fail "no target -> silent about leakage"; fi
if grep -q 'leakage_suspects' <<<"$WITHOUT"; then fail "no target -> still claims a suspect list"
else pass "no target -> claims no clean bill of health"; fi

EVAL=$(call "$ML/medium/mcp" "$ML_TOK" evaluate_model \
  "{\"file_path\":\"$DIR/fixture.csv\",\"target_column\":\"loan_status\",\"model_path\":\"$DIR/model.pkl\"}")
if grep -qE 'leakage_note|leakage_suspects|leakage_count' <<<"$EVAL"; then
  pass "evaluate_model carries the caveat beside the score"
else fail "a score was quoted with no caveat"; fi

EDA=$(call "$DATA/visual/mcp" "$DATA_TOK" run_eda \
  "{\"file_path\":\"$DIR/fixture.csv\",\"target_column\":\"loan_status\",\"open_after\":false,\"output_path\":\"$DIR/eda.html\"}")
if grep -q 'leakage_suspects' <<<"$EDA"; then pass "run_eda names suspects for a target"
else fail "run_eda is silent about leakage"; fi
if [ -s "$HOST_DIR/eda.html" ] && grep -qi 'leakage' "$HOST_DIR/eda.html"; then
  pass "and the panel is in the page a person reads"
else fail "the report page has no leakage panel"; fi
echo

rm -rf "$HOST_DIR"
find /root/Harnesses/data -maxdepth 1 -name 'fixture_*' -delete
if [ "$FAILED" -eq 0 ]; then
  echo "all checks passed"
else
  echo "$FAILED check(s) failed"
fi
exit "$FAILED"
