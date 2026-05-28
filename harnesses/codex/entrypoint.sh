#!/bin/sh
set -e

export OPENAI_BASE_URL="${PROVIDER_BASE_URL}"
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"
export CODEX_MODEL="${MODEL_NAME}"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "codex --model ${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
