#!/bin/sh
set -e

# Goose ignores env vars alone — it requires GOOSE_PROVIDER to be set in
# ~/.config/goose/config.yaml, otherwise `goose run` errors with "No provider
# configured. Run 'goose configure' first."  The API key + host still come
# from process env (set below + via compose env_file).
mkdir -p /root/.config/goose
cat > /root/.config/goose/config.yaml <<EOF
GOOSE_PROVIDER: openai
GOOSE_MODEL: ${MODEL_NAME}
OPENAI_HOST: ${PROVIDER_ANTHROPIC_URL}
OPENAI_BASE_URL: ${PROVIDER_BASE_URL}
extensions:
  developer:
    enabled: true
EOF

export GOOSE_PROVIDER="openai"
export OPENAI_HOST="${PROVIDER_ANTHROPIC_URL}"
export OPENAI_BASE_URL="${PROVIDER_BASE_URL}"
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"
export GOOSE_MODEL="${MODEL_NAME}"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "goose session" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
