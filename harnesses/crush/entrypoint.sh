#!/bin/sh
set -e

# Crush has a built-in `openai` provider that activates whenever OPENAI_API_KEY
# is set in the environment.  Our compose anchors set OPENAI_API_KEY (so other
# harnesses work), but crush then sends our OpenRouter key to api.openai.com
# instead of honouring crush.json's `lab` provider.  Strip the OPENAI_* env
# vars in this container only — the `lab` provider in crush.json carries
# everything crush actually needs.
unset OPENAI_API_KEY OPENAI_API_BASE OPENAI_BASE_URL OPENAI_HOST

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
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
