#!/bin/sh
set -e

# Goose reads OPENAI_HOST as the host part (no /v1) and appends its own path.
# Some Goose versions prefer OPENAI_BASE_URL (full URL with /v1) instead; we
# set both so either convention works.
export GOOSE_PROVIDER="openai"
export OPENAI_HOST="${PROVIDER_ANTHROPIC_URL}"
export OPENAI_BASE_URL="${PROVIDER_BASE_URL}"
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"
export GOOSE_MODEL="${MODEL_NAME}"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "goose session" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
