#!/bin/sh
set -e

mkdir -p /root/.qwen-code
cat > /root/.qwen-code/settings.json <<EOF
{
  "modelProviders": {
    "lab": {
      "type": "openai",
      "baseURL": "${PROVIDER_BASE_URL}",
      "apiKey": "${PROVIDER_API_KEY:-not-used}",
      "models": ["${MODEL_NAME}"]
    }
  },
  "defaultModel": "lab/${MODEL_NAME}"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "qwen-code" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
