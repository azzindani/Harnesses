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
#   MCP_DISABLED                    -> comma-separated names to leave out
python3 - <<'PY'
import json, os

config = {
    "$schema": "https://opencode.ai/config.json",
    # An unattended sweep cannot answer a permission dialog, and a blocked
    # session is indistinguishable from a slow one until the phase times out.
    # Round 16 lost phase 57 to "△ Permission required — Access external
    # directory /tmp/xlsx_check/xl/charts": the model had unzipped a workbook to
    # /tmp to read the raw chart XML, which is precisely the verification the
    # round asks for, and the harness stopped it to ask.
    #
    # Scoped rather than blanket-allowed. /tmp is where the models extract
    # archives and /workspace is the material under test; anything else still
    # asks, so this does not quietly hand the model the whole filesystem.
    "permission": {
        "external_directory": {
            "/tmp/**": "allow",
            "/workspace/**": "allow",
            "*": "ask",
        },
    },
}

# OPENCODE_MODEL names a model opencode already knows -- one of the entries in
# `opencode models`, provider included, e.g. opencode/x-preview-f-free. Those
# providers carry their own endpoint and their own credentials, so the config
# says which model and nothing else; inventing a provider block for one of them
# only overrides what already works. That is what the first attempt at this did:
# it pointed a hand-rolled openai-compatible provider at the OpenCode Zen URL
# with no key of its own, and every request came back "Invalid API key".
#
# Unset, the harness builds the `lab` provider from the shared PROVIDER_* /
# OPENAI_* environment, which is the OpenRouter-via-auth-proxy route the other
# twelve harnesses use.
_qualified = os.environ.get("OPENCODE_MODEL", "").strip()
if _qualified:
    config["model"] = _qualified
else:
    config["provider"] = {
        "lab": {
            "npm": "@ai-sdk/openai-compatible",
            "options": {
                # The key follows the same precedence as the URL it is sent to.
                # These two used to disagree -- the URL preferred OPENAI_*, the
                # key preferred PROVIDER_* -- so pointing this harness at a
                # different host kept sending the previous host's credential to
                # it. Repointing the base URL is exactly when the key must move
                # with it, so the one case the split mattered was the one that
                # leaked.
                "baseURL": os.environ.get("OPENAI_BASE_URL") or os.environ.get("PROVIDER_BASE_URL", ""),
                "apiKey": os.environ.get("OPENAI_API_KEY") or os.environ.get("PROVIDER_API_KEY") or "not-used",
            },
            "models": {
                os.environ.get("MODEL_NAME", ""): {},
            },
        },
    }
    config["model"] = "lab/" + os.environ.get("MODEL_NAME", "")

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

# Drop the servers this harness is not meant to see. Names match either a whole
# entry ("math", "folio", "office-xlsx-new") or the repo prefix of a multi-server
# repo ("office" removes all eleven). Registering a server the session will not
# use is not free: every tool it exposes is spent context in the model's tool
# list, and a sweep that is scoped to four repos should not be told about six.
# Leaving the URL and token in .env means re-enabling is a one-word edit.
_disabled = {n.strip().lower() for n in os.environ.get("MCP_DISABLED", "").split(",") if n.strip()}
if _disabled:
    mcp = {k: v for k, v in mcp.items() if k not in _disabled and k.split("-")[0] not in _disabled}

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

# --model, from the same value written into config.json above.
#
# config.json only supplies the *default* model. Once someone picks one in the
# TUI, that choice is recorded on the session row and every new session inherits
# it, so a session started before a config change keeps using the old model
# indefinitely -- recreating the container does not clear it, because the
# session database is a bind mount that outlives the container. Switching the
# harness back to OpenRouter left the TUI still on the OpenCode Zen model it had
# been pointed at hours earlier, which was by then out of free quota.
#
# Passing it on the command line pins each boot to the configured model.
if [ -n "${OPENCODE_MODEL:-}" ]; then
  OC_MODEL="$OPENCODE_MODEL"
else
  OC_MODEL="lab/${MODEL_NAME}"
fi

# `--continue` resumes the last session, so waking the container after an
# idle-stop lands back in the conversation instead of a blank one (the session
# data itself already survives in ./history/opencode). `|| opencode` covers the
# first-ever boot, when there's no last session to continue. Deliberately NOT
# applied to dynamic <harness>-<slug> sessions -- see the same note in
# harnesses/claude/entrypoint.sh.
tmux send-keys -t main "opencode --model '$OC_MODEL' --continue || opencode --model '$OC_MODEL'" Enter

# Light xterm.js theme (true white "notepad" paper), matching the notepad
# theme above -- covers the shell prompt/chrome around the opencode TUI.
# Yellow is darkened from pure #ffff00 since that's unreadable on white.
LIGHT_THEME='theme={"background":"#ffffff","foreground":"#24292e","cursor":"#24292e","cursorAccent":"#ffffff","selectionBackground":"#c8e1ff","black":"#24292e","red":"#d73a49","green":"#22863a","yellow":"#b08800","blue":"#005cc5","magenta":"#5a32a3","cyan":"#032f62","white":"#6a737d","brightBlack":"#6a737d","brightRed":"#cb2431","brightGreen":"#22863a","brightYellow":"#b08800","brightBlue":"#005cc5","brightMagenta":"#5a32a3","brightCyan":"#3192aa","brightWhite":"#ffffff"}'

exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' -t "$LIGHT_THEME" tmux attach-session -t main
