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

# 3. The 6 self-hosted MCP_* tool servers. Single-endpoint repos register
# directly; ml/data/office mount several sub-servers with no unified
# endpoint, so each is registered individually as "<repo>-<sub-server>".
_gptme_mcp() {  # name url token
  cat >> /root/.config/gptme/config.toml <<EOF

[[mcp.servers]]
name = "$1"
enabled = true
url = "$2"
headers = { Authorization = "Bearer $3" }
EOF
}

[ -n "${MATH_MCP_URL}" ] && [ -n "${MATH_MCP_TOKEN}" ] && _gptme_mcp math "${MATH_MCP_URL}" "${MATH_MCP_TOKEN}"
[ -n "${BROWSER_MCP_URL}" ] && [ -n "${BROWSER_MCP_TOKEN}" ] && _gptme_mcp browser "${BROWSER_MCP_URL}" "${BROWSER_MCP_TOKEN}"
[ -n "${FS_MCP_URL}" ] && [ -n "${FS_MCP_TOKEN}" ] && _gptme_mcp filesystem "${FS_MCP_URL}" "${FS_MCP_TOKEN}"

if [ -n "${ML_MCP_BASE_URL}" ] && [ -n "${ML_MCP_TOKEN}" ]; then
  for t in basic medium advanced; do
    _gptme_mcp "ml-$t" "${ML_MCP_BASE_URL}/$t/mcp" "${ML_MCP_TOKEN}"
  done
fi
if [ -n "${DATA_MCP_BASE_URL}" ] && [ -n "${DATA_MCP_TOKEN}" ]; then
  for s in basic medium statistics transform visual workspace ingest; do
    _gptme_mcp "data-$s" "${DATA_MCP_BASE_URL}/$s/mcp" "${DATA_MCP_TOKEN}"
  done
fi
if [ -n "${OFFICE_MCP_BASE_URL}" ] && [ -n "${OFFICE_MCP_TOKEN}" ]; then
  for s in docx-basic docx-tables docx-layout docx-new xlsx-basic xlsx-formulas xlsx-charts xlsx-new pptx-basic pptx-design pptx-new; do
    _gptme_mcp "office-$s" "${OFFICE_MCP_BASE_URL}/$s/mcp" "${OFFICE_MCP_TOKEN}"
  done
fi
if [ -n "${DOCS_MCP_BASE_URL}" ] && [ -n "${DOCS_MCP_TOKEN}" ]; then
  for s in read edit; do
    _gptme_mcp "docs-$s" "${DOCS_MCP_BASE_URL}/$s/mcp" "${DOCS_MCP_TOKEN}"
  done
fi

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "gptme --model lab/${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
