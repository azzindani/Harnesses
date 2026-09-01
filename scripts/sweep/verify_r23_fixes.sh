#!/usr/bin/env bash
# Assert round 23's three fixes over MCP, against the DEPLOYED office server.
#
#     ./verify_r23_fixes.sh
#
# No model, no quota, no tmux -- so a provider outage cannot turn this red and
# a model choosing its own inputs cannot turn it green. Round 22 shipped five
# fixes that a whole sweep round failed to re-test, because a model picking its
# own arguments picks the branch the fix did not change: 4-for-4 in one round.
# This calls the exact broken input and asserts the exact new string.
#
# Reads values out of the envelope with the escaped-key pattern. A tool's
# document arrives as the JSON *string* `result.content[0].text`, so keys come
# back as \"slide_count\": 0. Patterns written for unescaped JSON match nothing
# while every call still succeeds -- four of six repos' smoke scripts had
# silently stopped asserting anything that way. Every extractor ends `|| true`,
# because under `set -euo pipefail` one that matches nothing aborts the script
# before its own failure can be reported.
set -uo pipefail

ENV_FILE=/root/Harnesses/.env
get() { grep "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
BASE=$(get OFFICE_MCP_BASE_URL)
TOK=$(get OFFICE_MCP_TOKEN)
DIR=/workspace/data/verify_r23_fixes
FAILED=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }

# One MCP session per mount, then a tools/call. The servers speak streamable
# HTTP, so replies arrive as SSE `data:` lines even when Accept allows JSON.
call() {
  local mount="$1" tool="$2" args="$3" url hdr sid
  url="$BASE/$mount/mcp"
  hdr=$(mktemp)
  curl -s --max-time 30 -X POST "$url" -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
    -D "$hdr" >/dev/null
  sid=$(grep -i '^mcp-session-id' "$hdr" | tr -d '\r' | awk '{print $2}')
  rm -f "$hdr"
  [ -z "$sid" ] && { echo "NO SESSION on $url"; return 1; }
  curl -s --max-time 30 -X POST "$url" -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s --max-time 120 -X POST "$url" -H "Authorization: Bearer $TOK" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: $sid" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$tool\",\"arguments\":$args}}" \
    | tr -d '\r' | grep '^data:' | sed 's/^data: //'
}

echo "office: $BASE"
echo

# --- fix 1: batch_create_from_template must not double .docx -----------------
echo "1. batch_create_from_template does not double the extension"

call docx-new create_from_text \
  "{\"paragraphs\":[{\"text\":\"Hello {{name}}\",\"style\":\"Normal\"}],\"output_path\":\"$DIR/tpl.docx\"}" >/dev/null

OUT=$(call docx-new batch_create_from_template \
  "{\"template_path\":\"$DIR/tpl.docx\",\"data_list\":[{\"name\":\"Alice\",\"filename\":\"alice.docx\"},{\"name\":\"Bob\",\"filename\":\"bob\"}],\"output_dir\":\"$DIR/batch\",\"filename_key\":\"filename\"}")

if grep -q 'alice\\*\.docx\\*\.docx' <<<"$OUT"; then
  fail "alice.docx.docx is still produced"
else
  pass "no .docx.docx in the response"
fi
if grep -q 'alice\.docx' <<<"$OUT"; then pass "alice.docx present"; else fail "alice.docx missing entirely"; fi
if grep -q 'bob\.docx' <<<"$OUT"; then pass "bob.docx still gets its extension"; else fail "bob.docx missing"; fi
echo

# --- fix 2: diff_versions counts a removed slide -----------------------------
echo "2. diff_versions counts a slide that was deleted"

call pptx-new create_from_outline \
  "{\"slides\":[{\"title\":\"One\",\"content\":\"a\"},{\"title\":\"Two\",\"content\":\"b\"}],\"output_path\":\"$DIR/deck.pptx\"}" >/dev/null

