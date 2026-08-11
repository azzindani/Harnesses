# Harnesses — Multi-Agent Coding Lab

[![CI](https://github.com/azzindani/Harnesses/actions/workflows/ci.yml/badge.svg)](https://github.com/azzindani/Harnesses/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
[![Status: experimental](https://img.shields.io/badge/status-v0.1.0%20%E2%80%94%20experimental-orange.svg)](CHANGELOG.md)

> **Status:** `v0.1.0` — experimental / example project, actively evolving. Expect breaking changes between `0.x` releases; see [`CHANGELOG.md`](CHANGELOG.md).

A personal lab for running and comparing multiple AI coding CLI agents ("harnesses") side by side — Claude Code, Aider, OpenCode, Crush, gptme, Goose, Plandex, Qwen Code, Codex CLI, Pi, and Droid — all backed by the same model provider, each reachable from a browser terminal on its own subdomain, with containers that sleep when idle and wake on first request.

> Every domain shown below is a placeholder (`lab.example.com`). Replace it with your own.

## What this is

- A single Docker Compose stack that runs 11 different coding-agent CLIs, each wrapped in `ttyd` (browser terminal) + `tmux` (session persistence) inside its own container.
- One shared model provider config (OpenAI-compatible and/or Anthropic-compatible endpoint) feeds all 11 — swap the provider once, every harness picks it up.
- A small FastAPI **auth/lifecycle service** (`auth/`) does three jobs at once:
  1. **JWT-gated per-subdomain login** — one token per harness, all stored in `.env`.
  2. **Sablier-lite container lifecycle** — starts a harness container on first request, stops it after an idle timeout, so nothing but the always-on services costs RAM when the lab isn't in use.
  3. **A translating proxy** in front of OpenRouter that (a) serves a self-updating catalog of *free, tool-calling* models to each harness's own model picker, (b) transparently rolls a request over to another free model on rate-limit/deprecation, and (c) translates Anthropic's `/v1/messages` wire format to OpenAI `/v1/chat/completions` for the two harnesses (Claude Code, Droid) that speak Anthropic natively but whose target models only support OpenAI-shaped tool calling.
- A shared, external Caddy reverse proxy (not part of this repo) terminates TLS and routes each subdomain in.

## What this is NOT

- Not a way to get Anthropic's real Claude models for free — you get the *harness* (the CLI/workflow), backed by whatever model you actually configure (by default, free tool-calling models on OpenRouter).
- Not multi-tenant / public-facing — it's a single-operator lab with one shared JWT secret and one shared model budget.

## Architecture

```
Browser
  │
  ▼
Shared Caddy reverse proxy (external to this repo, owns TLS/ports 80+443)
  │
  ├── on-demand TLS "ask" gate ──► harnesses-auth:/ask  (is this hostname ours?)
  │
  └── forward_auth ──► harnesses-auth:/verify
        │                  │
        │                  ├─ validates the JWT cookie
        │                  ├─ starts the target container if it's stopped
        │                  ├─ for a dynamic "<harness>-<slug>" hostname, docker-execs
        │                  │  an extra tmux+ttyd session into the SAME base container
        │                  └─ returns "X-Harness-Upstream: harness-<type>:<port>"
        │
        └── reverse_proxy {that header} ──► harness-<type> container, port 7681..7686
                                                  │
                                          ttyd (browser terminal)
                                                  │
                                          tmux ("main" + any extra sessions)
                                                  │
                                          the actual CLI (claude / aider / opencode / …)
```

Always-on: the shared Caddy router + `harnesses-auth`. Everything else (the 11 harness containers, `plandex-server`+`plandex-postgres`, `web-mcp`) starts on demand and stops after `IDLE_TIMEOUT_MIN` minutes of no connected client.

## Harnesses

| Harness | Protocol | Config file | Notes |
|---|---|---|---|
| **Claude Code** | Anthropic (`/v1/messages`) | env vars | via the auth service's `/anthropic` translating proxy |
| **Droid** (Factory CLI) | Anthropic-shaped, OpenAI-compat model | `~/.factory/settings.json` | BYOK custom model, non-interactive-friendly |
| **Aider** | OpenAI (`/v1/chat/completions`) | env vars | |
| **OpenCode** | OpenAI-compat | `config.json` + `tui.json` + custom theme file | see theming notes below |
| **Crush** | OpenAI-compat | `crush.json` (rendered into `/workspace`) | unsets `OPENAI_*` env so its own provider config wins |
| **gptme** | OpenAI-compat | `config.toml` | |
| **Goose** | OpenAI-compat | `config.yaml` | telemetry consent prompt disabled at boot |
| **Plandex** | OpenAI-compat | custom model pack + `custom-models.json` | self-hosted Plandex server (`plandex-server` + Postgres), no cloud account |
| **Qwen Code** | OpenAI-compat | `settings.json` | auto-updater disabled (breaks the TUI mid-session otherwise) |
| **Codex CLI** | OpenAI `/responses` API | `config.toml` | bypasses the auth-service proxy — talks straight to the provider, so it doesn't get the free-model fallback the others do |
| **Pi** | OpenAI-compat | `~/.pi/agent/models.json` | stateless — no persisted conversation history |

> Only Claude Code and OpenCode are actively run day to day; the other 9 harness containers are stopped (not removed from `docker-compose.yml`) to save RAM/storage. Any of them comes back with `docker compose --profile on-demand up -d harness-<name>` — their images rebuild from the committed Dockerfiles and their history (see below) was never deleted.

Every harness that supports MCP (all but Aider, Plandex, Pi) registers optional remote servers the same env-var-gated way: **Folio** and **web search/fetch** (bundled DuckDuckGo sidecar, no key), plus the 6 self-hosted `azzindani/MCP_*` tool servers — **Math**, **Browser** (real browser automation, not the DuckDuckGo sidecar), **File_System**, **Machine_Learning**, **Data_Analyst**, and **Microsoft_Office**. The latter three mount several sub-servers each with no single unified endpoint, so every sub-server is registered individually (`ml-basic`, `data-workspace`, `office-pptx-design`, etc.) — up to 26 MCP server connections and ~225 extra tools when all are configured. Each pair of `..._URL`/`..._TOKEN` vars is independent — leave any blank to skip that repo.

## Quick start

1. **Copy env and fill in your provider:**
   ```bash
   cp .env.example .env
   ```
   `.env.example` documents several ready-made provider blocks (OpenRouter, NVIDIA NIM, build.nvidia.com, Anthropic, OpenAI, Groq, Together.ai, DeepSeek, local Ollama) — uncomment one. The only hard requirement for agentic use is that the chosen model supports tool/function calling:
   ```bash
   curl -H "Authorization: Bearer $PROVIDER_API_KEY" $PROVIDER_BASE_URL/models
   ```

2. **Set your domain and generate tokens:**
   ```bash
   # in .env
   HARNESS_BASE_DOMAIN=lab.example.com
   JWT_SECRET=$(openssl rand -hex 32)
   ```
   ```bash
   JWT_SECRET=$JWT_SECRET python3 scripts/generate-tokens.py
   ```
   Paste the printed `TOKEN_<NAME>=...` lines into `.env`. (The auth service will also auto-fill any missing/expired token at startup and log a ready-to-use login URL per harness — `docker logs harnesses-auth`.)

3. **DNS:** point a wildcard `*.lab.example.com` A record at your VPS. A single wildcard record covers every base harness *and* every dynamic session slug (see below) — you never register a subdomain per session.

4. **Build the images** (base image first, everything else depends on it):
   ```bash
   docker compose --profile build-only build harness-base
   docker compose build
   ```

5. **Start the always-on services:**
   ```bash
   docker compose up -d auth
   ```
   Harness containers under the `on-demand` profile start automatically on first authenticated request — you don't `docker compose up` them yourself.

6. **Log in:** visit `https://claude.lab.example.com/?token=<TOKEN_CLAUDE>` (or any harness). First visit sets a 360-day cookie scoped to the whole base domain, so logging in once on any subdomain unlocks every other harness too.

## Multiple simultaneous sessions per harness

Visiting `https://<harness>-<slug>.lab.example.com/?token=<jwt>` (any existing token for that harness type works, not just an exact match) opens an **additional, independent, simultaneously-usable session** — its own tmux window and its own `ttyd` process on its own port — inside that harness's *single* base container, sharing its one `/workspace`. It is deliberately **not** a separate container: the goal is more terminals into the same project, not isolated sandboxes.

- Up to `MAX_INSTANCES_PER_HARNESS` (default `5`) concurrent extra sessions per harness type, on ports `7682`–`7686`.
- Each slug's session and port are stable across reconnects; visiting the same slug again reattaches to the same tmux window.
- `/pin` and `/unpin` (e.g. `https://claude-blog.lab.example.com/pin`) exempt a session from the `RETENTION_DAYS` auto-cleanup sweep.
- Because every session of one harness type shares that one container, idle-stop is all-or-nothing: the container only stops once *every* session on it (base and every slug) has had no connected client for `IDLE_TIMEOUT_MIN`. A dynamic session's tmux window doesn't survive a container stop — it's recreated fresh the next time that slug is visited (the CLI's own conversation history, where a harness persists one, is unaffected — only the terminal window itself is momentarily gone).

## File management

`https://files.lab.example.com/?token=<TOKEN_FILES>` gives you a web-based file browser over `project/`, `data/`, and `history/` — read/write (browse, upload, download, delete, search, download-as-archive) — using the *exact same* subdomain + JWT/cookie auth as every CLI harness above, not a separate login. It's backed by [dufs](https://github.com/sigoden/dufs), a small always-on service rather than an on-demand one: it's lightweight and has no per-visitor terminal state worth idle-stopping, so (unlike the CLI harnesses) it doesn't sleep and there's no cold-start delay.

Like `ttyd` itself, `dufs` has no login of its own here — Caddy's `forward_auth` already gates every request before it reaches the container, so anyone with a valid `harness_session` cookie (from logging into *any* subdomain with the master token) or a `files`-scoped token has full read-write access to all three directories. Treat it accordingly: it's exactly as sensitive as shell access to any other harness.

## Session history & storage

Every harness that persists conversations writes into `./history/<harness>/` — one bind-mounted directory tree on the host, not a separate opaque Docker volume per harness. `docker-compose.yml` mounts the relevant subdirectory into each container at the path that harness expects (e.g. `./history/claude:/root/.claude`, `./history/codex:/root/.codex`, `./history/plandex/db:/var/lib/postgresql/data`). Practical implications:

- **One place to back up:** `tar czf backup.tar.gz history/` captures every harness's entire conversation history in one shot.
- **Survives everything except deleting it:** container recreate, image rebuild, `docker compose down`, even `docker volume prune` — none of these touch it, because it's a plain host directory, not a Docker-managed volume. Only `rm -rf history/<harness>` (or the whole tree) destroys it, same as any other file on disk.
- **Config is not history:** each harness's config files (provider settings, MCP registration, etc.) are re-seeded by `entrypoint.sh` on every boot and are *not* in `./history/` — only conversation/session data (transcripts, chat DBs, prompt history) lives there. Pi has nothing here since it's stateless (no persisted conversations to begin with).
- **Never treat these directories as scratch.** `history/claude`, `history/aider`, `history/crush`, etc. hold real conversation history, not disposable build output — do not `rm -rf` them during a "clean unused files" pass.

## Terminal theming

Two of the eleven harnesses (Claude Code, OpenCode) ship a light "notepad" theme (`#ffffff` background) instead of `ttyd`'s plain dark default — set both at the `ttyd`/xterm.js layer (the actual background painter) and in the CLI's own theme config (Claude Code's `settings.json.theme`, OpenCode's custom theme file). Dynamic sessions inherit whichever theme (or lack of one) their harness type's base session uses, so they always match rather than silently falling back to a different look.

## Copy/paste and scrolling in the browser terminal

`tmux.conf` runs with `mouse off` on purpose: it leaves the mouse to the browser, so a plain drag makes a native browser text selection that `ttyd-kbfix.html` auto-copies to your OS clipboard (reliable — happens inside the drag gesture, unlike tmux's own OSC 52 copy, which browsers silently drop outside a user gesture). Ctrl+C/Ctrl+V and a mobile 📋 panel (tap to view/select/copy the visible text) work the same way on both desktop and touch.

Claude Code and OpenCode run in the terminal's alternate-screen buffer (like `vim`/`htop`), which by spec has no scrollback of its own — neither tmux's `history-limit` nor xterm.js's local buffer apply there. Instead, both apps manage their own scrollable transcript, driven by real key input (PageUp/PageDown). On wheel-scroll or touch-drag (only while on the alternate screen), `ttyd-kbfix.html` synthesizes a real PageUp/PageDown `KeyboardEvent` and dispatches it at `term.textarea` — the same element xterm.js itself listens on for physical typing, so it flows through the identical path a real keypress would. (`term.input()` isn't exposed on this ttyd build's xterm.js — gated behind the "proposed API" flag — and `term.paste()` strips the ESC byte, so neither can carry a raw escape sequence; both were ruled out with a real headless-browser test before landing on the KeyboardEvent approach.) A plain shell prompt (normal buffer) is left alone, so xterm.js's default local scrollback still works there as-is.

On touch devices, a fixed bottom toolbar (Esc, Tab, Ctrl, Alt, Shift, Home, End, PgUp, PgDn, arrows — Termius/Termux-style) fills in keys a mobile on-screen keyboard doesn't have. Ctrl/Alt/Shift are one-shot sticky toggles: tap to arm, then the next keypress (physical or another toolbar tap) gets that modifier merged in and the toggle releases itself.

## Environment variables

See `.env.example` for the full, commented list. Highlights beyond the provider block:

| Var | Purpose |
|---|---|
| `HARNESS_BASE_DOMAIN` | the base domain every harness subdomain lives under |
| `JWT_SECRET` | signs every per-harness token; rotating it invalidates all of them instantly |
| `IDLE_TIMEOUT_MIN` | minutes of no connected client before a container is stopped (`0` disables) |
| `RETENTION_DAYS` | days of inactivity before an unpinned dynamic session is torn down |
| `MAX_INSTANCES_PER_HARNESS` | cap on concurrent dynamic sessions per harness type (`0` = unlimited) |
| `TOKEN_<NAME>` | per-harness JWT (auto-filled by the auth service if left blank) |
| `FREE_FALLBACK` / `FREE_REQUIRE_TOOLS` | OpenRouter free-model catalog/fallback behavior |
| `FOLIO_MCP_URL` / `FOLIO_MCP_TOKEN` | optional external Folio MCP server |
| `WEB_MCP_URL` | the bundled web-search MCP sidecar (on by default, no key) |
| `MATH_MCP_URL` / `..._TOKEN` | optional MCP_Math server |
| `BROWSER_MCP_URL` / `..._TOKEN` | optional MCP_Web_Browser server (real browser automation, distinct from the `web` DuckDuckGo sidecar) |
| `FS_MCP_URL` / `..._TOKEN` | optional MCP_File_System server |
| `ML_MCP_BASE_URL` / `..._TOKEN` | optional MCP_Machine_Learning server — 3 sub-servers registered as `ml-basic`/`ml-medium`/`ml-advanced` |
| `DATA_MCP_BASE_URL` / `..._TOKEN` | optional MCP_Data_Analyst server — 7 sub-servers registered as `data-<name>` |
| `OFFICE_MCP_BASE_URL` / `..._TOKEN` | optional MCP_Microsoft_Office server — 11 sub-servers registered as `office-<name>` |

`.env` is gitignored — never commit it. Commit changes to `.env.example` (placeholders only) instead.

## Common operations

```bash
# Regenerate/rotate all tokens
JWT_SECRET=$JWT_SECRET python3 scripts/generate-tokens.py

# Manually stop/start a specific harness
docker compose stop harness-aider
docker compose up -d harness-aider

# Smoke-test every harness end to end (mints a token, wakes the container,
# checks the configured provider is reachable, checks the CLI process is alive)
./scripts/test-all-harnesses.sh
./scripts/test-all-harnesses.sh aider crush     # just a subset
STOP_AFTER=1 ./scripts/test-all-harnesses.sh    # stop each container when done

# Tail logs (auth service logs every harness's login URL at startup)
docker logs -f harnesses-auth

# Rebuild after changing base image or any entrypoint
docker compose --profile build-only build harness-base
docker compose build harness-<name>
docker compose up -d --force-recreate harness-<name>
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `404 model does not exist` (Claude Code) | A model alias still points at an unavailable model | Check `ANTHROPIC_DEFAULT_*_MODEL` / the auth service's free-model catalog |
| MCP tool calls silently ignored | Configured model doesn't support tool calling | Pick a tool-calling model; verify via the provider's `/models` endpoint |
| 401 on a subdomain | No/expired session cookie | Visit `https://<harness>.<domain>/?token=<jwt>` once |
| Token works on the wrong subdomain | JWT `harness` claim doesn't match | Each token is pinned to one harness *type* (works on `claude` and any `claude-<slug>`), not across harnesses |
| A `<harness>-<slug>` URL 429s | `MAX_INSTANCES_PER_HARNESS` reached for that type | Let an idle slug time out, or raise the cap |
| Container never sleeps | `IDLE_TIMEOUT_MIN=0`, or a client still holds an open websocket | Check the value; the idle sweep reads `/proc/net/tcp` for a real connection, not just `/verify` timestamps |
| All harnesses use the same model | Intended — one provider config drives all 11 | Change `MODEL_NAME`/provider in `.env`, or run a second stack for comparison |

## Project layout

```
.
├── .env.example              # documented provider + auth config, no secrets
├── docker-compose.yml         # every service; the 11 CLI harness-* gated behind the on-demand profile (harness-files is always-on)
├── LICENSE                    # Apache-2.0
├── CHANGELOG.md               # notable changes per release
├── CONTRIBUTING.md            # how to send a PR
├── auth/
│   ├── server.py              # JWT gate, container lifecycle, free-model proxy
│   └── Dockerfile
├── scripts/
│   ├── generate-tokens.py     # mint/rotate per-harness JWTs
│   └── test-all-harnesses.sh  # end-to-end smoke test
├── harnesses/
│   ├── base/                  # shared Ubuntu+tmux+ttyd image every harness builds on
│   │   ├── Dockerfile
│   │   ├── new-session.sh     # spawns an extra tmux+ttyd session inside an already-running container
│   │   ├── ttyd-wrapper.sh     # injects in-page copy/paste into ttyd's UI
│   │   └── tmux.conf
│   └── <name>/
│       ├── Dockerfile
│       └── entrypoint.sh      # writes that CLI's config, launches tmux + ttyd
├── web-mcp/                   # bundled DuckDuckGo search/fetch MCP sidecar
├── project/                   # shared codebase, mounted at /workspace in every harness
├── data/                      # shared datasets, mounted at /workspace/data
└── history/                   # every harness's session history, one bind-mounted tree (see above)
    ├── claude/
    ├── opencode/{state,hist}/
    ├── plandex/{db,files}/
    └── <name>/...
```

The reverse proxy in front of all of this (TLS, on-demand certificate issuance, per-hostname routing) is a shared Caddy instance that lives **outside** this repo, since it also fronts other, unrelated projects on the same host. This repo only owns everything behind it.
