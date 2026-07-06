#!/bin/sh
set -e

mkdir -p /root/.pi/agent
cat > /root/.pi/agent/models.json <<EOF
{
  "providers": {
    "lab": {
      "base_url": "${OPENAI_BASE_URL:-${PROVIDER_BASE_URL}}",
      "api_key": "${PROVIDER_API_KEY:-not-used}",
      "models": ["${MODEL_NAME}"]
    }
  },
  "default": "lab/${MODEL_NAME}"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "pi" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
