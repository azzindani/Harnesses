#!/bin/sh
set -e

# Droid uses the Anthropic-compatible surface, configured via
# ~/.factory/config.json (the CLI accepts a `provider: anthropic` block with a
# custom base_url).
mkdir -p /root/.factory
cat > /root/.factory/config.json <<EOF
{
  "providers": [
    {
      "name": "lab",
      "provider": "anthropic",
      "base_url": "${PROVIDER_ANTHROPIC_URL}",
      "api_key": "${PROVIDER_API_KEY:-not-used}",
      "model": "${MODEL_NAME}"
    }
  ],
  "active_provider": "lab"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "droid" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
