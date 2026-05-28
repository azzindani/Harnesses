#!/bin/sh
set -e

# Aider uses OpenAI-compatible env vars.  Model id is prefixed with `openai/`
# so Aider routes via its OpenAI provider rather than guessing from MODEL_NAME.
export OPENAI_API_BASE="${PROVIDER_BASE_URL}"
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "aider --model openai/${MODEL_NAME} --no-auto-commits" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
