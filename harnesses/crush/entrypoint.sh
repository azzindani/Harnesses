#!/bin/sh
set -e

mkdir -p /workspace
cat > /workspace/crush.json <<EOF
{
  "\$schema": "https://charm.land/crush.json",
  "providers": {
    "lab": {
      "type": "openai-compat",
      "base_url": "${PROVIDER_BASE_URL}",
      "api_key": "${PROVIDER_API_KEY:-not-used}",
      "models": [
        { "id": "${MODEL_NAME}", "name": "${MODEL_NAME}" }
      ]
    }
  },
  "model": "lab/${MODEL_NAME}"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "crush" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
