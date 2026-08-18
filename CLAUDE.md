# CLAUDE.md — Harnesses: Multi-Agent Coding Lab

## Project overview

A personal lab for running multiple AI coding CLI agents ("harnesses") side by side — Claude Code, Aider, OpenCode, Crush, gptme, Goose, Plandex, Qwen Code, Codex CLI, Pi, and Droid — each wrapped in `ttyd` (browser terminal) + `tmux` (session persistence) inside its own Docker container, all fed by one shared model provider config, each reachable from a browser on its own subdomain. Containers sleep when idle and wake on first request.

Status: **v0.1.0, single-operator lab, not multi-tenant.** One shared JWT secret, one shared model/provider budget. Treat it as an example/reference project, not a hardened multi-user service.

`README.md` is the user-facing setup guide (quick start, env vars, troubleshooting) — read it first for "how do I run this." This file is the agent-facing map of how the pieces fit together and the gotchas that aren't obvious from the code.

## Architecture

```
Browser
  │
  ▼
Shared Caddy reverse proxy (external to this repo — see caddy-snippet.txt)
  │
  ├── on-demand TLS "ask" gate ──► auth:/ask   (is this hostname ours?)
  │
  └── forward_auth ──► auth:/verify
        │                  ├─ validates the session cookie (or Bearer, or ?token=)
        │                  ├─ re-mints it when near expiry → X-Harness-Session
        │                  │  (Caddy copies it onto the response as Set-Cookie)
        │                  ├─ starts the target container if it's stopped
        │                  ├─ for a "<harness>-<slug>" hostname, docker-execs
        │                  │  an extra tmux+ttyd session into the SAME base
        │                  │  container (not a separate container)
        │                  └─ returns X-Harness-Upstream: harness-<type>:<port>
        │
        └── reverse_proxy {that header} ──► harness-<type> container
                                                  │
                                          ttyd (browser terminal)
                                                  │
                                          tmux ("main" + any extra sessions)
                                                  │
                                          the actual CLI (claude / aider / …)
```

