#!/usr/bin/env bash
# Real-inference smoke test: send a prompt through each harness's one-shot CLI
# mode (or tmux send-keys for harnesses without one) and verify the model
# actually replied with non-empty text.
#
# Failures here mean one of:
#   (a) the harness's one-shot mode has a different CLI shape than expected
#   (b) the model on this provider is misbehaving for this harness
#   (c) the harness rejects this provider (e.g., Claude Code with a model
#       that only returns `thinking` blocks)
#
# Usage:
#   ./scripts/test-inference.sh                # all testable harnesses
#   ./scripts/test-inference.sh aider crush    # subset
#   KEEP_OUTPUT=1 ./scripts/test-inference.sh  # keep /tmp/infer-<h>.log files

set -uo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

PROMPT="Reply with exactly the four characters PONG and nothing else."

# How to drive each harness in one-shot mode.  Empty value = no programmable
# one-shot mode available; the test skips it and reports MANUAL.
declare -A CMD=(
  [claude]='claude -p "$PROMPT"'
  [aider]='aider --no-stream --no-auto-commits --yes-always --message "$PROMPT" . </dev/null'
  [opencode]='opencode run "$PROMPT"'
  [crush]='crush run "$PROMPT"'
  [gptme]='gptme --non-interactive "$PROMPT"'
  [goose]='goose run -t "$PROMPT"'
  [plandex]='PLANDEX'                                   # multi-step: plandex new + tell --bg + poll convo
  [qwencode]='qwen -m $MODEL_NAME "$PROMPT"'
  [openhands]='WEB:3000'                                # web UI — verify HTTP response
  [kilocode]='WEB:8080'                                 # code-server — verify HTTP response
  [codex]='codex exec "$PROMPT"'
  [pi]='pi "$PROMPT"'
  [droid]='droid exec -m "$MODEL_NAME" "$PROMPT"'        # BYOK custom model via ~/.factory/settings.json
)
ALL=( claude aider opencode crush gptme goose plandex qwencode openhands kilocode codex pi droid )
TARGETS=( "$@" ); [ ${#TARGETS[@]} -eq 0 ] && TARGETS=( "${ALL[@]}" )

# Guarantee always-on services are up before testing.  `docker compose up`
# with --profile on-demand has been known to recreate no-profile services
# (plandex-server, plandex-postgres) and leave them stopped — bring them back.
docker compose up -d auth plandex-postgres plandex-server >/dev/null 2>&1 || true
sleep 2

AUTH_IP=$(docker inspect harnesses-auth --format '{{(index .NetworkSettings.Networks "harnesses_net").IPAddress}}')
[ -n "$AUTH_IP" ] && [ "$AUTH_IP" != "<no value>" ] \
    || { echo "harnesses-auth not running — run 'docker compose up -d auth' first" >&2; exit 2; }

PASS=0; FAIL=0; SKIP=0
printf '%-14s %-8s %-7s %s\n' HARNESS RESULT TIME NOTE
printf '%-14s %-8s %-7s %s\n' -------- ------ ---- ----

for h in "${TARGETS[@]}"; do
    cmd="${CMD[$h]}"
    if [ -z "$cmd" ]; then
        case "$h" in
            droid)    note="factory.ai required — set FACTORY_API_KEY (fk-...) in .env";;
            *)        note="no one-shot mode";;
        esac
        printf '%-14s %-8s %-7s %s\n' "$h" "SKIP" "-" "$note"
        SKIP=$((SKIP+1)); continue
    fi

    # Wake the container.
    token=$(python3 scripts/generate-tokens.py --only "$h" 2>/dev/null | cut -d= -f2)
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
        -H "Cookie: harness_session=${token}" \
        "http://${AUTH_IP}:8080/verify?harness=${h}")
    if [ "$code" != "200" ]; then
        printf '%-14s %-8s %-7s %s\n' "$h" "FAIL" "-" "wake failed: HTTP $code"
        FAIL=$((FAIL+1)); continue
    fi

    # Plandex needs a multi-step flow because its stream UI requires a TTY:
    # create a plan with the --oss pack, submit via `tell --bg`, poll convo.
    if [ "$cmd" = "PLANDEX" ]; then
        log="/tmp/infer-${h}.log"
        start=$(date +%s)
        docker exec "harness-${h}" sh -c '
            set -e
            plandex new --oss --name "t-$$" >/dev/null 2>&1
            plandex set-auto basic >/dev/null 2>&1
            plandex tell --bg "Reply with exactly the four characters PONG and nothing else." >/dev/null 2>&1
            for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
                sleep 10
                status=$(plandex ps 2>/dev/null | sed -E "s/\x1b\[[0-9;]*[mK]//g" | grep -oE "Finished|Error|Running" | head -1)
                if [ "$status" = "Finished" ] || [ "$status" = "Error" ]; then break; fi
            done
            plandex convo --plain 2>/dev/null | sed -E "s/\x1b\[[0-9;]*[mK]//g" | tail -50
        ' > "$log" 2>&1
        rc=$?
        elapsed=$(( $(date +%s) - start ))
        if grep -q "PONG" "$log"; then
            preview=$(grep -i pong "$log" | head -1 | cut -c1-60)
            printf '%-14s %-8s %-7s %s\n' "$h" "PASS" "${elapsed}s" "PONG found; $preview"
            PASS=$((PASS+1))
        else
            preview=$(tail -1 "$log" | tr -s '[:space:]' ' ' | cut -c1-80)
            printf '%-14s %-8s %-7s %s\n' "$h" "FAIL" "${elapsed}s" "no PONG; $preview"
            FAIL=$((FAIL+1))
        fi
        [ "${STOP_AFTER:-0}" = "1" ] && docker stop "harness-${h}" >/dev/null 2>&1 || true
        continue
    fi

    # Web-app harnesses: PASS = the UI HTTP endpoint responds.
    if [[ "$cmd" == WEB:* ]]; then
        port="${cmd#WEB:}"
        start=$(date +%s)
        wcode=$(docker exec caddy-router wget -qSO /dev/null --tries=1 --timeout=10 \
            "http://harness-${h}:${port}/" 2>&1 | awk '/^  HTTP/ {print $2; exit}')
        elapsed=$(( $(date +%s) - start ))
        if [ -n "$wcode" ] && [ "$wcode" -ge 200 ] && [ "$wcode" -lt 500 ]; then
            printf '%-14s %-8s %-7s %s\n' "$h" "PASS" "${elapsed}s" "web UI HTTP ${wcode}"
            PASS=$((PASS+1))
        else
            printf '%-14s %-8s %-7s %s\n' "$h" "FAIL" "${elapsed}s" "web UI HTTP ${wcode:-unreachable}"
            FAIL=$((FAIL+1))
        fi
        [ "${STOP_AFTER:-0}" = "1" ] && docker stop "harness-${h}" >/dev/null 2>&1 || true
        continue
    fi

    # Drive the CLI inside the container with a generous timeout.  Reasoning
    # models on free tiers (e.g. nemotron-3) can take 60-120s through an
    # agentic CLI's tool loop before emitting final content.
    log="/tmp/infer-${h}.log"
    start=$(date +%s)
    docker exec "harness-${h}" sh -c "PROMPT=\"$PROMPT\"; timeout 150 $cmd" \
        > "$log" 2>&1
    rc=$?
    elapsed=$(( $(date +%s) - start ))

    bytes=$(wc -c < "$log" 2>/dev/null || echo 0)
    # Strip ANSI escapes for cleaner inspection.
    clean=$(sed -E 's/\x1b\[[0-9;]*[mK]//g' "$log" 2>/dev/null | head -c 4000)
    preview=$(printf '%s' "$clean" | tr -s '[:space:]' ' ' | cut -c1-80)

    note=""
    if [ "$rc" = "124" ]; then
        result=TIMEOUT; note="exceeded 150s; ${bytes}B; $preview"
    elif [ "$bytes" -lt 5 ]; then
        result=FAIL; note="no output (rc=${rc})"
    elif printf '%s' "$clean" | grep -qiE 'pong'; then
        result=PASS; note="${bytes}B PONG; $preview"
    elif printf '%s' "$clean" | grep -qiE 'no provider|no auth|configure first|not configured|please run.*config|no API key|unknown.*flag|unknown command'; then
        result=CONFIG; note="cli config issue; $preview"
    elif printf '%s' "$clean" | grep -qiE 'issue with the selected model|model.*not (found|supported|available)|invalid model'; then
        result=MODEL; note="provider rejected model; $preview"
    elif printf '%s' "$clean" | grep -qiE '401|403|unauthor|user not found|invalid api key'; then
        result=AUTH; note="auth rejected; $preview"
    elif [ "$bytes" -gt 100 ]; then
        result=PARTIAL; note="${bytes}B no PONG; $preview"
    else
        result=FAIL; note="thin output (${bytes}B); $preview"
    fi

    printf '%-14s %-8s %-7s %s\n' "$h" "$result" "${elapsed}s" "$note"
    case "$result" in
        PASS|PARTIAL) PASS=$((PASS+1)) ;;
        *)            FAIL=$((FAIL+1)) ;;
    esac

    docker stop "harness-${h}" >/dev/null 2>&1 || true
    # Always keep logs on non-PASS so the failure note can be inspected.
    if [ "${KEEP_OUTPUT:-0}" != "1" ] && [ "$result" = "PASS" ]; then
        rm -f "$log"
    fi
done

echo
echo "INFERENCE: $PASS reached the model, $FAIL broken, $SKIP skipped (manual only)"
[ "${KEEP_OUTPUT:-0}" = "1" ] && echo "Full logs preserved under /tmp/infer-*.log"
exit $(( FAIL > 0 ? 1 : 0 ))
