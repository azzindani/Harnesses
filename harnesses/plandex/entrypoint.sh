#!/bin/sh
set -e

# Plandex CLI talks to a backend server.  PLANDEX_API_HOST points it at our
# self-hosted plandex-server (compose service) which runs with LOCAL_MODE=1 +
# GOENV=development so /accounts requires no email verification.
PLANDEX_API_HOST="${PLANDEX_API_HOST:-http://plandex-server:8099}"
export PLANDEX_API_HOST
export PROVIDER_API_KEY="${PROVIDER_API_KEY:-not-used}"

# Plandex's built-in model packs (--oss, --strong, etc.) authenticate via
# provider-specific env vars.  Alias our generic key into all of them so
# whichever pack the user picks works.
export OPENROUTER_API_KEY="${PROVIDER_API_KEY}"
export OPENAI_API_KEY="${PROVIDER_API_KEY}"
export DEEPSEEK_API_KEY="${PROVIDER_API_KEY}"

# Bootstrap auth state: create a fresh account on the local server every boot
# (idempotent via a per-boot email) and write the resulting token into the
# CLI's expected config files so plandex skips its interactive sign-in prompt.
HOME_DIR=/root/.plandex-home-v2
mkdir -p "$HOME_DIR"

BOOT_EMAIL="lab-$(hostname)-$(date +%s)@harnesses.local"
RESP=$(curl -sS -X POST -H "Content-Type: application/json" \
    "$PLANDEX_API_HOST/accounts" \
    -d "{\"userName\":\"lab\",\"email\":\"${BOOT_EMAIL}\"}" 2>/dev/null || echo '{}')

python3 - <<PY "$RESP" "$PLANDEX_API_HOST" "$BOOT_EMAIL" "$HOME_DIR"
import json, sys
resp_text, host, email, home = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    r = json.loads(resp_text)
except Exception:
    r = {}
account = {
    "isCloud": False,
    "host": host,
    "email": email,
    "userName": r.get("userName", "lab"),
    "userId": r.get("userId", ""),
    "token": r.get("token", ""),
    "isLocalMode": True,
}
auth = {**account, "orgId": "", "orgName": "Personal", "orgIsTrial": False, "integratedModelsMode": False}
import os
with open(os.path.join(home, "accounts.json"), "w") as f:
    json.dump([account], f)
with open(os.path.join(home, "auth.json"), "w") as f:
    json.dump(auth, f)
PY

# Bring-your-own-provider via custom-models.json — picked up by `plandex models`.
mkdir -p /workspace
cat > /workspace/custom-models.json <<EOF
[
  {
    "modelTag": "${MODEL_NAME}",
    "publisher": "lab",
    "description": "Lab-configured ${MODEL_NAME}",
    "defaultMaxConvoTokens": 100000,
    "defaultMaxTokens": 4096,
    "baseUrl": "${PROVIDER_BASE_URL}",
    "apiKeyEnvVar": "PROVIDER_API_KEY"
  }
]
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "plandex" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
