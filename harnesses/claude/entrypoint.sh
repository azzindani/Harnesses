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
export ANTHROPIC_DEFAULT_OPUS_MODEL="${M2:-$M1}"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="${M3:-$M1}"
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

# ── Register external MCP servers (Folio + web search) ────────────────────────
# Containers are ephemeral, so MCP servers are (re)registered at every boot from
# env vars rather than baked into a persisted config.  FOLIO_MCP_* / WEB_MCP_URL
# come from the shared .env via the compose env_file.  Registered at user scope
# so the servers are available in every /workspace session.
if [ -n "$FOLIO_MCP_URL" ] && [ -n "$FOLIO_MCP_TOKEN" ]; then
    claude mcp remove --scope user folio >/dev/null 2>&1 || true
    if claude mcp add --scope user --transport http folio "$FOLIO_MCP_URL" \
        --header "Authorization: Bearer $FOLIO_MCP_TOKEN" >/dev/null 2>&1; then
        echo "MCP: registered 'folio' -> $FOLIO_MCP_URL"
    else
        echo "MCP: WARNING failed to register 'folio'"
    fi
fi
# Web search/fetch (DuckDuckGo sidecar) — no auth header.
if [ -n "$WEB_MCP_URL" ]; then
    claude mcp remove --scope user web >/dev/null 2>&1 || true
    if claude mcp add --scope user --transport http web "$WEB_MCP_URL" >/dev/null 2>&1; then
        echo "MCP: registered 'web' -> $WEB_MCP_URL"
    else
        echo "MCP: WARNING failed to register 'web'"
    fi
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

# Run with permissions bypassed.  Claude Code refuses --dangerously-skip-
# permissions under root, but IS_SANDBOX=1 marks this container as a sandbox and
# re-enables it (the lab containers are disposable and network-isolated).
export IS_SANDBOX=1

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "claude --dangerously-skip-permissions" Enter

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

exec ttyd --port 7681 --writable -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
