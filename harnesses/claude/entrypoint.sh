#!/bin/sh
set -e

# ── Populate Claude Code's /model picker with several free models ──────────────
# Claude Code's picker labels are fixed (Default / Opus / Sonnet / Haiku + one
# custom entry) and it never queries /v1/models — but each tier can resolve to a
# *different* model.  So we map the live free-model catalog (served by the auth
# proxy at /v1/models) onto those slots: the picker then shows several distinct,
# currently-valid free models instead of one.
#
# Re-fetched on every cold start → the picker self-updates as OpenRouter adds or
# retires free models, with no manual maintenance.  The model configured via the
# x-anthropic-env anchor stays primary (Sonnet / default slot).  If the catalog
# fetch fails, the original single-model defaults remain in effect.
#
# Only the model-alias vars are touched here — BASE_URL and AUTH_TOKEN are left
# exactly as the anchor set them (overriding those would break the proxy path).
#
# CLAUDE_MODEL (from .env) is this harness's own default, e.g.
# opencode-go/muse-spark-1.3-contributor, instead of the MODEL_NAME every
# harness shares. ANTHROPIC_MODEL outranks the model /model saves into
# settings.json, so every launch -- the --continue relaunch after an idle stop
# and each claude-<slug> session included -- starts on it, while /model still
# switches for the session. Subagents follow it, and so do the Opus and Haiku
# slots below, so nothing in a session falls back to a free OpenRouter model.
if [ -n "$CLAUDE_MODEL" ]; then
    export ANTHROPIC_MODEL="$CLAUDE_MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$CLAUDE_MODEL"
    export CLAUDE_CODE_SUBAGENT_MODEL="$CLAUDE_MODEL"
fi
PRIMARY="${ANTHROPIC_DEFAULT_SONNET_MODEL:-$ANTHROPIC_DEFAULT_OPUS_MODEL}"
CATALOG_URL="${ANTHROPIC_BASE_URL%/anthropic}/v1/models"
IDS=$(curl -fsS --max-time 8 "$CATALOG_URL" 2>/dev/null | jq -r '.data[].id' 2>/dev/null || true)

# Primary first, then the catalog; drop blanks and duplicates.
PICK=$(printf '%s\n%s\n' "$PRIMARY" "$IDS" | awk 'NF && !seen[$0]++')
M1=$(printf '%s\n' "$PICK" | sed -n 1p)
M2=$(printf '%s\n' "$PICK" | sed -n 2p)
M3=$(printf '%s\n' "$PICK" | sed -n 3p)
M4=$(printf '%s\n' "$PICK" | sed -n 4p)

# Sonnet (= Default) keeps the configured primary; the others get distinct free
# models when available, falling back to the primary if the catalog is short.
export ANTHROPIC_DEFAULT_SONNET_MODEL="$M1"
if [ -n "$CLAUDE_MODEL" ]; then
    # CLAUDE_MODEL fills these too. Claude Code runs session titles and
    # WebFetch summaries on Haiku, and caps a built-in Explore subagent at
    # Opus whenever the main model isn't a Claude model. On free OpenRouter
    # models those calls hung for minutes (a 504 after 3 minutes), and the
    # session waited on them behind "will retry in 4m". The bare id, because
    # the proxy doesn't strip [1m].
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${CLAUDE_MODEL%\[1m\]}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CLAUDE_MODEL%\[1m\]}"
else
    export ANTHROPIC_DEFAULT_OPUS_MODEL="${M2:-$M1}"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${M3:-$M1}"
fi
export ANTHROPIC_CUSTOM_MODEL_OPTION="${M4:-${M2:-$M1}}"

# Gateway model discovery: Claude Code queries ${ANTHROPIC_BASE_URL}/v1/models at
# startup and adds the full free catalog to the /model picker (labelled "From
# gateway"), so all free models are pickable — not just the 4 tier slots above.
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1

echo "Claude /model picker (active = $ANTHROPIC_MODEL):"
echo "  Sonnet (default) = $ANTHROPIC_DEFAULT_SONNET_MODEL"
echo "  Opus             = $ANTHROPIC_DEFAULT_OPUS_MODEL"
echo "  Haiku            = $ANTHROPIC_DEFAULT_HAIKU_MODEL"
echo "  Custom           = $ANTHROPIC_CUSTOM_MODEL_OPTION"
echo "  (type '/model <id>' to pick any other free model from the catalog)"

