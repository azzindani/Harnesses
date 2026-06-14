#!/usr/bin/env python3
"""Generate per-harness JWTs.

Usage:
    JWT_SECRET=... python3 scripts/generate-tokens.py [--days 30]

Prints `TOKEN_<NAME>=<jwt>` lines to stdout. Paste into .env (or pipe through
`sponge` / `envsubst`).  Re-running rotates everything — invalidates any
previously issued token for the same harness.
"""
from __future__ import annotations

import argparse
import os
import sys
import time

try:
    import jwt  # PyJWT
except ImportError:
    sys.stderr.write("Missing dependency: pip install PyJWT\n")
    sys.exit(1)


HARNESSES = [
    "claude",
    "aider",
    "opencode",
    "crush",
    "gptme",
    "goose",
    "plandex",
    "qwencode",
    "codex",
    "pi",
    "droid",
]


def env_key(harness: str) -> str:
    return "TOKEN_" + harness.upper().replace("-", "_")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--days", type=int, default=30, help="JWT lifetime (default 30)")
    parser.add_argument(
        "--only",
        nargs="*",
        choices=HARNESSES,
        help="Only emit tokens for the listed harnesses",
    )
    args = parser.parse_args()

    secret = os.environ.get("JWT_SECRET")
    if not secret or secret == "replace-me-with-a-long-random-string":
        sys.stderr.write("Set JWT_SECRET (a long random string) before running.\n")
        sys.exit(2)

    now = int(time.time())
    exp = now + args.days * 86400
    targets = args.only or HARNESSES
    for harness in targets:
        token = jwt.encode(
            {"harness": harness, "iat": now, "exp": exp},
            secret,
            algorithm="HS256",
        )
        print(f"{env_key(harness)}={token}")


if __name__ == "__main__":
    main()
