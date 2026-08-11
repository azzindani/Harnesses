# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/) — while the
major version is `0`, the public interface (env vars, compose service names,
Caddy routes) may still change between minor releases.

## [Unreleased]

### Added

- `harness-files`: a web-based file manager (`dufs`) at `files.<domain>`, giving read-write access to `project/`, `data/`, and `history/` through the same subdomain + JWT/cookie auth as every CLI harness. Always-on rather than on-demand. Considered `filebrowser/filebrowser` first but it announced its own archival (2026-09-01, no further security fixes) partway through integration, so switched to the actively-maintained `dufs` instead.

### Changed

- Token TTL widened from 30 to 360 days (`TOKEN_TTL_DAYS` in `auth/server.py`, `--days` default in `scripts/generate-tokens.py`) — 30 days was too easy to silently expire mid-use.

## [0.1.0] — 2026-07-13

First tagged release. Everything below was built and run against a live
single-operator deployment before being generalized into this repo.

### Added

- Docker Compose stack for 11 AI coding CLI harnesses (Claude Code, Aider,
  OpenCode, Crush, gptme, Goose, Plandex, Qwen Code, Codex CLI, Pi, Droid),
  each wrapped in `ttyd` + `tmux` behind a shared `harness-base` image.
- `auth/server.py`: a single FastAPI service handling JWT-gated per-subdomain
  login, on-demand container lifecycle (start on request, stop after
  `IDLE_TIMEOUT_MIN`), and a translating proxy in front of OpenRouter that
  serves a self-updating catalog of free tool-calling models with transparent
  fallback on rate-limit/deprecation.
- Provider-agnostic configuration: `PROVIDER_BASE_URL` / `PROVIDER_API_KEY` /
  `MODEL_NAME` (+ `PROVIDER_ANTHROPIC_URL`) drive all 11 harnesses, with
  ready-made `.env.example` blocks for OpenRouter, NVIDIA NIM,
  build.nvidia.com, Anthropic, OpenAI, Groq, Together.ai, DeepSeek, and local
  Ollama.
- Multiple simultaneous sessions per harness: `<harness>-<slug>` subdomains
  open an additional tmux+ttyd session inside that harness's existing
  container, capped by `MAX_INSTANCES_PER_HARNESS`, with `/pin` and `/unpin`
  to exempt a session from the `RETENTION_DAYS` cleanup sweep.
- One bind-mounted `./history/<harness>/` tree per harness for conversation
  history, independent of container/image lifecycle.
- Bundled `web-mcp` DuckDuckGo search/fetch MCP sidecar, plus optional
  external Folio MCP registration, wired into every harness that supports MCP.
- Browser-terminal ergonomics: in-page Ctrl+C/Ctrl+V copy-paste, a mobile key
  toolbar (Esc/Tab/Ctrl/Alt/Shift/Home/End/PgUp/PgDn/arrows), wheel/touch
  scroll bridged into alternate-screen TUIs via synthesized PageUp/PageDown,
  and a light "notepad" theme for Claude Code and OpenCode.
- `scripts/generate-tokens.py` and `scripts/test-all-harnesses.sh` for token
  rotation and end-to-end smoke testing.
- CI (`.github/workflows/ci.yml`): shellcheck, Python syntax + ruff, gitleaks
  secret scanning, `docker compose config` validation, and Caddyfile
  validation for `caddy-snippet.txt`.
- Apache-2.0 `LICENSE` and a minimal `CONTRIBUTING.md`.

### Changed

- Dynamic sessions moved from one container+volume per slug to sharing a
  single per-harness-type container (simpler, cheaper, matches how a real
  workspace is actually used).
- `openhands` and `kilocode` harnesses were dropped after failing to reach
  parity with the rest of the lab.

### Security

- Scrubbed a real domain that had leaked into committed files
  (`.env.example`, `auth/server.py`'s fallback default, `docker-compose.yml`,
  `caddy-snippet.txt`) back to the `lab.example.com` placeholder used
  everywhere else.
