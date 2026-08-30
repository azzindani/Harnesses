#!/bin/sh
set -e

# Droid (Factory CLI) loads BYOK custom models from ~/.factory/settings.json.
# Schema is camelCase (droid >= 0.14x): each customModels entry needs
# `model`, `baseUrl`, `apiKey`, `provider` — an entry using the legacy
# snake_case keys (base_url/api_key) is treated as invalid and silently
# dropped when droid normalises the file at startup, leaving the harness with
# no usable model.  We register a `generic-chat-completion-api` model pointed
# at the auth service's OpenAI-compat proxy (free catalog + free fallback),
# which is the same path the OpenAI-protocol harnesses use.
#
# The proxy's OpenAI base is the Anthropic base with /anthropic -> /v1, so the
# endpoint stays driven by compose's ANTHROPIC_BASE_URL (single source of truth).
# `model` is BOTH the upstream model id AND the value `-m` / the /model picker
# reference, so it must be the real MODEL_NAME.
PROXY_OPENAI="${ANTHROPIC_BASE_URL%/anthropic}/v1"

mkdir -p /root/.factory
PROXY_OPENAI="$PROXY_OPENAI" python3 - <<'PY'
import json, os
cfg = {
  # Pre-seed the keys droid writes itself, so its startup normalisation finds
  # the file already canonical and leaves customModels untouched.
  "enabledPlugins": {"core@factory-plugins": True},
  "logoAnimation": "off",
  "customModels": [
    {
      "model": os.environ["MODEL_NAME"],
      "displayName": "Lab via OpenRouter",
      "baseUrl": os.environ["PROXY_OPENAI"],
      "apiKey": os.environ.get("PROVIDER_API_KEY", "not-used"),
      "provider": "generic-chat-completion-api",
      "maxOutputTokens": 16384,
    }
  ],
}
with open("/root/.factory/settings.json", "w") as f:
    json.dump(cfg, f, indent=2)
print("droid: registered custom model", cfg["customModels"][0]["model"],
      "->", cfg["customModels"][0]["baseUrl"])
PY

# Register remote HTTP/streamable MCP servers in droid's native format.
# droid 0.142 stores these in a SEPARATE file (~/.factory/mcp.json) under an
# `mcpServers` block — independent of settings.json/customModels — so writing
# the whole file is safe and does not touch the custom-model config.
# We rewrite it from scratch each boot (idempotent) and include only the
# servers whose env vars are present. `droid mcp add` is intentionally NOT used:
# it errors ("already exists") on re-runs and offers no upsert flag, whereas the
# on-disk format is simple, stable, and exactly what `add` itself produces.
python3 - <<'PY'
import json, os
servers = {}

folio_url = os.environ.get("FOLIO_MCP_URL", "").strip()
folio_token = os.environ.get("FOLIO_MCP_TOKEN", "").strip()
if folio_url and folio_token:
    servers["folio"] = {
        "type": "http",
        "url": folio_url,
        "headers": {"Authorization": "Bearer " + folio_token},
        "disabled": False,
    }

web_url = os.environ.get("WEB_MCP_URL", "").strip()
if web_url:
    servers["web"] = {
        "type": "http",
        "url": web_url,
        "disabled": False,
    }

# The 6 self-hosted MCP_* tool servers. Single-endpoint repos register
# directly; ml/data/office mount several sub-servers with no unified
# endpoint, so each is registered individually as "<repo>-<sub-server>".
_single = [
    ("math", "MATH_MCP_URL", "MATH_MCP_TOKEN"),
    ("browser", "BROWSER_MCP_URL", "BROWSER_MCP_TOKEN"),
    ("filesystem", "FS_MCP_URL", "FS_MCP_TOKEN"),
]
for name, url_var, token_var in _single:
    url = os.environ.get(url_var, "").strip()
    token = os.environ.get(token_var, "").strip()
    if url and token:
        servers[name] = {"type": "http", "url": url,
                          "headers": {"Authorization": "Bearer " + token}, "disabled": False}

_multi = [
    ("ml", "ML_MCP_BASE_URL", "ML_MCP_TOKEN", ["basic", "medium", "advanced"]),
    ("data", "DATA_MCP_BASE_URL", "DATA_MCP_TOKEN",
     ["basic", "medium", "statistics", "transform", "visual", "workspace", "ingest"]),
    ("office", "OFFICE_MCP_BASE_URL", "OFFICE_MCP_TOKEN",
     ["docx-basic", "docx-tables", "docx-layout", "docx-new",
      "xlsx-basic", "xlsx-formulas", "xlsx-charts", "xlsx-new",
      "pptx-basic", "pptx-design", "pptx-new"]),
    ("docs", "DOCS_MCP_BASE_URL", "DOCS_MCP_TOKEN", ["read", "edit"]),
]
for prefix, base_var, token_var, subs in _multi:
    base = os.environ.get(base_var, "").strip()
    token = os.environ.get(token_var, "").strip()
    if base and token:
        for sub in subs:
            servers[prefix + "-" + sub] = {"type": "http", "url": base + "/" + sub + "/mcp",
                                            "headers": {"Authorization": "Bearer " + token}, "disabled": False}

path = "/root/.factory/mcp.json"
with open(path, "w") as f:
    json.dump({"mcpServers": servers}, f, indent=2)
print("droid: registered MCP servers:", ", ".join(servers) or "(none)")
PY

tmux new-session -d -s main -c /workspace
# `-m "$MODEL_NAME"` selects our custom model entry (its `model` field IS the id).
tmux send-keys -t main "droid -m \"$MODEL_NAME\"" Enter

# droid rewrites settings.json once on startup; if its normalisation ever drops
# the customModels entry, re-assert it so the session lands on a usable model.
# (No-op when droid preserves the file, which it does for a valid entry.)
(
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 1
    if ! grep -q '"customModels"' /root/.factory/settings.json 2>/dev/null; then
      PROXY_OPENAI="$PROXY_OPENAI" python3 - <<'PY' 2>/dev/null || true
import json, os
p = "/root/.factory/settings.json"
try:
    cfg = json.load(open(p))
except Exception:
    cfg = {"enabledPlugins": {"core@factory-plugins": True}, "logoAnimation": "off"}
cfg["customModels"] = [{
    "model": os.environ["MODEL_NAME"],
    "displayName": "Lab via OpenRouter",
    "baseUrl": os.environ["PROXY_OPENAI"],
    "apiKey": os.environ.get("PROVIDER_API_KEY", "not-used"),
    "provider": "generic-chat-completion-api",
    "maxOutputTokens": 16384,
}]
json.dump(cfg, open(p, "w"), indent=2)
PY
    fi
    i=$((i + 1))
  done
) &

exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
