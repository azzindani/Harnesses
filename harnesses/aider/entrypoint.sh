#!/bin/sh
set -e

# Aider uses OpenAI-compatible env vars.  Model id is prefixed with `openai/`
# so Aider routes via its OpenAI provider rather than guessing from MODEL_NAME.
export OPENAI_API_BASE="${PROVIDER_BASE_URL}"
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"

# Persist chat/input/llm history in a dedicated volume (/root/.aider) instead of
# the shared /workspace, so it survives recreates AND workspace cleanups. By
# default aider writes .aider.*.history into the cwd (/workspace).
mkdir -p /root/.aider
AIDER_HIST="--chat-history-file /root/.aider/chat.history.md \
--input-history-file /root/.aider/input.history \
--llm-history-file /root/.aider/llm.history"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "aider --model openai/${MODEL_NAME} --no-auto-commits $AIDER_HIST" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
