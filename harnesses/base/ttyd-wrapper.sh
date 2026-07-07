#!/bin/sh
# Transparent ttyd wrapper installed at /usr/local/bin/ttyd (earlier in PATH
# than the real /usr/bin/ttyd). Every harness entrypoint already runs `ttyd ...`
# to serve its browser terminal; this wrapper injects a custom index.html that
# adds in-page Ctrl+C / Ctrl+V copy-paste (see ttyd-kbfix.html) without any
# per-harness change. If anything goes wrong it falls back to plain ttyd, so it
# can never block the terminal from starting.
set -e

REAL_TTYD=/usr/bin/ttyd
SNIPPET=/opt/ttyd-kbfix.html          # the <script> snippet, baked into the image
INDEX=/run/ttyd-kbfix-index.html      # generated custom index (tmpfs, per boot)
SCRATCH_PORT=7699

build_index() {
    [ -s "$SNIPPET" ] || return 1
    # ttyd's index.html (with the whole app inlined) lives inside the binary, so
    # the only way to obtain it is to ask a running ttyd. Start one briefly on a
    # localhost-only scratch port, fetch /, then stop it.
    "$REAL_TTYD" --port "$SCRATCH_PORT" --interface 127.0.0.1 sh >/dev/null 2>&1 &
    p=$!
    i=0
    rm -f /run/_ttyd_idx.html
    while [ "$i" -lt 40 ]; do
        if curl -sf "http://127.0.0.1:${SCRATCH_PORT}/" -o /run/_ttyd_idx.html 2>/dev/null; then
            break
        fi
        i=$((i + 1))
        sleep 0.2
    done
    kill "$p" 2>/dev/null || true
    [ -s /run/_ttyd_idx.html ] || return 1
    # Inject a mobile viewport meta tag (ttyd's stock index.html ships without
    # one, so real phone browsers fall back to a ~980px desktop-width layout
    # and zoom the whole page out to fit -- confirmed via a real-device-
    # profile headless browser test, where the terminal element measured
    # ~2.5x the actual viewport size; that scale mismatch maps touch/tap
    # coordinates wrong and made the page feel broken/zoomed-out on a real
    # phone even though desktop and an explicit-viewport test both looked
    # fine) right after <head>, and the kbfix snippet right before </body>.
    SNIPPET="$SNIPPET" python3 - /run/_ttyd_idx.html "$INDEX" <<'PY' || return 1
import os, sys
src_path, out_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding='utf-8', errors='surrogateescape').read()
viewport = '<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">'
src = src.replace('<head>', '<head>' + viewport, 1) if '<head>' in src else viewport + src
snip = open(os.environ['SNIPPET'], encoding='utf-8').read()
src = src.replace('</body>', snip + '</body>', 1) if '</body>' in src else src + snip
open(out_path, 'w', encoding='utf-8', errors='surrogateescape').write(src)
PY
    rm -f /run/_ttyd_idx.html
    [ -s "$INDEX" ]
}

if [ ! -s "$INDEX" ]; then
    build_index || true
fi

if [ -s "$INDEX" ]; then
    exec "$REAL_TTYD" --index "$INDEX" "$@"
fi

# Fallback: never block terminal startup if index generation failed.
exec "$REAL_TTYD" "$@"