- **The browser cookie holds a minted *session* token, not the credential you logged in with.** `/issue` validates the presented `?token=`/Bearer and then mints a fresh HS256 session JWT (`kind: "session"`, `harness: "*"` under the default `SESSION_SCOPE=all`) for the cookie — so one login covers every subdomain including `files`, the long-lived `TOKEN_*`/`JWT_SECRET` never sits in a browser, and the clock starts at login. `/verify` slides it: when less than `SESSION_REFRESH_DAYS` remain (or the cookie predates this model), it returns the replacement as a complete Set-Cookie value in the `X-Harness-Session` header, which the Caddy `harness_auth` snippet `copy_headers` onto the request and the site block emits with `header +Set-Cookie`. Ported from Folio's editor session (`/root/Folio/src/editor/editor-auth.ts`), which is itself modelled on this lab's JWT module — keep the two conceptually in sync.
- **One FastAPI service (`auth/server.py`)** does JWT-gated login, Sablier-style container lifecycle (start on request, stop after `IDLE_TIMEOUT_MIN` idle), and — for OpenAI-compat harnesses and Claude Code's Anthropic proxy — a translating proxy in front of OpenRouter that serves a self-updating catalog of free, tool-calling models and can transparently fail over between them. There is no separate Sablier/Traefik container; this one service does all of it.
- **No provider is hardcoded.** `.env.example` documents ready-made blocks for OpenRouter, NVIDIA NIM, build.nvidia.com, Anthropic, OpenAI, Groq, Together.ai, DeepSeek, and local Ollama — uncomment one. `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` / `MODEL_NAME` (+ `PROVIDER_ANTHROPIC_URL` for Claude Code/Droid) drive all 11 harnesses.
- **The reverse proxy is external to this repo.** A shared Caddy instance (this user's lives at `/root/caddy-router`, fronting other unrelated projects too) terminates TLS and routes subdomains in. `caddy-snippet.txt` is the block to append to it — this repo does not run Caddy itself.
- **Multiple simultaneous sessions per harness are live**, not a future feature: `https://<harness>-<slug>.<domain>/?token=<jwt>` opens an extra tmux window + ttyd process inside that harness's one existing container/`/workspace` (up to `MAX_INSTANCES_PER_HARNESS`, default 5). It is deliberately not a separate container or volume per slug.
- **Session history is one bind-mounted tree**, `./history/<harness>/`, not per-harness Docker volumes. `tar czf backup.tar.gz history/` backs up everything; `rm -rf history/` is the only thing that destroys it.
- **`harness-files` is a 12th `harness-*` container that isn't a CLI harness** — it's `dufs` (a small file-server), always-on rather than on-demand, giving read-write web access to `project/`, `data/`, and `history/` at `files.<domain>` through the *same* JWT/cookie auth as everything else. It's recognized in `auth/server.py` via `UTILITY_SERVICES`, kept deliberately out of `HARNESSES`/`MULTI_INSTANCE_HARNESSES` so idle-sweep and dynamic-slug logic (which assume ttyd/tmux) leave it alone. See "File management" in `README.md`.

## Harnesses

| Harness | Protocol | Config | Notes |
|---|---|---|---|
| Claude Code | Anthropic (`/v1/messages`) | env vars | via `auth`'s `/anthropic` translating proxy |
| Droid (Factory CLI) | Anthropic-shaped | `~/.factory/settings.json` | BYOK custom model |
| Aider | OpenAI (`/v1/chat/completions`) | env vars | |
| OpenCode | OpenAI-compat | `config.json` + `tui.json` + custom theme | |
| Crush | OpenAI-compat | `crush.json` | unsets `OPENAI_*` so its own config wins |
| gptme | OpenAI-compat | `config.toml` | |
| Goose | OpenAI-compat | `config.yaml` | telemetry prompt disabled at boot |
| Plandex | OpenAI-compat | custom model pack | self-hosted `plandex-server` + Postgres |
| Qwen Code | OpenAI-compat | `settings.json` | auto-updater disabled (breaks TUI mid-session) |
| Codex CLI | OpenAI `/responses` | `config.toml` | talks straight to the provider — bypasses the auth proxy, no free-model fallback |
| Pi | OpenAI-compat | `~/.pi/agent/models.json` | stateless, no persisted history |

Only Claude Code and OpenCode run day to day; the rest are stopped (not removed) to save RAM — `docker compose --profile on-demand up -d harness-<name>` brings any of them back. `openhands` and `kilocode` were dropped entirely (see git history) — do not re-add references to them.

## Key files

```
.env.example              # every provider block + all tunables, no secrets — keep in sync with docker-compose.yml
docker-compose.yml        # the 11 CLI harness-* gated behind the `on-demand` profile (harness-base built first); harness-files is always-on
Makefile                  # tokens, build, up/down, router-reload (targets the external Caddy), validate
auth/server.py            # JWT gate + container lifecycle + free-model proxy — the one always-on brain
scripts/generate-tokens.py
scripts/test-all-harnesses.sh
harnesses/base/           # shared image: Dockerfile, tmux.conf, ttyd-wrapper.sh, ttyd-kbfix.html (clipboard/scroll/reconnect), new-session.sh
harnesses/<name>/          # Dockerfile + entrypoint.sh (writes that CLI's config, launches tmux+ttyd)
web-mcp/                  # bundled DuckDuckGo search/fetch MCP sidecar
caddy-snippet.txt         # append-only block for the external Caddy instance
project/, data/, history/  # gitignored (except .gitkeep) — real working data, see below
```

## Environment variables

Full documented list lives in `.env.example` — don't let it drift from what `docker-compose.yml` actually reads. Highlights: `HARNESS_BASE_DOMAIN`, `JWT_SECRET`, `SESSION_TTL_DAYS` / `SESSION_REFRESH_DAYS` / `SESSION_SCOPE`, `IDLE_TIMEOUT_MIN`, `IDLE_EXEMPT`, `COLD_START_TIMEOUT_S`, `RETENTION_DAYS`, `MAX_INSTANCES_PER_HARNESS`, `TOKEN_<NAME>` (auto-filled by `auth` if blank), `FREE_FALLBACK` / `FREE_REQUIRE_TOOLS`, `FOLIO_MCP_URL` / `FOLIO_MCP_TOKEN`, `WEB_MCP_URL`, and the 6 self-hosted `MCP_*` tool servers: `MATH_MCP_URL`/`_TOKEN`, `BROWSER_MCP_URL`/`_TOKEN`, `FS_MCP_URL`/`_TOKEN`, `ML_MCP_BASE_URL`/`_TOKEN`, `DATA_MCP_BASE_URL`/`_TOKEN`, `OFFICE_MCP_BASE_URL`/`_TOKEN`.

## MCP server registration pattern

Every MCP-capable harness (`claude`, `opencode`, `crush`, `qwencode`, `codex`, `droid`, `goose`, `gptme` — not `aider`/`plandex`/`pi`, which don't support MCP) registers the same set of remote servers in its own native config format, re-seeded from env vars on every boot (see §"Config is not history" below). The pattern is identical across all 8 entrypoints:

- **Single-endpoint repos** (`folio`, `web`, `math`, `browser`, `filesystem`) register directly from a `..._URL` (+ optional `..._TOKEN` for bearer auth) — only if the required var(s) are non-empty.
- **Sub-mounted repos** (`ml`, `data`, `office`) have no single unified endpoint — `MCP_Machine_Learning`, `MCP_Data_Analyst`, and `MCP_Microsoft_Office` each mount several sub-servers at `<BASE_URL>/<sub-server>/mcp`. Their harness var is the BASE url (no `/mcp` suffix); each entrypoint loops over the known sub-server names and registers every one individually as `<repo>-<sub-server>` (e.g. `ml-basic`, `data-workspace`, `office-pptx-design`).
- Adding a 7th self-hosted repo (or a new sub-server to an existing one): add its `..._URL`/`..._TOKEN` pair to `.env.example` + `.env`, then extend the registration block in all 8 `harnesses/<name>/entrypoint.sh` files — there is no single shared helper, each harness's native config format needs its own block, so keep them all in sync by hand.
- This is a lot of tools per harness by design (up to 26 servers / ~225 tools when every repo is configured) — small/free local models may struggle with tool-call reliability at that scale (see the troubleshooting table). Leaving a repo's `..._TOKEN` blank fully disables its registrations with no other changes needed.

## Gotchas for anyone (agent or human) working in this repo

- **`project/`, `data/`, `history/` are gitignored on purpose** (only `.gitkeep` is tracked) — they hold the shared workspace, datasets, and every harness's real conversation history. Never treat them as scratch during a "clean up" pass; never `rm -rf` them.
- **Never commit a real domain, IP, or token.** Use the `lab.example.com` placeholder pattern already used throughout `.env.example`, `caddy-snippet.txt`, and `auth/server.py`'s fallback default — this was violated once (a real domain leaked into committed files) and had to be scrubbed before the v0.1.0 release.
- **`.env` is real secrets, gitignored, never touched by CI beyond a throwaway `cp .env.example .env`** inside the CI runner. Don't run that `cp` against a local checkout that already has a real `.env` — it clobbers it.
- **Multi-session is same-container, not per-slug containers.** If you're touching `auth/server.py`'s dynamic-session logic or `caddy-snippet.txt`, remember the routing target is `X-Harness-Upstream` (a container:port the auth service names), not something derivable from the hostname alone.
- **Don't add a static per-hostname Caddy block alongside the wildcard block** in `caddy-snippet.txt` — an exact-hostname site and a wildcard site covering it are a policy conflict in Caddy's automatic HTTPS and this has broken cert resolution for every harness subdomain before.
- **Idle-stopping a container kills its tmux server**, so every session in it (base `main` + every dynamic slug) dies; only what the CLI wrote under `history/` survives. The answer is NOT to stop sweeping — the operator wants containers asleep (idle opencode ≈ 1.1GB + a few % CPU on a 15GB box, claude ≈ 460MB), and `IDLE_EXEMPT` is empty on purpose. Instead, `claude`'s and `opencode`'s entrypoints launch `main` with `--continue` (with a `|| <plain launch>` fallback for the first-ever boot), so waking resumes the conversation. Verified end to end: `docker stop` → visit → 200 in ~63s → the prior conversation is back in the pane. Do not add `--continue` to `HARNESS_LAUNCH_CMD` (dynamic slugs) — they share one `/workspace` and would all resume the same conversation.
- **Editing a bind-mounted single file doesn't reach the running container.** `Caddyfile`, `.env`, and `harnesses/base/ttyd-kbfix.html` are all mounted as individual files. Any edit that replaces the file (which is what the Edit/Write tools do) leaves the container bound to the old inode: `caddy reload` will keep serving the previous config and swear it's valid. Recreate/restart the container so the mount re-resolves — for the shared Caddy that means `docker compose restart caddy` in `/root/caddy-router`, not `make router-reload`.
- **`harnesses/base/ttyd-wrapper.sh` caches its generated index at `/run/ttyd-kbfix-index.html`**, which survives `docker restart` (writable layer, not tmpfs). It now rebuilds when the snippet is newer, but that check only exists in a rebuilt base image — after editing `ttyd-kbfix.html` on a stack running an older image, `rm -f /run/ttyd-kbfix-index.html` inside the container before restarting it.
- **Claude's harness needs >60s to boot** (its entrypoint registers ~26 MCP servers before it execs ttyd), which is why `COLD_START_TIMEOUT_S` defaults to 120. Lowering it back to 30 makes the first visit after an idle-stop 504 on a container that was coming up fine.
- **`gitleaks` runs in CI** (`.github/workflows/ci.yml` lint job) — if a new allowlist entry in `.gitleaks.toml` is ever needed, justify it with a comment; don't blanket-disable a rule.

## Common operations

```bash
# Regenerate/rotate all tokens
JWT_SECRET=$JWT_SECRET python3 scripts/generate-tokens.py    # or: make tokens-write

# Build base image first, then everything
docker compose --profile build-only build harness-base && docker compose build   # or: make build

# Start the always-on service (harnesses come up on demand)
docker compose up -d auth   # or: make up

# Manually stop/start one harness
docker compose stop harness-aider
docker compose up -d harness-aider

# Smoke-test every harness end to end
./scripts/test-all-harnesses.sh
./scripts/test-all-harnesses.sh aider crush     # subset
STOP_AFTER=1 ./scripts/test-all-harnesses.sh    # stop each when done

# Reload the external Caddy after editing caddy-snippet.txt into it
make router-reload
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `404 model does not exist` (Claude Code) | A model alias points at an unavailable model | Check `ANTHROPIC_DEFAULT_*_MODEL` / the auth service's free-model catalog |
| MCP tool calls silently ignored | Configured model doesn't support tool calling | Pick a tool-calling model; verify via the provider's `/models` endpoint |
| 401 on a subdomain | No/expired session cookie | Visit `https://<harness>.<domain>/?token=<jwt>` once. `docker compose logs auth \| grep "auth:"` names the exact reason for every rejection — no credential vs. rejected one |
| A raw `TOKEN_*` 403s on another subdomain | Its `harness` claim pins it to one type (`claude` + any `claude-<slug>`) | Expected. The *session* it mints is lab-wide under `SESSION_SCOPE=all`, so log in once anywhere and every subdomain incl. `files` opens |
| Terminal window is fresh after a break, conversation intact | The container was idle-stopped (tmux dies with it) and the CLI relaunched with `--continue` | Working as designed — see the idle-stop gotcha above |
| Waking a slept harness takes ~a minute | claude re-registers ~26 MCP servers before ttyd listens | Expected; `COLD_START_TIMEOUT_S=120` covers it. Trim `MCP_*` vars to speed it up |
| Terminal stuck on "Connection Closed" | Socket dropped and ttyd's single retry didn't take | Self-heals: `ttyd-kbfix.html` synthesizes the reconnect keypress, then reloads once after ~12s. If it persists, the container is genuinely down |
| `<harness>-<slug>` URL 429s | `MAX_INSTANCES_PER_HARNESS` reached | Let an idle slug time out, or raise the cap |
| Container never sleeps | `IDLE_TIMEOUT_MIN=0`, or a client still holds an open websocket | Idle sweep checks for a real TCP connection, not just `/verify` timestamps |
| Caddy cert resolution breaks for a harness subdomain | A static per-hostname block was added alongside the wildcard block | Remove it — see the gotcha above |
| All harnesses use the same model | Intended — one provider config drives all 11 | Change the provider block in `.env`, or run a second stack for comparison |

## References

- [Claude Code Best Practices](https://code.claude.com/docs/en/best-practices)
- [Claude Code Model Configuration](https://code.claude.com/docs/en/model-config)
- [Sablier — on-demand container lifecycle (design inspiration; not used directly)](https://github.com/acouvreur/sablier)
- [Aider: OpenAI-compatible endpoints](https://aider.chat/docs/llms/openai-compat.html)
- [gptme: Custom Providers](https://gptme.org/docs/custom-providers.html)
- [Crush: Custom Provider Config](https://github.com/charmbracelet/crush/blob/main/README.md)