# ── Real per-model rates for Claude Code's cost estimate ──────────────────────
# Claude Code prices a model it doesn't recognize at list rates, so the status
# line's `est $` for Muse Spark read ~50x what OpenCode Go charges. modelPricing
# fixes the rates, but only from managed settings, and the file-based source,
# /etc/claude-code/managed-settings.json, is ours to write in this image
# (Claude Code reloads it when it changes). Rates are OpenCode Go's, from
# models.dev (the catalog opencode itself prices from), keyed by every spelling
# a session can carry: the bare id, the `[1m]` context-window suffix, and the
# `anthropic/` prefix the /model picker adds. Every free OpenRouter model is $0.
# Rebuilt each boot; if models.dev is unreachable the previous file stays.
mkdir -p /etc/claude-code
python3 - "$IDS" <<'PY' || echo "pricing: WARNING could not write modelPricing"
import json, os, sys, urllib.request
free_ids = sys.argv[1].split()
try:
    # models.dev answers Python's default "Python-urllib" user agent with 403.
    req = urllib.request.Request("https://models.dev/api.json",
                                 headers={"User-Agent": "harness-lab (claude entrypoint)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        go = json.load(r).get("opencode-go", {}).get("models", {})
except Exception as e:
    print(f"pricing: models.dev unreachable ({e}); keeping previous rates")
    sys.exit(0)
overrides = {}
for mid, m in go.items():
    c = m.get("cost") or {}
    if "input" not in c or "output" not in c:
        continue
    rate = {"input": c["input"], "output": c["output"],
            "cacheRead": c.get("cache_read", c["input"]),
            "cacheWrite": c.get("cache_write", c["input"])}
    for key in (f"opencode-go/{mid}", f"opencode-go/{mid}[1m]",
                f"anthropic/opencode-go/{mid}", f"anthropic/opencode-go/{mid}[1m]"):
        overrides[key] = rate
zero = {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}
for mid in free_ids:
    overrides.setdefault(mid, zero)
    overrides.setdefault(f"anthropic/{mid}", zero)
path = "/etc/claude-code/managed-settings.json"
with open(path + ".tmp", "w") as f:
    # WebSearch runs on Anthropic's own servers, so a session on OpenCode Go or
    # OpenRouter gets an empty result set and burns a turn on it -- denied here,
    # where a session can't override it, leaving the web MCP's `search` as the
    # one that works. WebFetch is NOT denied: it fetches in the client and
    # summarises with the configured model, and answers correctly (verified on
    # example.com and docs.python.org).
    json.dump({"modelPricing": {"overrides": overrides},
               "permissions": {"deny": ["WebSearch"]}}, f, indent=1)
os.replace(path + ".tmp", path)
print(f"pricing: {len(go)} OpenCode Go models, {len(free_ids)} free OpenRouter models")
PY

# ── Register MCP servers ─────────────────────────────────────────────────────
# Containers are ephemeral, so MCP servers are (re)registered at every boot from
# env vars rather than baked into a persisted config.  The *_MCP_* vars come
# from the shared .env via the compose env_file.  Registered at user scope so
# the servers are available in every /workspace session.
#
# MCP_DISABLED (from .env) drops servers exactly as the opencode harness does:
# a whole entry name ("browser", "office-xlsx-new") or a repo prefix ("office"
# drops all eleven), so the two personal harnesses see the same set.  Every
# tool a server exposes is context spent on every request -- on OpenCode Go,
# quota.  A dropped server is also removed: a container that was restarted
# rather than recreated still has the last boot's registrations in
# ~/.claude.json.
_mcp_disabled() {  # name -> true when MCP_DISABLED lists it or its repo prefix
    case ",$(printf '%s' "$MCP_DISABLED" | tr -d ' ' | tr 'A-Z' 'a-z')," in
        *",$1,"*|*",${1%%-*},"*) return 0 ;;
    esac
    return 1
}

_mcp_register() {  # name url token(optional)
    name="$1"; url="$2"; token="$3"
    claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
    if _mcp_disabled "$name"; then
        echo "MCP: skipped '$name' (MCP_DISABLED)"
        return 0
    fi
    if [ -n "$token" ]; then
        if claude mcp add --scope user --transport http "$name" "$url" \
            --header "Authorization: Bearer $token" >/dev/null 2>&1; then
            echo "MCP: registered '$name' -> $url"
        else
            echo "MCP: WARNING failed to register '$name'"
        fi
    else
        if claude mcp add --scope user --transport http "$name" "$url" >/dev/null 2>&1; then
            echo "MCP: registered '$name' -> $url"
        else
            echo "MCP: WARNING failed to register '$name'"
        fi
    fi
}

[ -n "$FOLIO_MCP_URL" ] && [ -n "$FOLIO_MCP_TOKEN" ] && _mcp_register folio "$FOLIO_MCP_URL" "$FOLIO_MCP_TOKEN"
# Pipeline (/root/Pipeline, Rust).  The binary baked in from PIPELINE_MCP_IMAGE
# wins: over stdio it works on /workspace with no capability gate.  The remote
# endpoint is only a fallback -- it runs PIPELINE_REMOTE_MODE=read_only and on
# its own /work, so every write or run through it is refused.  Pipeline roots
# itself at its cwd (the session's), or at PIPELINE_PROJECT when that names a
# directory: every call reads pipeline.yaml from that root.
claude mcp remove --scope user pipeline >/dev/null 2>&1 || true
if command -v pipeline >/dev/null 2>&1; then
    if _mcp_disabled pipeline; then
        echo "MCP: skipped 'pipeline' (MCP_DISABLED)"
    else
        set -- mcp --transport stdio
        if [ -n "$PIPELINE_PROJECT" ]; then
            if [ -d "$PIPELINE_PROJECT" ]; then
                set -- "$@" --project "$PIPELINE_PROJECT"
            else
                echo "MCP: WARNING PIPELINE_PROJECT '$PIPELINE_PROJECT' is not a directory; pipeline follows the session cwd"
            fi
        fi
        if claude mcp add --scope user pipeline -- pipeline "$@" >/dev/null 2>&1; then
            echo "MCP: registered 'pipeline' -> stdio $(pipeline --version 2>/dev/null) ($*)"
        else
            echo "MCP: WARNING failed to register 'pipeline'"
        fi
    fi
elif [ -n "$PIPELINE_MCP_URL" ] && [ -n "$PIPELINE_MCP_TOKEN" ]; then
    _mcp_register pipeline "$PIPELINE_MCP_URL" "$PIPELINE_MCP_TOKEN"
fi
# Web search/fetch (DuckDuckGo sidecar) — no auth header.
[ -n "$WEB_MCP_URL" ] && _mcp_register web "$WEB_MCP_URL"

# The self-hosted MCP_* servers. Single-endpoint repos (math/browser/
# filesystem) register directly; the sub-mounted repos (ml/data/office/docs)
# have no single unified endpoint, so each sub-server under <BASE>/<name>/mcp
# is registered as its own named server ("ml-basic", "data-workspace", etc).
[ -n "$MATH_MCP_URL" ] && [ -n "$MATH_MCP_TOKEN" ] && _mcp_register math "$MATH_MCP_URL" "$MATH_MCP_TOKEN"
[ -n "$BROWSER_MCP_URL" ] && [ -n "$BROWSER_MCP_TOKEN" ] && _mcp_register browser "$BROWSER_MCP_URL" "$BROWSER_MCP_TOKEN"
[ -n "$FS_MCP_URL" ] && [ -n "$FS_MCP_TOKEN" ] && _mcp_register filesystem "$FS_MCP_URL" "$FS_MCP_TOKEN"

if [ -n "$ML_MCP_BASE_URL" ] && [ -n "$ML_MCP_TOKEN" ]; then
    for t in basic medium advanced; do
        _mcp_register "ml-$t" "$ML_MCP_BASE_URL/$t/mcp" "$ML_MCP_TOKEN"
    done
fi
if [ -n "$DATA_MCP_BASE_URL" ] && [ -n "$DATA_MCP_TOKEN" ]; then
    for s in basic medium statistics transform visual workspace ingest; do
        _mcp_register "data-$s" "$DATA_MCP_BASE_URL/$s/mcp" "$DATA_MCP_TOKEN"
    done
fi
if [ -n "$OFFICE_MCP_BASE_URL" ] && [ -n "$OFFICE_MCP_TOKEN" ]; then
    for s in docx-basic docx-tables docx-layout docx-new xlsx-basic xlsx-formulas xlsx-charts xlsx-new pptx-basic pptx-design pptx-new; do
        _mcp_register "office-$s" "$OFFICE_MCP_BASE_URL/$s/mcp" "$OFFICE_MCP_TOKEN"
    done
fi
if [ -n "$DOCS_MCP_BASE_URL" ] && [ -n "$DOCS_MCP_TOKEN" ]; then
    for s in read edit; do
        _mcp_register "docs-$s" "$DOCS_MCP_BASE_URL/$s/mcp" "$DOCS_MCP_TOKEN"
    done
fi

# Pre-accept the first-run dialogs (onboarding, "trust this folder", and the
# Bypass Permissions warning) so a freshly-recreated container drops straight
# into the session instead of stopping on interactive prompts.  ~/.claude.json
# is ephemeral (recreated each boot), so this is re-seeded every time.
CFG="$HOME/.claude.json"
[ -f "$CFG" ] || echo '{}' > "$CFG"
_tmp=$(mktemp)
if jq '.hasCompletedOnboarding = true
       | .bypassPermissionsModeAccepted = true
       | .projects = (.projects // {})
       | .projects["/workspace"] = ((.projects["/workspace"] // {}) + {
             hasTrustDialogAccepted: true,
             bypassPermissionsModeAccepted: true,
             hasCompletedProjectOnboarding: true
         })' "$CFG" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$CFG"
else
    rm -f "$_tmp"
fi

# Light "notepad" theme: Claude Code's own "light" theme only retunes its
# foreground palette for readability on a light background — it never paints
# the background itself, so the actual bg color has to come from the ttyd/
# xterm.js theme below. settings.json lives on the persistent claude_state
# volume, so this is set idempotently rather than only on first boot.
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
_tmp=$(mktemp)
# The status line shows model, thinking effort, directory, context used and
# Claude Code's estimated session cost (harnesses/claude/statusline.py, baked
# into the image), set the same idempotent way. -B keeps Python from writing
# __pycache__ into /opt.
if jq '.theme = "light"
       | .statusLine = {type: "command", command: "python3 -B /opt/claude-statusline.py"}' \
       "$SETTINGS" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$SETTINGS"
else
    rm -f "$_tmp"
fi

# Run with permissions bypassed.  Claude Code refuses --dangerously-skip-
# permissions under root, but IS_SANDBOX=1 marks this container as a sandbox and
# re-enables it (the lab containers are disposable and network-isolated).
export IS_SANDBOX=1

tmux new-session -d -s main -c /workspace
# `--continue` resumes the most recent conversation for this cwd. That matters
# because this entrypoint runs again every time the idle sweep has stopped the
# container and a visit restarts it: without it, waking up drops you into a
# blank session even though the transcript is sitting right there in
# ./history/claude. The `||` fallback covers the first-ever boot (nothing to
# continue yet), where `claude --continue` exits instead of starting.
# Deliberately NOT applied to dynamic <harness>-<slug> sessions (see
# HARNESS_LAUNCH_CMD in auth/server.py): they share this one /workspace, so
# resuming would point every parallel slug at the SAME conversation.
# Written to a file, not just sent: the auth service re-sends this exact line
# when a tab reconnects and `main` is gone (_ensure_base_session in
# auth/server.py), so quitting the CLI no longer leaves a terminal that can
# only fail to attach.
printf '%s\n' "claude --continue --dangerously-skip-permissions || claude --dangerously-skip-permissions" \
    > /run/main-launch
tmux send-keys -t main "$(cat /run/main-launch)" Enter

# The Bypass Permissions warning can't be pre-accepted via config (the config
# flags are ignored), so auto-confirm it once the dialog renders — this is a
# disposable, network-isolated sandbox and bypass is the intended mode.  Polls
# the pane for the dialog's unique text, then selects "Yes, I accept".
(
  i=0
  while [ "$i" -lt 40 ]; do
    if tmux capture-pane -t main -p 2>/dev/null | grep -q "Yes, I accept"; then
      tmux send-keys -t main Down
      sleep 0.3
      tmux send-keys -t main Enter
      break
    fi
    i=$((i + 1))
    sleep 0.5
  done
) &

# Light xterm.js theme (true white "notepad" paper) so the terminal's own
# background is actually white — Claude Code relies on this rather than
# painting a background itself (see .theme = "light" above). Yellow is
# darkened from pure #ffff00 since that's unreadable on a white background.
LIGHT_THEME='theme={"background":"#ffffff","foreground":"#24292e","cursor":"#24292e","cursorAccent":"#ffffff","selectionBackground":"#c8e1ff","black":"#24292e","red":"#d73a49","green":"#22863a","yellow":"#b08800","blue":"#005cc5","magenta":"#5a32a3","cyan":"#032f62","white":"#6a737d","brightBlack":"#6a737d","brightRed":"#cb2431","brightGreen":"#22863a","brightYellow":"#b08800","brightBlue":"#005cc5","brightMagenta":"#5a32a3","brightCyan":"#3192aa","brightWhite":"#ffffff"}'

exec ttyd --port 7681 --writable -t fontSize=18 -t scrollback=10000 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' -t "$LIGHT_THEME" tmux attach-session -t main
