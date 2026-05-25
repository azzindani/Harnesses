#!/usr/bin/env bash
# End-to-end smoke test for every harness.
#
# For each harness this script:
#   1. mints a 30-day JWT via scripts/generate-tokens.py
#   2. POSTs it to harnesses-auth /verify (which wakes the container)
#   3. polls the harness's listen port from inside caddy-router's network view
#   4. from inside the harness container, curls the configured provider /models
#      using the env vars compose has already wired
#   5. checks that the expected CLI / web-app process is alive
#
# Output is one row per harness plus an aggregate pass/fail at the end.
#
# Usage:
#   ./scripts/test-all-harnesses.sh                 # test all 13
#   ./scripts/test-all-harnesses.sh aider crush     # subset
#   STOP_AFTER=1 ./scripts/test-all-harnesses.sh    # stop each container when done

set -uo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

# port + process pattern per harness.  Web apps (openhands, kilocode) leave
# PROC empty — only the port check is meaningful there.
declare -A PORT=(
  [claude-code]=7681 [aider]=7681 [opencode]=7681 [crush]=7681 [gptme]=7681
  [goose]=7681 [plandex]=7681 [qwencode]=7681 [codex]=7681 [pi]=7681 [droid]=7681
  [openhands]=3000 [kilocode]=8080
)
declare -A PROC=(
  [claude-code]=claude    [aider]=aider          [opencode]=opencode
  [crush]=crush           [gptme]=gptme          [goose]=goose
  [plandex]=plandex       [qwencode]="qwen"      [codex]=codex
  [pi]="pi"               [droid]=droid
  [openhands]=""          [kilocode]=""
)
# pi ships a stub on the image; skip the process check for it explicitly.
SKIP_PROC_CHECK="pi"

ALL=( claude-code aider opencode crush gptme goose plandex qwencode openhands kilocode codex pi droid )
TARGETS=( "$@" ); [ ${#TARGETS[@]} -eq 0 ] && TARGETS=( "${ALL[@]}" )

AUTH_IP=$(docker inspect harnesses-auth --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
[ -n "$AUTH_IP" ] || { echo "harnesses-auth not running — run 'docker compose up -d auth' first" >&2; exit 2; }

PASS=0; FAIL=0
printf '%-14s %-10s %-8s %-12s %-14s %s\n' HARNESS WAKE PORT PROVIDER PROCESS NOTES
printf '%-14s %-10s %-8s %-12s %-14s %s\n' -------- ---- ---- -------- ------- -----

for h in "${TARGETS[@]}"; do
    note=""

    # 1. mint token, hit /verify
    token=$(python3 scripts/generate-tokens.py --only "$h" 2>/dev/null | cut -d= -f2)
    if [ -z "$token" ]; then
        printf '%-14s %-10s %-8s %-12s %-14s %s\n' "$h" "FAIL" skip skip skip "token gen failed"
        FAIL=$((FAIL+1)); continue
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
        -H "Cookie: harness_session=${token}" \
        "http://${AUTH_IP}:8080/verify?harness=${h}")
    if [ "$code" = "200" ]; then wake=PASS; else wake="FAIL($code)"; fi

    # 2. poll the listen port — accept any HTTP response (2xx / 3xx),
    # since code-server redirects with 302 and that still proves "service up".
    port=${PORT[$h]}
    port_status=skip
    if [ "$wake" = "PASS" ]; then
        port_status=FAIL
        for _ in $(seq 1 30); do
            pcode=$(docker exec caddy-router wget -qSO /dev/null --tries=1 --timeout=2 \
                "http://harness-${h}:${port}/" 2>&1 | awk '/^  HTTP/ {print $2; exit}')
            if [ -n "$pcode" ] && [ "$pcode" -ge 200 ] && [ "$pcode" -lt 500 ]; then
                port_status=PASS; break
            fi
            sleep 0.5
        done
    fi

    # 3. provider reachability from inside the container
    prov_status=skip
    if [ "$wake" = "PASS" ]; then
        # Try the OpenAI surface (every harness has PROVIDER_BASE_URL via env_file).
        prov_code=$(docker exec "harness-${h}" sh -c 'curl -sS -o /dev/null -w "%{http_code}" --max-time 10 -H "Authorization: Bearer $PROVIDER_API_KEY" "$PROVIDER_BASE_URL/models"' 2>/dev/null || echo EX)
        if [ "$prov_code" = "200" ]; then prov_status=PASS; else prov_status="FAIL($prov_code)"; fi
    fi

    # 4. process check (skip for web-app harnesses and explicit opt-outs)
    pp="${PROC[$h]}"
    proc_status=skip
    if [ -z "$pp" ]; then
        proc_status="(web)"
    elif echo "$SKIP_PROC_CHECK" | tr ' ' '\n' | grep -qx "$h"; then
        proc_status="(skip)"
    elif [ "$wake" = "PASS" ]; then
        # tmux fires the CLI after a brief delay — give it a beat.
        sleep 1
        if docker exec "harness-${h}" sh -c "ps -ef | grep -v grep | grep -E '$pp' >/dev/null"; then
            proc_status="PASS"
        else
            proc_status="FAIL"
            note="${note}no $pp proc; "
        fi
    fi

    printf '%-14s %-10s %-8s %-12s %-14s %s\n' "$h" "$wake" "$port_status" "$prov_status" "$proc_status" "$note"

    if [ "$wake" = "PASS" ] && [ "$port_status" = "PASS" ] && [ "$prov_status" = "PASS" ] \
       && { [ "$proc_status" = "PASS" ] || [ "$proc_status" = "(web)" ] || [ "$proc_status" = "(skip)" ]; }; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi

    [ "${STOP_AFTER:-0}" = "1" ] && docker stop "harness-${h}" >/dev/null 2>&1 || true
done

echo
echo "RESULT: $PASS / $((PASS+FAIL)) passed"
exit $(( FAIL > 0 ? 1 : 0 ))
