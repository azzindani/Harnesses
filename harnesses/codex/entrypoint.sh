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

# The 6 self-hosted MCP_* tool servers. Single-endpoint repos register
# directly; ml/data/office mount several sub-servers with no unified
# endpoint, so each is registered individually as "<repo>-<sub-server>".
if [ -n "$MATH_MCP_URL" ] && [ -n "$MATH_MCP_TOKEN" ]; then
    { printf '\n[mcp_servers.math]\n'; printf 'url = "%s"\n' "$MATH_MCP_URL"; printf 'bearer_token_env_var = "MATH_MCP_TOKEN"\n'; } >> "$CONFIG_FILE"
fi
if [ -n "$BROWSER_MCP_URL" ] && [ -n "$BROWSER_MCP_TOKEN" ]; then
    { printf '\n[mcp_servers.browser]\n'; printf 'url = "%s"\n' "$BROWSER_MCP_URL"; printf 'bearer_token_env_var = "BROWSER_MCP_TOKEN"\n'; } >> "$CONFIG_FILE"
fi
if [ -n "$FS_MCP_URL" ] && [ -n "$FS_MCP_TOKEN" ]; then
    { printf '\n[mcp_servers.filesystem]\n'; printf 'url = "%s"\n' "$FS_MCP_URL"; printf 'bearer_token_env_var = "FS_MCP_TOKEN"\n'; } >> "$CONFIG_FILE"
fi
if [ -n "$ML_MCP_BASE_URL" ] && [ -n "$ML_MCP_TOKEN" ]; then
    for t in basic medium advanced; do
        { printf '\n[mcp_servers.ml-%s]\n' "$t"; printf 'url = "%s/%s/mcp"\n' "$ML_MCP_BASE_URL" "$t"; printf 'bearer_token_env_var = "ML_MCP_TOKEN"\n'; } >> "$CONFIG_FILE"
    done
fi
if [ -n "$DATA_MCP_BASE_URL" ] && [ -n "$DATA_MCP_TOKEN" ]; then
    for s in basic medium statistics transform visual workspace ingest; do
        { printf '\n[mcp_servers.data-%s]\n' "$s"; printf 'url = "%s/%s/mcp"\n' "$DATA_MCP_BASE_URL" "$s"; printf 'bearer_token_env_var = "DATA_MCP_TOKEN"\n'; } >> "$CONFIG_FILE"
    done
fi
if [ -n "$OFFICE_MCP_BASE_URL" ] && [ -n "$OFFICE_MCP_TOKEN" ]; then
    for s in docx-basic docx-tables docx-layout docx-new xlsx-basic xlsx-formulas xlsx-charts xlsx-new pptx-basic pptx-design pptx-new; do
        { printf '\n[mcp_servers.office-%s]\n' "$s"; printf 'url = "%s/%s/mcp"\n' "$OFFICE_MCP_BASE_URL" "$s"; printf 'bearer_token_env_var = "OFFICE_MCP_TOKEN"\n'; } >> "$CONFIG_FILE"
    done
fi

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "codex --model ${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
