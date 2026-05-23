# OpenHands ships its own web UI on port 3000 — no ttyd/tmux needed.  We use
# the upstream image directly and let the auth+caddy chain gate access.
#
# Image source: the canonical registry `docker.all-hands.dev` is intermittently
# DNS-broken on some hosts; the GitHub Container Registry mirror is reliable.
# Bump the tag as upstream releases (`ghcr.io/all-hands-ai/openhands:0.x`).
FROM ghcr.io/all-hands-ai/openhands:0.20
# The image already EXPOSEs 3000 and runs its own entrypoint.
