#!/usr/bin/env bash
# Re-check every tool fixed on the vocabulary axis, against the live endpoints.
#
# The axis: a tool advertises, documents or implies a vocabulary, and then
# rejects or silently drops part of it. run_cleaning_pipeline accepted 8 of the
# 52 ops list_patch_ops prints; conditional_assign's condition dict was
# undocumented and raised KeyError('label'); the ten filter ops that read
# `value` returned the bare word 'value', or in filter_rows kept zero rows and
# called it success; four ml preprocessing ops raised out of the tool; and
# docx_new dropped any paragraph or heading written under an unrecognised key.
#
# Same shape as verify_n1.sh: direct curl, because this confirms a deployment
# rather than exercising a model. Several checks read the written file instead
# of the response, since that is the only place three of these defects existed.
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

DATA_BASE=$(get DATA_MCP_BASE_URL); DATA_TOK=$(get DATA_MCP_TOKEN)
ML_BASE=$(get ML_MCP_BASE_URL);     ML_TOK=$(get ML_MCP_TOKEN)
OFF_BASE=$(get OFFICE_MCP_BASE_URL); OFF_TOK=$(get OFFICE_MCP_TOKEN)

DIR=/workspace/data/vocab_verify          # as the containers see it
HOST=/root/Harnesses/data/vocab_verify    # the same bytes, from here
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

