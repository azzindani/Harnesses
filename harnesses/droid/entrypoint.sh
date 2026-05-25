#!/bin/sh
set -e

# Droid (Factory CLI) loads BYOK custom models from ~/.factory/settings.json.
# The `customModels` array entries take `model`, `provider`, `base_url`,
# `api_key`, plus optional `displayName`.  `provider: anthropic` routes the
# request to OpenRouter's Anthropic-compat surface (which we also proxy).
mkdir -p /root/.factory
python3 - <<PY
import json, os
api = os.environ.get("ANTHROPIC_BASE_URL") or os.environ["PROVIDER_ANTHROPIC_URL"]
cfg = {
  "customModels": [
    {
      "model": "lab-anthropic",
      "provider": "anthropic",
      "base_url": api,
      "api_key": os.environ.get("PROVIDER_API_KEY", "not-used"),
      "displayName": "Lab via OpenRouter (Anthropic surface)",
      "apiModel": os.environ["MODEL_NAME"],
    }
  ]
}
with open("/root/.factory/settings.json", "w") as f:
    json.dump(cfg, f, indent=2)
PY

tmux new-session -d -s main -c /workspace
# `-m lab-anthropic` selects our custom model entry; --auto low restricts
# autonomy to read-only ops (safe default for a fresh session).
tmux send-keys -t main "droid -m lab-anthropic" Enter
exec ttyd --port 7681 --writable --check-origin=false tmux attach-session -t main
