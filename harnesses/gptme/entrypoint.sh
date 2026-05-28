#!/bin/sh
set -e

mkdir -p /root/.config/gptme
cat > /root/.config/gptme/config.toml <<EOF
[prompt]
about_user = "Lab user running gptme"

[env]
PROVIDER_API_KEY = "${PROVIDER_API_KEY:-not-used}"

[[providers]]
name = "lab"
base_url = "${PROVIDER_BASE_URL}"
api_key_env = "PROVIDER_API_KEY"
default_model = "${MODEL_NAME}"
EOF

tmux new-session -d -s main -c /workspace
tmux send-keys -t main "gptme --model lab/${MODEL_NAME}" Enter
exec ttyd --port 7681 --writable --check-origin=false -t fontSize=18 -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' tmux attach-session -t main
