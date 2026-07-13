# Contributing

This started as a personal single-operator lab (see "What this is NOT" in
`README.md`) and is shared mainly as a reference/example. There's no formal
roadmap or maintenance commitment.

That said:

- **Bug reports and small fixes are welcome** — open an issue or a PR.
- **Before opening a PR:** run the checks CI runs — `shellcheck -S error` on
  `scripts/*.sh` and `harnesses/*/entrypoint.sh`, `ruff check --select=E,F`
  on the Python files, and `docker compose config -q` (with `.env.example`
  copied to `.env`) — see `.github/workflows/ci.yml` for the exact commands.
- **Never commit a real domain, IP, or secret.** Use the `lab.example.com`
  placeholder pattern already used throughout `.env.example`,
  `caddy-snippet.txt`, and `auth/server.py`.
- **Larger changes** (new harness, architecture changes to `auth/server.py`)
  are easier to discuss in an issue first, since this is still a young,
  single-maintainer project.

By contributing, you agree your contribution is licensed under this
project's Apache-2.0 license (see `LICENSE`).
