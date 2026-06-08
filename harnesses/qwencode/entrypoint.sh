#!/bin/sh
set -e

# Qwen Code v0.15 settings schema:
#   - `model.name` is the active model id (NOT a top-level `model` string)
#   - `modelProviders.openai` is an array; each entry needs `id` + `envKey`
#   - `selectedAuthType` picks which provider group is active
# Without `model.name` qwen falls back to its built-in qwen3.5-plus default
# and the OpenAI base_url is ignored.
mkdir -p /root/.qwen
python3 - <<PY
import json, os
cfg = {
  "selectedAuthType": "openai",
  "model": {"name": os.environ["MODEL_NAME"]},
  "modelProviders": {
    "openai": [
      {
        "id": os.environ["MODEL_NAME"],
        "envKey": "OPENAI_API_KEY",
        "baseUrl": os.environ["PROVIDER_BASE_URL"],
      }
    ]
  }
}
with open("/root/.qwen/settings.json", "w") as f:
    json.dump(cfg, f, indent=2)
PY

# qwen reads OPENAI_API_KEY by name (we configured envKey above).  Make sure
# it's set even on fresh .env files.
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"

# Register remote MCP servers in qwen's native config (~/.qwen/settings.json).
# `qwen mcp add -t http` writes "httpUrl" (streamable HTTP) and merges into the
# existing settings.json without clobbering model/provider keys.  Re-running on
# an existing name updates it in place, so this is idempotent across boots.
#   - folio: HTTP MCP with Authorization header (only if URL AND token set)
#   - web:   HTTP MCP, no auth header        (only if URL set)
if [ -n "${FOLIO_MCP_URL}" ] && [ -n "${FOLIO_MCP_TOKEN}" ]; then
  qwen mcp add folio "${FOLIO_MCP_URL}" -t http \
    -H "Authorization: Bearer ${FOLIO_MCP_TOKEN}" >/dev/null 2>&1 || true
fi
if [ -n "${WEB_MCP_URL}" ]; then
  qwen mcp add web "${WEB_MCP_URL}" -t http >/dev/null 2>&1 || true
fi

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "qwen -m ${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
