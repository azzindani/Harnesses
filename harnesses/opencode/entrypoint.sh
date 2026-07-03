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
                "baseURL": os.environ.get("OPENAI_BASE_URL") or os.environ.get("PROVIDER_BASE_URL", ""),
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

# Light theme: "system" is opencode's adaptive theme (it's meant to pick a
# light/dark variant based on the detected terminal background instead of a
# fixed palette). NOTE: as of opencode 1.17.13 its TUI (opentui) paints its
# own background using fixed dark 256-color cells no matter which theme is
# selected here -- verified by testing "github", "flexoki", and "system"
# directly, all render dark. This is a known upstream regression from the
# opentui rewrite (see sst/opencode#3680), not something fixable from harness
# config alone. Set to the semantically-correct value so this self-heals for
# free once upstream fixes it -- the ttyd theme below is what actually
# lightens what's on screen today (prompt/shell chrome around the TUI).
cat > /root/.config/opencode/tui.json <<'EOF'
{
  "$schema": "https://opencode.ai/tui.json",
  "theme": "system"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "opencode" Enter

# Light xterm.js theme (true white "notepad" paper) -- see note above re:
# opencode's own TUI canvas not yet honoring this; kept for chrome
# consistency with the other harnesses and so a future opencode fix picks
# it up automatically. Yellow is darkened from pure #ffff00 since that's
# unreadable on a white background.
LIGHT_THEME='theme={"background":"#ffffff","foreground":"#24292e","cursor":"#24292e","cursorAccent":"#ffffff","selectionBackground":"#c8e1ff","black":"#24292e","red":"#d73a49","green":"#22863a","yellow":"#b08800","blue":"#005cc5","magenta":"#5a32a3","cyan":"#032f62","white":"#6a737d","brightBlack":"#6a737d","brightRed":"#cb2431","brightGreen":"#22863a","brightYellow":"#b08800","brightBlue":"#005cc5","brightMagenta":"#5a32a3","brightCyan":"#3192aa","brightWhite":"#ffffff"}'

exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' -t "$LIGHT_THEME" tmux attach-session -t main
