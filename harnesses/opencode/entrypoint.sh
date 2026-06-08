#!/bin/sh
set -e

mkdir -p /root/.config/opencode

# Write opencode config (provider + optional MCP servers).
# Idempotent: fully overwritten on every boot.
# MCP env vars (from compose env_file: .env):
#   FOLIO_MCP_URL / FOLIO_MCP_TOKEN -> "folio" (auth header, only if BOTH set)
#   WEB_MCP_URL                     -> "web"   (no auth, only if set)
python3 - <<'PY'
import json, os

config = {
    "$schema": "https://opencode.ai/config.json",
    "provider": {
        "lab": {
            "npm": "@ai-sdk/openai-compatible",
            "options": {
                "baseURL": os.environ.get("PROVIDER_BASE_URL", ""),
                "apiKey": os.environ.get("PROVIDER_API_KEY") or "not-used",
            },
            "models": {
                os.environ.get("MODEL_NAME", ""): {},
            },
        },
    },
    "model": "lab/" + os.environ.get("MODEL_NAME", ""),
}

mcp = {}

folio_url = os.environ.get("FOLIO_MCP_URL", "").strip()
folio_token = os.environ.get("FOLIO_MCP_TOKEN", "").strip()
if folio_url and folio_token:
    mcp["folio"] = {
        "type": "remote",
        "url": folio_url,
        "enabled": True,
        "headers": {
            "Authorization": "Bearer " + folio_token,
        },
    }

web_url = os.environ.get("WEB_MCP_URL", "").strip()
if web_url:
    mcp["web"] = {
        "type": "remote",
        "url": web_url,
        "enabled": True,
    }

if mcp:
    config["mcp"] = mcp

with open("/root/.config/opencode/config.json", "w") as f:
    json.dump(config, f, indent=2)
PY

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "opencode" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
