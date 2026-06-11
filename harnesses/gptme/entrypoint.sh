#!/bin/sh
set -e

mkdir -p /root/.config/gptme
cat > /root/.config/gptme/config.toml <<EOF
[prompt]
about_user = "Lab user running gptme"

[env]
PROVIDER_API_KEY = "${PROVIDER_API_KEY:-not-used}"

[[providers]]
name = "lab"
base_url = "${OPENAI_BASE_URL:-${PROVIDER_BASE_URL}}"
api_key_env = "PROVIDER_API_KEY"
default_model = "${MODEL_NAME}"
EOF

# ---------------------------------------------------------------------------
# MCP servers (gptme native [mcp] section).
#
# Installed gptme (v0.31.0) supports native HTTP MCP transport with headers:
#   gptme/config.py  -> MCPServerConfig(name, enabled, command, args, env, url, headers)
#                       is_http == url starts with http://|https://
#   gptme/mcp/client.py -> is_http routes to streamablehttp_client(url, headers=headers)
# So we register both servers by URL; folio carries a Bearer auth header.
# No stdio/npx bridge is required.
#
# Each server is appended only when its required env vars are non-empty.
# We always write the [mcp] header (enabled/auto_start) so the section is valid
# whether or not any server is present; gptme only connects on demand.
# ---------------------------------------------------------------------------
cat >> /root/.config/gptme/config.toml <<EOF

[mcp]
enabled = true
auto_start = true
EOF

# 1. folio — HTTP MCP with Authorization: Bearer <token>. Both vars required.
if [ -n "${FOLIO_MCP_URL}" ] && [ -n "${FOLIO_MCP_TOKEN}" ]; then
  cat >> /root/.config/gptme/config.toml <<EOF

[[mcp.servers]]
name = "folio"
enabled = true
url = "${FOLIO_MCP_URL}"
headers = { Authorization = "Bearer ${FOLIO_MCP_TOKEN}" }
EOF
fi

# 2. web — HTTP MCP, no auth header. URL required.
if [ -n "${WEB_MCP_URL}" ]; then
  cat >> /root/.config/gptme/config.toml <<EOF

[[mcp.servers]]
name = "web"
enabled = true
url = "${WEB_MCP_URL}"
EOF
fi

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "gptme --model lab/${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
