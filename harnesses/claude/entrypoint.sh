#!/bin/sh
set -e

# Anthropic-compatible provider.  All *_MODEL aliases must point at the model
# the provider serves — leaving even one unset triggers 404s mid-session.
export ANTHROPIC_BASE_URL="${PROVIDER_ANTHROPIC_URL}"
export ANTHROPIC_API_KEY="${PROVIDER_API_KEY:-not-used}"
export ANTHROPIC_CUSTOM_MODEL_OPTION="${MODEL_NAME}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${MODEL_NAME}"
export ANTHROPIC_DEFAULT_SONNET_MODEL="${MODEL_NAME}"
export ANTHROPIC_DEFAULT_OPUS_MODEL="${MODEL_NAME}"
export CLAUDE_CODE_SUBAGENT_MODEL="${MODEL_NAME}"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "claude" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
