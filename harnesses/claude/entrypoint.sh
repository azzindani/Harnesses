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

echo "Claude /model picker:"
echo "  Sonnet (default) = $ANTHROPIC_DEFAULT_SONNET_MODEL"
echo "  Opus             = $ANTHROPIC_DEFAULT_OPUS_MODEL"
echo "  Haiku            = $ANTHROPIC_DEFAULT_HAIKU_MODEL"
echo "  Custom           = $ANTHROPIC_CUSTOM_MODEL_OPTION"
echo "  (type '/model <id>' to pick any other free model from the catalog)"

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "claude" Enter
exec ttyd --port 7681 --writable -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
