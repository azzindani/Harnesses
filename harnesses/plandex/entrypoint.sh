#!/bin/sh
set -e

# Plandex bring-your-own-provider via custom-models.json.  Drop it into the
# CWD and `plandex models` picks it up on first invocation.
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
# PROVIDER_API_KEY already exported via compose env_file; re-export with a
# fallback so the JSON's apiKeyEnvVar resolves cleanly even on a fresh .env.
export PROVIDER_API_KEY="${PROVIDER_API_KEY:-not-used}"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "plandex" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
