#!/bin/sh
set -e

# Crush has a built-in `openai` provider that activates whenever OPENAI_API_KEY
# is set in the environment.  Our compose anchors set OPENAI_API_KEY (so other
# harnesses work), but crush then sends our OpenRouter key to api.openai.com
# instead of honouring crush.json's `lab` provider.  Strip the OPENAI_* env
# vars in this container only — the `lab` provider in crush.json carries
# everything crush actually needs.
unset OPENAI_API_KEY OPENAI_API_BASE OPENAI_BASE_URL OPENAI_HOST

mkdir -p /workspace

# Build /workspace/crush.json (the config crush loads from its cwd /workspace).
# We render the provider block plus an "mcp" object whose entries are added
# only when the relevant env vars are present. The MCP schema for the installed
# crush (v0.73.0, $schema https://charm.land/crush.json) is:
#   "mcp": { "<name>": { "type": "http"|"sse"|"stdio", "url": "...",
#                        "headers": { "Authorization": "Bearer ..." } } }
# Any pre-existing crush.json is merged (we only overwrite the keys we manage:
# $schema, providers, model, and the folio/web entries inside mcp).
CRUSH_CONFIG=/workspace/crush.json python3 <<'PY'
import json, os

path = os.environ["CRUSH_CONFIG"]

# Preserve anything already in the file (merge, don't clobber unrelated keys).
try:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        cfg = {}
except (FileNotFoundError, ValueError):
    cfg = {}

cfg["$schema"] = "https://charm.land/crush.json"

model_name = os.environ.get("MODEL_NAME", "")
cfg["providers"] = {
    "lab": {
        "type": "openai-compat",
        "base_url": os.environ.get("PROVIDER_BASE_URL", ""),
        "api_key": os.environ.get("PROVIDER_API_KEY") or "not-used",
        "models": [{"id": model_name, "name": model_name}],
    }
}
cfg["model"] = "lab/%s" % model_name

# Merge MCP servers without dropping any user-defined ones.
mcp = cfg.get("mcp")
if not isinstance(mcp, dict):
    mcp = {}

# folio: remote streamable HTTP MCP, bearer auth. Only if BOTH vars are set.
folio_url = os.environ.get("FOLIO_MCP_URL", "").strip()
folio_token = os.environ.get("FOLIO_MCP_TOKEN", "").strip()
if folio_url and folio_token:
    mcp["folio"] = {
        "type": "http",
        "url": folio_url,
        "headers": {"Authorization": "Bearer %s" % folio_token},
    }
else:
    mcp.pop("folio", None)

# web: remote streamable HTTP MCP, no auth. Only if URL is set.
web_url = os.environ.get("WEB_MCP_URL", "").strip()
if web_url:
    mcp["web"] = {
        "type": "http",
        "url": web_url,
    }
else:
    mcp.pop("web", None)

if mcp:
    cfg["mcp"] = mcp
elif "mcp" in cfg:
    del cfg["mcp"]

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

# Store crush's session DB in a dedicated volume (/root/.crush-data) instead of
# /workspace/.crush, so conversations survive recreates AND workspace cleanups.
mkdir -p /root/.crush-data

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "crush --data-dir /root/.crush-data" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