# Patterns allow an optional space after the colon: the Office servers
# pretty-print their JSON and the others do not, and a pattern written
# against one of them silently fails against the other -- which is how the
# first run of this script reported four failures that were all mine.
# Patterns are written `success\\?": ?true` rather than `"success":true`
# because the servers do not agree on either detail: Office pretty-prints
# its JSON (a space after the colon) and its payload arrives escaped inside
# the MCP envelope (a backslash before the quote), while the others do
# neither. A pattern written against one silently fails against the other,
# which is how the first two runs of this script reported four failures
# that were all mine -- every artifact check passed throughout.
check() {
  local label="$1" url="$2" tok="$3" tool="$4" args="$5" want="$6" out
  out=$(call "$url" "$tok" "$tool" "$args")
  if grep -qE "$want" <<<"$out"; then
    printf 'PASS  %-46s %s\n' "$label" "matched /$want/"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-46s wanted /%s/\n' "$label" "$want"
    printf '      %.400s\n' "$out"; FAIL=$((FAIL + 1))
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

# check_ooxml <label> <host-path> <inner-part> <pattern> — for .docx/.pptx,
# whose text is only visible inside the zip. Three of this round's defects were
# a document that opened fine and had the content missing.
check_ooxml() {
  local label="$1" path="$2" part="$3" want="$4"
  if [ -f "$path" ] && unzip -p "$path" "$part" 2>/dev/null | grep -qE "$want"; then
    printf 'PASS  %-46s %s contains /%s/\n' "$label" "$part" "$want"; PASS=$((PASS + 1))
  else
    printf 'FAIL  %-46s wanted /%s/ in %s of %s\n' "$label" "$want" "$part" "$path"; FAIL=$((FAIL + 1))
  fi
}

echo "=== data_analyst: the op catalog ==="
check "list_patch_ops advertises 52" "$DATA_BASE/basic/mcp" "$DATA_TOK" list_patch_ops \
  '{}' '"total_ops":52'
check "pipeline runs normalize" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"normalize\",\"column\":\"spend\",\"method\":\"minmax\"}],\"output_path\":\"$DIR/norm.csv\"}" \
  'success\\?": ?true'
check_file "  and the file really is scaled" "$HOST/norm.csv" '^W1,0\.0,' yes
check "pipeline runs rolling_agg" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"rolling_agg\",\"column\":\"spend\",\"window\":2,\"agg\":\"mean\",\"new_column\":\"roll\"}],\"output_path\":\"$DIR/roll.csv\"}" \
  'success\\?": ?true'
check_file "  and the column exists" "$HOST/roll.csv" '^region,spend,clicks,roll$' yes
check "pipeline runs round_values" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"round_values\",\"column\":\"spend\",\"decimals\":1}],\"output_path\":\"$DIR/round.csv\"}" \
  'success\\?": ?true'
check "pipeline still refuses a real unknown" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"teleport\"}],\"output_path\":\"$DIR/x.csv\"}" \
  'success\\?": ?false.*teleport'

echo "=== data_analyst: conditional_assign ==="
check "condition written the obvious way" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"conditional_assign\",\"new_column\":\"band\",\"conditions\":[{\"column\":\"spend\",\"op\":\">\",\"value\":50,\"then\":\"hi\"}],\"default\":\"lo\"}],\"output_path\":\"$DIR/band.csv\"}" \
  'success\\?": ?true'
check_file "  and the labels are in the file" "$HOST/band.csv" ',hi$' yes
check_file "  and so are the defaults" "$HOST/band.csv" ',lo$' yes
check "condition missing label names it" "$DATA_BASE/transform/mcp" "$DATA_TOK" run_cleaning_pipeline \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"conditional_assign\",\"new_column\":\"b\",\"conditions\":[{\"column\":\"spend\",\"op\":\"gt\",\"value\":50}]}],\"output_path\":\"$DIR/y.csv\"}" \
  'condition 0.*label'

echo "=== data_analyst: filter conditions ==="
check "filter_dataset gt with no value" "$DATA_BASE/transform/mcp" "$DATA_TOK" filter_dataset \
  "{\"file_path\":\"$DIR/rows.csv\",\"conditions\":[{\"column\":\"spend\",\"op\":\"gt\"}],\"output_path\":\"$DIR/f1.csv\"}" \
  "Condition 0.*'value'"
check "filter_rows equals with no value" "$DATA_BASE/medium/mcp" "$DATA_TOK" filter_rows \
  "{\"file_path\":\"$DIR/rows.csv\",\"conditions\":[{\"column\":\"region\",\"op\":\"equals\"}],\"output_path\":\"$DIR/f2.csv\",\"open_after\":false}" \
  "Condition 0.*'value'"
check_file "  and it wrote no empty file" "$HOST/f2.csv" '.' no
check "filter date_range with no dates" "$DATA_BASE/transform/mcp" "$DATA_TOK" filter_dataset \
  "{\"file_path\":\"$DIR/rows.csv\",\"conditions\":[{\"column\":\"region\",\"op\":\"date_range\"}],\"output_path\":\"$DIR/f3.csv\"}" \
  'neither .start. nor .end.'
check "filter gt against text" "$DATA_BASE/transform/mcp" "$DATA_TOK" filter_dataset \
  "{\"file_path\":\"$DIR/rows.csv\",\"conditions\":[{\"column\":\"spend\",\"op\":\"gt\",\"value\":\"abc\"}],\"output_path\":\"$DIR/f4.csv\"}" \
  'needs a number'
check "a complete filter still filters" "$DATA_BASE/transform/mcp" "$DATA_TOK" filter_dataset \
  "{\"file_path\":\"$DIR/rows.csv\",\"conditions\":[{\"column\":\"spend\",\"op\":\"gt\",\"value\":50}],\"output_path\":\"$DIR/f5.csv\"}" \
  'success\\?": ?true'
check_file "  and kept the right rows" "$HOST/f5.csv" '^W0,60,18$' yes
check_file "  and dropped the rest" "$HOST/f5.csv" '^W1,10,3$' no

echo "=== data_analyst: pipeline templates ==="
check "save refuses an op that cannot run" "$DATA_BASE/workspace/mcp" "$DATA_TOK" save_workspace_pipeline \
  '{"workspace_name":"vocabws","pipeline_name":"p","ops":[{"op":"drop_nulls"}]}' \
  'success\\?": ?false.*drop_nulls'

echo "=== machine_learning ==="
check "log_transform with no column" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"log_transform\"}],\"output_path\":\"$DIR/m1.csv\"}" \
  'success\\?": ?false.*column'
check "bin_numeric with no column" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"bin_numeric\"}],\"output_path\":\"$DIR/m2.csv\"}" \
  'success\\?": ?false.*column'
check "add_date_parts with no column" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"add_date_parts\"}],\"output_path\":\"$DIR/m3.csv\"}" \
  'success\\?": ?false.*column'
check "clip_column with no column" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"clip_column\"}],\"output_path\":\"$DIR/m4.csv\"}" \
  'success\\?": ?false.*column'
check "dropping a column that is not there" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"drop_column\",\"column\":\"ghost\"}],\"output_path\":\"$DIR/m5.csv\"}" \
  'success\\?": ?false.*column not found'
check_file "  and wrote nothing" "$HOST/m5.csv" '.' no
check "a real pipeline still runs" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/rows.csv\",\"ops\":[{\"op\":\"log_transform\",\"column\":\"spend\"}],\"output_path\":\"$DIR/m6.csv\"}" \
  'success\\?": ?true'
check_file "  and wrote the new column" "$HOST/m6.csv" 'spend_log' yes

echo "=== microsoft_office ==="
check "paragraph under 'content'" "$OFF_BASE/docx-new/mcp" "$OFF_TOK" create_from_text \
  "{\"paragraphs\":[{\"content\":\"VocabCheckAlpha\"}],\"output_path\":\"$DIR/p.docx\"}" \
  'success\\?": ?true'
check_ooxml "  and the text is in the document" "$HOST/p.docx" word/document.xml 'VocabCheckAlpha'
check "section under 'header'" "$OFF_BASE/docx-new/mcp" "$OFF_TOK" create_from_sections \
  "{\"title\":\"T\",\"sections\":[{\"header\":\"VocabCheckBeta\",\"body\":\"B\"}],\"output_path\":\"$DIR/s.docx\"}" \
  'success\\?": ?true'
check_ooxml "  and the heading survived" "$HOST/s.docx" word/document.xml 'VocabCheckBeta'
check "paragraphs carrying nothing refused" "$OFF_BASE/docx-new/mcp" "$OFF_TOK" create_from_text \
  "{\"paragraphs\":[{\"zzz\":\"x\"}],\"output_path\":\"$DIR/junk.docx\"}" \
  'success\\?": ?false.*zzz'
check "deck bullets under 'items'" "$OFF_BASE/pptx-new/mcp" "$OFF_TOK" create_deck_from_data \
  "{\"title\":\"T\",\"data_slides\":[{\"heading\":\"H\",\"items\":[\"VocabCheckGamma\"]}],\"output_path\":\"$DIR/d.pptx\"}" \
  'success\\?": ?true'
check_ooxml "  and the bullets are on the slide" "$HOST/d.pptx" 'ppt/slides/slide2.xml' 'VocabCheckGamma'

echo "=== round-14 harness findings: data_analyst ==="
check "search_columns dtype=float64 filters" "$DATA_BASE/basic/mcp" "$DATA_TOK" search_columns \
  "{\"file_path\":\"$DIR/rows.csv\",\"dtype\":\"float64\"}" \
  'matched\\?": ?2'
check "search_columns dtype=str filters" "$DATA_BASE/basic/mcp" "$DATA_TOK" search_columns \
  "{\"file_path\":\"$DIR/rows.csv\",\"dtype\":\"str\"}" \
  '"matched": ?1'
check "search_columns refuses a bad dtype" "$DATA_BASE/basic/mcp" "$DATA_TOK" search_columns \
  "{\"file_path\":\"$DIR/rows.csv\",\"dtype\":\"complex128\"}" \
  'success\\?": ?false.*complex128'
check "merge matched counts real matches" "$DATA_BASE/transform/mcp" "$DATA_TOK" merge_datasets \
  "{\"file_path\":\"$DIR/left.csv\",\"right_file_path\":\"$DIR/right.csv\",\"left_on\":\"k\",\"right_on\":\"k\",\"how\":\"left\",\"output_path\":\"$DIR/merged.csv\"}" \
  'matched\\?": ?2'
check_file "  and no indicator column leaked" "$HOST/merged.csv" '_merge_side' no
check "aggregate refuses an arg its mode ignores" "$DATA_BASE/transform/mcp" "$DATA_TOK" aggregate_dataset \
  "{\"file_path\":\"$DIR/rows.csv\",\"mode\":\"value_counts\",\"row_col\":\"region\"}" \
  'does not read row_col'
check "list_patch_ops category=original" "$DATA_BASE/basic/mcp" "$DATA_TOK" list_patch_ops \
  '{"category":"original"}' 'total_ops\\?": ?13'

echo "=== round-14 harness findings: machine_learning ==="
check "clip_column reads min/max" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/small.csv\",\"ops\":[{\"op\":\"clip_column\",\"column\":\"n\",\"min\":0,\"max\":100}],\"output_path\":\"$DIR/clip.csv\"}" \
  'success\\?": ?true'
check_file "  and 900 really became 100" "$HOST/clip.csv" '^c,100' yes
check "label_encode honours new_column" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/small.csv\",\"ops\":[{\"op\":\"label_encode\",\"column\":\"cat\",\"new_column\":\"cat_enc\"}],\"output_path\":\"$DIR/enc.csv\"}" \
  'success\\?": ?true'
check_file "  and the new column exists" "$HOST/enc.csv" '^cat,n,cat_enc$' yes
check_file "  and the source survived" "$HOST/enc.csv" '^a,1,0$' yes
check "an unlisted log base is refused" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/small.csv\",\"ops\":[{\"op\":\"log_transform\",\"column\":\"n\",\"base\":\"log5\"}],\"output_path\":\"$DIR/lg.csv\"}" \
  'invalid base .log5.'
check "a misspelled op field is refused" "$ML_BASE/medium/mcp" "$ML_TOK" run_preprocessing \
  "{\"file_path\":\"$DIR/small.csv\",\"ops\":[{\"op\":\"clip_column\",\"column\":\"n\",\"lowr\":0}],\"output_path\":\"$DIR/x.csv\"}" \
  'did you mean lower'
check "dbscan refuses what would kill it" "$ML_BASE/medium/mcp" "$ML_TOK" run_clustering \
  "{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"feature_columns\":[\"clicks\",\"spends\",\"impressions\"],\"algorithm\":\"dbscan\"}" \
  'success\\?": ?false.*16,834'
check "and the server is still answering" "$ML_BASE/medium/mcp" "$ML_TOK" run_clustering \
  "{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"feature_columns\":[\"clicks\",\"spends\"],\"algorithm\":\"kmeans\",\"n_clusters\":3}" \
  'success\\?": ?true'
check "find_optimal_clusters names its features" "$ML_BASE/medium/mcp" "$ML_TOK" find_optimal_clusters \
  "{\"file_path\":\"/workspace/data/Ad_Data.csv\",\"feature_columns\":[\"clicks\",\"device\",\"spends\"],\"max_k\":3,\"open_after\":false}" \
  'features_skipped\\?": ?\[[^]]*device'

echo "=== round-14 harness findings: microsoft_office ==="
check "outline builds the Title Only layout" "$OFF_BASE/pptx-new/mcp" "$OFF_TOK" create_from_outline \
  "{\"slides\":[{\"title\":\"VocabTitleOnly\",\"content\":\"body\",\"layout\":\"Title Only\"}],\"output_path\":\"$DIR/lay.pptx\"}" \
  'success\\?": ?true'
check_ooxml "  and the body is not on the slide" "$HOST/lay.pptx" 'ppt/slides/slide1.xml' 'VocabTitleOnly'
check "an unknown layout is refused" "$OFF_BASE/pptx-new/mcp" "$OFF_TOK" create_from_outline \
  "{\"slides\":[{\"title\":\"T\",\"layout\":\"zzz\"}],\"output_path\":\"$DIR/bad.pptx\"}" \
  'success\\?": ?false.*zzz'
check "sections doc -> one slide per section" "$OFF_BASE/docx-new/mcp" "$OFF_TOK" create_from_sections \
  "{\"title\":\"DeckTitle\",\"sections\":[{\"heading\":\"SecAlpha\",\"body\":\"a\"},{\"heading\":\"SecBeta\",\"body\":\"b\"}],\"output_path\":\"$DIR/src.docx\"}" \
  'success\\?": ?true'
check "  converted to a deck" "$OFF_BASE/pptx-new/mcp" "$OFF_TOK" create_from_docx \
  "{\"docx_path\":\"$DIR/src.docx\",\"output_path\":\"$DIR/conv.pptx\"}" \
  'slide_count\\?": ?3'
check_ooxml "  and SecBeta has its own slide" "$HOST/conv.pptx" 'ppt/slides/slide3.xml' 'SecBeta'

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