# delete_slide snapshots first, so its own timestamp is version A.
DEL=$(call pptx-basic delete_slide "{\"file_path\":\"$DIR/deck.pptx\",\"slide_index\":1}")
TS=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{6}Z' <<<"$DEL" | head -1 || true)

if [ -z "$TS" ]; then
  fail "no snapshot timestamp came back from delete_slide -- cannot diff"
else
  D=$(call pptx-basic diff_versions "{\"file_path\":\"$DIR/deck.pptx\",\"timestamp_a\":\"$TS\"}")
  CC=$(grep -oE '\\?"change_count\\?"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$D" | grep -oE '[0-9]+$' | head -1 || true)
  SC=$(grep -oE '\\?"slide_count_changed\\?"[[:space:]]*:[[:space:]]*(true|false)' <<<"$D" | grep -oE '(true|false)$' | head -1 || true)
  echo "     change_count=${CC:-?}  slide_count_changed=${SC:-?}"
  if [ "${SC:-}" = "true" ]; then pass "slide_count_changed is true"; else fail "slide_count_changed is not true (${SC:-unset})"; fi
  if [ -n "${CC:-}" ] && [ "$CC" -gt 0 ]; then
    pass "change_count is $CC, not 0"
  else
    fail "change_count is ${CC:-unset} for a deleted slide"
  fi
  if grep -q 'slide_changes' <<<"$D"; then pass "slide_changes is present"; else fail "slide_changes missing from the response"; fi
fi
echo

# --- fix 3: create_from_docx warns about an empty deck -----------------------
echo "3. create_from_docx warns when it saves 0 slides"

call docx-new create_from_text "{\"paragraphs\":[],\"output_path\":\"$DIR/empty.docx\"}" >/dev/null
E=$(call pptx-new create_from_docx "{\"docx_path\":\"$DIR/empty.docx\",\"output_path\":\"$DIR/zero.pptx\"}")

SLIDES=$(grep -oE '\\?"slide_count\\?"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$E" | grep -oE '[0-9]+$' | head -1 || true)
echo "     slide_count=${SLIDES:-?}"
if [ "${SLIDES:-}" = "0" ]; then pass "the empty source still yields 0 slides"; else fail "expected slide_count 0, got ${SLIDES:-unset}"; fi
if grep -q 'Deck is empty' <<<"$E"; then pass "the empty-deck warning is present"; else fail "no warn in progress -- the empty deck is still silent"; fi
if grep -q '0 slides' <<<"$E"; then pass "the warning names the count"; else fail "nothing in the response says 0 slides"; fi
if grep -q 'empty\.docx' <<<"$E"; then pass "the warning names the source"; else fail "the warning does not name the source document"; fi
echo

# --- a non-empty deck must NOT be warned about -------------------------------
echo "4. a deck with slides is not warned about (the fix did not overfire)"
call docx-new create_from_text \
  "{\"paragraphs\":[{\"text\":\"First\",\"style\":\"Heading 1\"},{\"text\":\"body\",\"style\":\"Normal\"},{\"text\":\"Second\",\"style\":\"Heading 1\"}],\"output_path\":\"$DIR/full.docx\"}" >/dev/null
F=$(call pptx-new create_from_docx "{\"docx_path\":\"$DIR/full.docx\",\"output_path\":\"$DIR/full.pptx\"}")
FS=$(grep -oE '\\?"slide_count\\?"[[:space:]]*:[[:space:]]*[0-9]+' <<<"$F" | grep -oE '[0-9]+$' | head -1 || true)
echo "     slide_count=${FS:-?}"
if [ -n "${FS:-}" ] && [ "$FS" -gt 0 ]; then
  pass "slide_count is $FS"
else
  fail "a real document produced ${FS:-no} slides"
fi
if grep -q 'Deck is empty' <<<"$F"; then
  fail "a non-empty deck was warned about"
else
  pass "no empty-deck warning"
fi
echo

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED assertion(s) FAILED"
  exit 1
fi
echo "all assertions passed"
