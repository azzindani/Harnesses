# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/) — while the
major version is `0`, the public interface (env vars, compose service names,
Caddy routes) may still change between minor releases.

## [0.2.0] — 2026-09-07

### Added

- **`scripts/sweep/run_all_checks.sh`** — every checker in the directory against
  the deployed fleet in one pass (~90s), quoting each one's own tally and
  checking the `Ad_Data.csv` md5 either side. Exits non-zero if any fails.
- **`scripts/sweep/unknown_arg_sweep.py`** — replaces the scratchpad
  `direct_sweep.py`. Reads `tools/list` at the start of every run rather than
  trusting a saved inventory, and checks the refusal against the argument names
  the tool's own schema declares.
- **`scripts/sweep/dispatch_probe.py`** — sends every dispatch parameter a value
  it cannot mean and checks the refusal against the `enum` the deployed schema
  publishes.

### Fixed — checkers that were reporting their own condition as the fleet's

- **The dispatch probe judged phrasing, not fact.** It decided whether a refusal
  named its legal values by searching for words like "allowed" and "valid". That
  filed `append_text`'s 27-style list as naming nothing, and passed any message
  containing "Invalid" — because "Invalid" contains "valid". Two live defects sat
  under that green line for two rounds.
- **`verify_r28_fixes.sh` and `verify_r27_fixes.sh` grepped the whole envelope**
  for a token that only means something inside a refusal. Every tool echoes the
  arguments it was given, so `has "$R" 'agg_func'` matched a success too. Both
  now read the refusal's own words and require a refusal to have happened.
- **`verify_n1.sh` assumed fixtures a past round had made by hand.** They were
  gone, so all 31 assertions answered "File not found" and the run read as 28
  regressions. It builds its own now, owns them to the server's uid, and decodes
  the result once in `call()` instead of asking 31 patterns to spell an escaped
  quote.
- **`verify_r24_shipped.sh` called `time_series_analysis` with `value_column`**,
  since renamed to `value_columns`, so the argument guard refused the name
  before `dayfirst` was ever read.
- **`verify_vocab.sh`** — two patterns missing the escaped-quote allowance the
  rest of the file already uses.

---

## [0.2.0] — 2026-09-07 · part two: the sweep harness

### Added

- **`SWEEP_MCP_DISABLED`** — the sweep container's own hidden-mount list, empty
  by default. `.env`'s `MCP_DISABLED` scopes the *personal* harness, and the
  sweep must never follow it, but empty also registered `folio`, which is not
  one of the repos under test. Set to `folio` for rounds 24-26, leaving 27
  servers: the 26 endpoints plus the `web` sidecar.
- **`scripts/sweep/monitor_round.sh`** — watches a round and writes one status
  line, exiting when the round ends, the driver dies, or nothing completes for
  ~48 minutes. `setsid`-detached like the driver, because a Claude Code
  background task gets reaped by the host's low-memory guard while the detached
  driver beside it never notices — that happened twice in one round. The log is
  an argument: round 25 needed three of these in a day, one per provider switch,
  and sed-copying the script per log left four near-identical files free to
  drift apart.
- **`AXES[24]`, `[25]`, `[26]`** — "believe the description", the same axis
  re-asked where the descriptions had changed, and "the call that failed and
  wrote anyway".
- **`verify_r24_shipped.sh`, `verify_r25_fixes.sh`** — the per-round direct-MCP
  checks, and round 25 is the argument for them: re-asking the axis flipped 12
  of 16 fixed tools from BROKEN to HELD, but every `dayfirst` tool was called
  with the *valid* value, so the refusal the fix added was never exercised. A
  model picks the branch the fix did not change.
- **`descriptions_r24.tsv` / `_r25.tsv`** — every tool's description frozen at
  launch, as a grading key. It earned itself on round 24's first four phases,
  catching a model that had invented a per-op description for `fs_write` and
  then scored its own inventions BROKEN.

### Changed

- `scripts/sweep/README.md` documents the `harness-sweep` container, both of its
  variables, how the three providers fail differently when their free quota runs
  out, and why a model switch needs a new session rather than new config.
- `AXES[24]`'s `columns_ops` names the *tool's* description rather than asking
  for one per op. Six File_System tools carry ~50 ops behind one 70-character
  sentence each, and asking for "the sentence that covers this op" produced
  fabrications.


## [0.1.1] — 2026-09-01

### Added

- `harness-files`: a web-based file manager (`dufs`) at `files.<domain>`, giving read-write access to `project/`, `data/`, and `history/` through the same subdomain + JWT/cookie auth as every CLI harness. Always-on rather than on-demand. Considered `filebrowser/filebrowser` first but it announced its own archival (2026-09-01, no further security fixes) partway through integration, so switched to the actively-maintained `dufs` instead.
- The self-hosted `MCP_*` tool servers are registered on every MCP-capable harness, and `MCP_DISABLED` lets one harness leave out servers it is not meant to see — whole entry names (`browser`, `folio`) or a repo prefix (`office`, which removes all eleven of its mounts).
- `scripts/sweep/`: the coverage-sweep harness that drives a harness's own agent through every tool of every `MCP_*` repo — plan generator, tmux driver, a ledger written as the round runs rather than after it, and model-free verifiers (`verify_n1.sh`, `verify_vocab.sh`, `verify_artifacts.py`) that re-check a round's fixes without spending a token.
- `harness-sweep`: the sweep gets its own `opencode`, its own subdomain and an empty `opencode.db`, so it can only ever reach the anonymous free tier and never a paid subscription.
- Containers get an `init`, so harness zombies are reaped; a real session cookie is minted and slid across every lab subdomain.

### Changed

- Token TTL widened from 30 to 360 days (`TOKEN_TTL_DAYS` in `auth/server.py`, `--days` default in `scripts/generate-tokens.py`) — 30 days was too easy to silently expire mid-use.
- The `web-mcp` and `auth` sidecars moved to Python 3.14.
- 30 minutes is now the documented idle default before a harness sleeps.

### Security

- Every agent was being handed the key that signs every session. It no longer is.

### Fixed

- The stuck-terminal watchdog could cancel its own reload.
- Harnesses sleep again, and resume the conversation on wake.

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
