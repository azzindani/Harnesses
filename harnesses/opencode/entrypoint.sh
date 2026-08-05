#!/bin/sh
set -e

mkdir -p /root/.config/opencode

# Write opencode config (provider + optional MCP servers).
# Idempotent: fully overwritten on every boot.
# MCP env vars (from compose env_file: .env):
#   FOLIO_MCP_URL / FOLIO_MCP_TOKEN -> "folio" (auth header, only if BOTH set)
#   WEB_MCP_URL                     -> "web"   (no auth, only if set)
#   MATH/BROWSER/FS_MCP_URL+TOKEN   -> "math"/"browser"/"filesystem"
#   ML/DATA/OFFICE_MCP_BASE_URL+TOKEN -> "<repo>-<sub-server>" per sub-server
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

# The 6 self-hosted MCP_* tool servers. Single-endpoint repos register
# directly; ml/data/office mount several sub-servers with no unified
# endpoint, so each is registered individually as "<repo>-<sub-server>".
def _remote(url, token=None):
    entry = {"type": "remote", "url": url, "enabled": True}
    if token:
        entry["headers"] = {"Authorization": "Bearer " + token}
    return entry

_single = [
    ("math", "MATH_MCP_URL", "MATH_MCP_TOKEN"),
    ("browser", "BROWSER_MCP_URL", "BROWSER_MCP_TOKEN"),
    ("filesystem", "FS_MCP_URL", "FS_MCP_TOKEN"),
]
for name, url_var, token_var in _single:
    url = os.environ.get(url_var, "").strip()
    token = os.environ.get(token_var, "").strip()
    if url and token:
        mcp[name] = _remote(url, token)

_multi = [
    ("ml", "ML_MCP_BASE_URL", "ML_MCP_TOKEN", ["basic", "medium", "advanced"]),
    ("data", "DATA_MCP_BASE_URL", "DATA_MCP_TOKEN",
     ["basic", "medium", "statistics", "transform", "visual", "workspace", "ingest"]),
    ("office", "OFFICE_MCP_BASE_URL", "OFFICE_MCP_TOKEN",
     ["docx-basic", "docx-tables", "docx-layout", "docx-new",
      "xlsx-basic", "xlsx-formulas", "xlsx-charts", "xlsx-new",
      "pptx-basic", "pptx-design", "pptx-new"]),
]
for prefix, base_var, token_var, subs in _multi:
    base = os.environ.get(base_var, "").strip()
    token = os.environ.get(token_var, "").strip()
    if base and token:
        for sub in subs:
            mcp[prefix + "-" + sub] = _remote(base + "/" + sub + "/mcp", token)

if mcp:
    config["mcp"] = mcp

with open("/root/.config/opencode/config.json", "w") as f:
    json.dump(config, f, indent=2)
PY

# Light theme. Built-in themes (including the adaptive "system" theme) define
# colors as {"dark": "...", "light": "..."} pairs and pick a variant based on
# detected terminal background -- that detection doesn't work in this ttyd/
# tmux setup, so every built-in theme rendered dark regardless of name
# (verified by testing "github", "flexoki", and "system" directly). A custom
# theme where every color is a plain hex string bypasses that detection
# entirely (per opencode's theme docs, a plain string is used as-is, no
# dark/light selection), so it forces a real light theme instead of hoping
# detection works. Palette matches the ttyd terminal theme below.
# Color keys must live under a "theme" object (verified against opencode's
# own built-in themes, e.g. packages/tui/src/theme/assets/github.json in the
# opencode repo) -- a flat top-level object is silently ignored (fails schema
# validation with no error, falls back to the default dark theme), which is
# why an earlier version of this file didn't actually work.
mkdir -p /root/.config/opencode/themes
cat > /root/.config/opencode/themes/notepad.json <<'EOF'
{
  "$schema": "https://opencode.ai/theme.json",
  "theme": {
    "primary": "#0969da",
    "secondary": "#8250df",
    "accent": "#bc4c00",
    "text": "#24292e",
    "textMuted": "#6a737d",
    "background": "#ffffff",
    "backgroundPanel": "#f6f8fa",
    "backgroundElement": "#eaeef2",
    "border": "#d0d7de",
    "borderActive": "#0969da",
    "borderSubtle": "#eaeef2",
    "error": "#cf222e",
    "warning": "#9a6700",
    "success": "#1a7f37",
    "info": "#0969da",
    "diffAdded": "#1a7f37",
    "diffRemoved": "#cf222e",
    "diffContext": "#6e7781",
    "diffHunkHeader": "#8250df",
    "diffHighlightAdded": "#2da44e",
    "diffHighlightRemoved": "#ff8182",
    "diffAddedBg": "#ccffd8",
    "diffRemovedBg": "#ffebe9",
    "diffContextBg": "#ffffff",
    "diffLineNumber": "#8c959f",
    "diffAddedLineNumberBg": "#b4f1c0",
    "diffRemovedLineNumberBg": "#ffd6d3",
    "markdownText": "#24292e",
    "markdownHeading": "#0969da",
    "markdownLink": "#0969da",
    "markdownLinkText": "#0969da",
    "markdownCode": "#8250df",
    "markdownBlockQuote": "#6a737d",
    "markdownEmph": "#24292e",
    "markdownStrong": "#24292e",
    "markdownHorizontalRule": "#d0d7de",
    "markdownListItem": "#24292e",
    "markdownListEnumeration": "#6a737d",
    "markdownImage": "#0969da",
    "markdownImageText": "#6a737d",
    "markdownCodeBlock": "#f6f8fa",
    "syntaxComment": "#6a737d",
    "syntaxKeyword": "#cf222e",
    "syntaxFunction": "#8250df",
    "syntaxVariable": "#24292e",
    "syntaxString": "#0a3069",
    "syntaxNumber": "#0550ae",
    "syntaxType": "#953800",
    "syntaxOperator": "#24292e",
    "syntaxPunctuation": "#24292e"
  }
}
EOF

cat > /root/.config/opencode/tui.json <<'EOF'
{
  "$schema": "https://opencode.ai/tui.json",
  "theme": "notepad"
}
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "opencode" Enter

# Light xterm.js theme (true white "notepad" paper), matching the notepad
# theme above -- covers the shell prompt/chrome around the opencode TUI.
# Yellow is darkened from pure #ffff00 since that's unreadable on white.
LIGHT_THEME='theme={"background":"#ffffff","foreground":"#24292e","cursor":"#24292e","cursorAccent":"#ffffff","selectionBackground":"#c8e1ff","black":"#24292e","red":"#d73a49","green":"#22863a","yellow":"#b08800","blue":"#005cc5","magenta":"#5a32a3","cyan":"#032f62","white":"#6a737d","brightBlack":"#6a737d","brightRed":"#cb2431","brightGreen":"#22863a","brightYellow":"#b08800","brightBlue":"#005cc5","brightMagenta":"#5a32a3","brightCyan":"#3192aa","brightWhite":"#ffffff"}'

exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' -t "$LIGHT_THEME" tmux attach-session -t main
