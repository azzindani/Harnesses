#!/bin/sh
set -e

# All ANTHROPIC_* env vars come from docker-compose's x-anthropic-env anchor:
#   - ANTHROPIC_BASE_URL points at the harnesses-auth proxy (strips thinking
#     blocks before they confuse Claude Code's content accumulator)
#   - ANTHROPIC_AUTH_TOKEN (not _API_KEY!) bypasses the OAuth login flow
#   - ANTHROPIC_DEFAULT_* aliases route every model tier to the one model NIM
#     actually serves; missing any alias triggers 404s mid-session.
# Re-exporting them here would *override* the proxy URL with the direct
# provider URL and re-add API_KEY, both of which break the harness.

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "claude" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
