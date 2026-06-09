#!/bin/sh
set -e

# Goose ignores env vars alone — it requires GOOSE_PROVIDER to be set in
# ~/.config/goose/config.yaml, otherwise `goose run` errors with "No provider
# configured. Run 'goose configure' first."  The API key + host still come
# from process env (set below + via compose env_file).
mkdir -p /root/.config/goose

# Build config.yaml. Goose (1.36.0) parses config.yaml with serde_yaml; since
# JSON is a strict subset of YAML 1.2 we emit JSON via python3 (PyYAML is NOT
# installed in this image, but json is stdlib). This keeps the base provider/
# model settings AND merges in MCP "extensions" idempotently on every boot.
#
# Remote streamable-HTTP extensions use type "streamable_http" — verified
# against the installed binary: goose's ExtensionConfig enum serde-tags this
# variant as `streamable_http` (configure UI label: "Remote Extension
# (Streamable HTTP)"). Other valid tags are stdio / sse / builtin / frontend.
GOOSE_CONFIG_PATH=/root/.config/goose/config.yaml \
MODEL_NAME="${MODEL_NAME}" \
PROVIDER_ANTHROPIC_URL="${PROVIDER_ANTHROPIC_URL}" \
PROVIDER_BASE_URL="${PROVIDER_BASE_URL}" \
FOLIO_MCP_URL="${FOLIO_MCP_URL}" \
FOLIO_MCP_TOKEN="${FOLIO_MCP_TOKEN}" \
WEB_MCP_URL="${WEB_MCP_URL}" \
python3 <<'PY'
import json, os

path = os.environ["GOOSE_CONFIG_PATH"]

# Start from existing config if present (preserve any keys goose itself wrote),
# else seed with the base provider/model settings this entrypoint owns.
cfg = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            cfg = json.load(f)  # our own previous JSON-as-YAML output
    except Exception:
        cfg = {}
if not isinstance(cfg, dict):
    cfg = {}

# Base settings (this entrypoint is the source of truth for these).
cfg["GOOSE_PROVIDER"] = "openai"
cfg["GOOSE_MODEL"] = os.environ.get("MODEL_NAME", "")
cfg["OPENAI_HOST"] = os.environ.get("PROVIDER_ANTHROPIC_URL", "")
cfg["OPENAI_BASE_URL"] = os.environ.get("PROVIDER_BASE_URL", "")

ext = cfg.get("extensions")
if not isinstance(ext, dict):
    ext = {}
# Keep the built-in developer extension enabled.
ext["developer"] = {"enabled": True}

def remote(name, uri, headers):
    return {
        "enabled": True,
        "type": "streamable_http",
        "name": name,
        "uri": uri,
        "headers": headers,
        "timeout": 300,
        "bundled": False,
    }

# folio: only if BOTH URL and token are non-empty.
folio_url = os.environ.get("FOLIO_MCP_URL", "").strip()
folio_token = os.environ.get("FOLIO_MCP_TOKEN", "").strip()
if folio_url and folio_token:
    ext["folio"] = remote("folio", folio_url,
                          {"Authorization": "Bearer " + folio_token})
else:
    ext.pop("folio", None)

# web: only if URL non-empty, no auth header.
web_url = os.environ.get("WEB_MCP_URL", "").strip()
if web_url:
    ext["web"] = remote("web", web_url, {})
else:
    ext.pop("web", None)

cfg["extensions"] = ext

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY

export GOOSE_PROVIDER="openai"
export OPENAI_HOST="${PROVIDER_ANTHROPIC_URL}"
export OPENAI_BASE_URL="${PROVIDER_BASE_URL}"
export OPENAI_API_KEY="${PROVIDER_API_KEY:-not-used}"
export GOOSE_MODEL="${MODEL_NAME}"

# Skip the interactive "Share anonymous usage data?" consent prompt that
# otherwise blocks the session on every boot (the config dir is not persisted,
# so it reappears each time). GOOSE_TELEMETRY_OFF overrides the unset config
# and disables telemetry without prompting.
export GOOSE_TELEMETRY_OFF=1

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "goose session" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
