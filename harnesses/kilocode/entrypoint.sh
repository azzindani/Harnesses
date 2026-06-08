#!/usr/bin/with-contenv bash
# shellcheck shell=bash
set -e

# code-server's binary is not on the s6 init PATH (it lives under /app); add it
# so --install-extension actually runs instead of silently failing.
export PATH="/app/code-server/bin:$PATH"

# Install Kilo Code extension if not already present.
EXT_DIR="/config/extensions"
mkdir -p "$EXT_DIR"
if ! ls "$EXT_DIR" 2>/dev/null | grep -qi kilocode; then
    s6-setuidgid abc code-server --install-extension kilocode.kilo-code || true
fi

# Seed the extension's provider config.
SETTINGS_DIR="/config/data/User"
mkdir -p "$SETTINGS_DIR"
cat > "$SETTINGS_DIR/settings.json" <<EOF
{
  "kilo-code.providers": [
    {
      "id": "lab",
      "type": "openai-compatible",
      "baseUrl": "${PROVIDER_BASE_URL}",
      "apiKey": "${PROVIDER_API_KEY:-not-used}",
      "model": "${MODEL_NAME}"
    }
  ],
  "kilo-code.activeProvider": "lab"
}
EOF

# ── Register external MCP servers (Folio + web search) ────────────────────────
# Kilo Code (publisher.name = kilocode.kilo-code) reads remote MCP servers from
#   <user-data-dir>/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json
# (user-data-dir is /config/data for code-server). Schema confirmed from the
# bundled extension's config mapper:
#   { "mcpServers": { "<name>": {
#       "type": "streamable-http", "url": "<url>",
#       "headers": { "Authorization": "Bearer ..." }, "disabled": false } } }
# A server is treated as remote when type is "streamable-http" (or "sse") and a
# non-empty "url" is present; "headers" carries auth. Containers are ephemeral,
# so this is (re)written from env at every boot. We merge into any existing file
# so servers added later via the UI are preserved.
GS_BASE="/config/data/User/globalStorage"
# Prefer the real extension globalStorage dir if it already exists; otherwise
# fall back to the canonical publisher.extensionId folder and create it.
KILO_GS="$(find "$GS_BASE" -maxdepth 1 -type d -iname '*kilo*code*' 2>/dev/null | head -n1)"
[ -n "$KILO_GS" ] || KILO_GS="$GS_BASE/kilocode.kilo-code"
MCP_DIR="$KILO_GS/settings"
MCP_FILE="$MCP_DIR/mcp_settings.json"
mkdir -p "$MCP_DIR"

# Start from the existing file (preserving any manually-added servers) or {}.
if [ -s "$MCP_FILE" ] && jq -e . "$MCP_FILE" >/dev/null 2>&1; then
    base_json="$(cat "$MCP_FILE")"
else
    base_json='{"mcpServers":{}}'
fi

mcp_json="$base_json"

# Folio — streamable-HTTP MCP with bearer auth (only if URL + token both set).
if [ -n "$FOLIO_MCP_URL" ] && [ -n "$FOLIO_MCP_TOKEN" ]; then
    mcp_json="$(printf '%s' "$mcp_json" | jq \
        --arg url "$FOLIO_MCP_URL" \
        --arg auth "Bearer $FOLIO_MCP_TOKEN" \
        '.mcpServers.folio = {type:"streamable-http", url:$url, headers:{Authorization:$auth}, disabled:false}')"
    echo "MCP(kilocode): registered 'folio' -> $FOLIO_MCP_URL"
fi

# Web search/fetch sidecar — streamable-HTTP, no auth (only if URL set).
if [ -n "$WEB_MCP_URL" ]; then
    mcp_json="$(printf '%s' "$mcp_json" | jq \
        --arg url "$WEB_MCP_URL" \
        '.mcpServers.web = {type:"streamable-http", url:$url, disabled:false}')"
    echo "MCP(kilocode): registered 'web' -> $WEB_MCP_URL"
fi

printf '%s\n' "$mcp_json" > "$MCP_FILE"

chown -R abc:abc /config
