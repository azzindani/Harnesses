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
# Bring-your-own-model via Plandex v2's models-input schema. The model is on
# OpenRouter, so it rides the built-in `openrouter` provider (authed by the
# OPENROUTER_API_KEY exported above) — no custom provider needed. We also define
# a model pack "lab" that uses nemotron for every role, then import + --save it
# so `plandex models` lists it and `plandex set-model lab` selects it.
mkdir -p /workspace
cat > /workspace/custom-models.json <<EOF
{
  "\$schema": "https://plandex.ai/schemas/models-input.schema.json",
  "models": [
    {
      "modelId": "lab/nemotron",
      "publisher": "lab",
      "description": "Lab ${MODEL_NAME} via OpenRouter",
      "defaultMaxConvoTokens": 75000,
      "maxTokens": 128000,
      "maxOutputTokens": 16000,
      "reservedOutputTokens": 16000,
      "preferredOutputFormat": "xml",
      "providers": [
        { "provider": "openrouter", "modelName": "${MODEL_NAME}" }
      ]
    }
  ],
  "modelPacks": [
    {
      "name": "lab",
      "description": "Lab nemotron pack (nemotron for every role)",
      "planner": "lab/nemotron",
      "architect": "lab/nemotron",
      "coder": { "modelId": "lab/nemotron" },
      "summarizer": "lab/nemotron",
      "builder": { "modelId": "lab/nemotron" },
      "wholeFileBuilder": { "modelId": "lab/nemotron" },
      "names": "lab/nemotron",
      "commitMessages": "lab/nemotron",
      "autoContinue": "lab/nemotron"
    }
  ]
}
EOF

# Import the custom model + pack into the local plandex server (idempotent).
plandex models custom -f /workspace/custom-models.json --save >/dev/null 2>&1 \
    && echo "plandex: imported custom model pack 'lab' (${MODEL_NAME})" \
    || echo "plandex: WARNING custom model import failed (check server)"

tmux new-session -d -s main -c /workspace
# Pre-fill the prompt so the user just hits Enter to start with the lab pack.
tmux send-keys -t main "plandex" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
