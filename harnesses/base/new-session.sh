#!/bin/sh
# Usage: new-session.sh <slug> <port> <launch_cmd>
#
# Idempotently creates an additional tmux session (sharing this container's
# /workspace) and a ttyd process bound to <port>, attached to that session --
# all INSIDE this already-running harness container. Invoked via
# `docker exec <container> /opt/new-session.sh ...` by the auth service
# (_ensure_dynamic_session in auth/server.py) the first time a
# `<harness>-<slug>` subdomain is visited. Every simultaneous session shares
# the one container + one /workspace by design (see the
# harness-multi-instance project memory) -- this is NOT a new container, just
# another tmux window + ttyd process reachable on its own port.
set -e

SLUG="$1"
PORT="$2"
LAUNCH_CMD="$3"

if [ -z "$SLUG" ] || [ -z "$PORT" ]; then
    echo "usage: new-session.sh <slug> <port> <launch_cmd>" >&2
    exit 1
fi

if ! tmux has-session -t "$SLUG" 2>/dev/null; then
    tmux new-session -d -s "$SLUG" -c /workspace
    if [ -n "$LAUNCH_CMD" ]; then
        tmux send-keys -t "$SLUG" "$LAUNCH_CMD" Enter
    fi
fi

# Match "--port $PORT --writable" rather than "ttyd --port $PORT" -- the
# ttyd-wrapper.sh in front of the real binary (see base image) always inserts
# its own `--index <file>` flag between "ttyd" and "--port", so a pattern
# anchored on "ttyd --port" never matches the real running process and would
# spawn a duplicate on every call (verified empirically: it left a defunct
# zombie process when this bug was still in place).
if ! pgrep -f -- "--port $PORT --writable" >/dev/null 2>&1; then
    nohup ttyd --port "$PORT" --writable --check-origin=false \
        -t fontSize=18 \
        -t 'fontFamily="JetBrains Mono, Menlo, Consolas, monospace"' \
        tmux attach-session -t "$SLUG" \
        >>/var/log/ttyd-extra.log 2>&1 &
fi
