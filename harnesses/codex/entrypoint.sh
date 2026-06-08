#!/bin/sh
set -e

# ---------------------------------------------------------------------------
# Codex >= 0.84 removed the chat-completions wire API; it now speaks ONLY the
# OpenAI /responses API.  OpenRouter implements /responses, so codex is pointed
# straight at the provider's /v1 endpoint (PROVIDER_BASE_URL) rather than the
# auth-service proxy, which only translates /chat/completions and /anthropic.
# The API key is read from PROVIDER_API_KEY via `env_key`.
#
# Tradeoff: because codex bypasses the proxy, it does NOT get the proxy's
# free-model fallback/catalog that the other OpenAI-protocol harnesses enjoy.
# It uses exactly MODEL_NAME against OpenRouter.
# ---------------------------------------------------------------------------
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG_FILE="$CODEX_HOME/config.toml"
mkdir -p "$CODEX_HOME"

{
    printf 'model = "%s"\n' "$MODEL_NAME"
    printf 'model_provider = "lab"\n'
    printf '\n[model_providers.lab]\n'
    printf 'name = "lab"\n'
    printf 'base_url = "%s"\n' "${PROVIDER_BASE_URL:-https://openrouter.ai/api/v1}"
    printf 'wire_api = "responses"\n'
    printf 'env_key = "PROVIDER_API_KEY"\n'
    # Pre-trust /workspace so codex doesn't prompt on first run.
    printf '\n[projects."/workspace"]\n'
    printf 'trust_level = "trusted"\n'
} > "$CONFIG_FILE"

# MCP servers.  web (DuckDuckGo) connects fine.  folio's streamable-HTTP
# handshake currently fails with codex's rmcp client (non-fatal — codex logs a
# warning and continues); it's kept for consistency and forward-compat.
if [ -n "$FOLIO_MCP_URL" ] && [ -n "$FOLIO_MCP_TOKEN" ]; then
    {
        printf '\n[mcp_servers.folio]\n'
        printf 'url = "%s"\n' "$FOLIO_MCP_URL"
        printf 'bearer_token_env_var = "FOLIO_MCP_TOKEN"\n'
    } >> "$CONFIG_FILE"
fi
if [ -n "$WEB_MCP_URL" ]; then
    {
        printf '\n[mcp_servers.web]\n'
        printf 'url = "%s"\n' "$WEB_MCP_URL"
    } >> "$CONFIG_FILE"
fi

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "codex --model ${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
