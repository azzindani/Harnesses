#!/bin/sh
set -e

mkdir -p /root/.config/opencode
cat > /root/.config/opencode/config.json <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "lab": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "${PROVIDER_BASE_URL}",
        "apiKey": "${PROVIDER_API_KEY:-not-used}"
      },
      "models": {
        "${MODEL_NAME}": {}
      }
    }
  },
  "model": "lab/${MODEL_NAME}"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "opencode" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
