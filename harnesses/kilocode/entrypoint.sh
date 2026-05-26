#!/usr/bin/with-contenv bash
# shellcheck shell=bash
set -e

# Install Kilo Code extension if not already present.
EXT_DIR="/config/extensions"
mkdir -p "$EXT_DIR"
if ! ls "$EXT_DIR" 2>/dev/null | grep -qi kilocode; then
    s6-setuidgid abc code-server --install-extension kilocode.kilo-code || true
fi

# Seed the extension's provider config.
SETTINGS_DIR="/config/data/User"
mkdir -p "$SETTINGS_DIR"
cat > "$SETTINGS_DIR/settings.json" <<EOF
{
  "kilo-code.providers": [
    {
      "id": "lab",
      "type": "openai-compatible",
      "baseUrl": "${PROVIDER_BASE_URL}",
      "apiKey": "${PROVIDER_API_KEY:-not-used}",
      "model": "${MODEL_NAME}"
    }
  ],
  "kilo-code.activeProvider": "lab"
}
EOF
chown -R abc:abc /config
