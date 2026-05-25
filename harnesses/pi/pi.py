#!/usr/bin/env python3
"""Minimal 'pi' CLI shim — sends a prompt to the configured OpenAI-compatible
provider and streams the response.  Reads config from ~/.pi/agent/models.json
or PROVIDER_* env vars.

Usage:
    pi "your prompt"
    echo "your prompt" | pi
    pi              # interactive, one prompt per blank-line-terminated block
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from openai import OpenAI

CONFIG_PATH = Path.home() / ".pi" / "agent" / "models.json"


def resolve_config() -> tuple[str, str, str]:
    """Return (base_url, api_key, model).  models.json wins over env."""
    if CONFIG_PATH.exists():
        cfg = json.loads(CONFIG_PATH.read_text())
        default = cfg.get("default", "")
        prov_key, _, model = default.partition("/")
        prov = cfg["providers"][prov_key]
        return prov["base_url"], prov["api_key"], model or prov.get("models", [""])[0]
    return (
        os.environ["PROVIDER_BASE_URL"],
        os.environ["PROVIDER_API_KEY"],
        os.environ["MODEL_NAME"],
    )


def ask(client: OpenAI, model: str, prompt: str) -> None:
    stream = client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": prompt}],
        max_tokens=2048,
        stream=True,
    )
    for chunk in stream:
        delta = (chunk.choices[0].delta.content or "") if chunk.choices else ""
        if delta:
            sys.stdout.write(delta)
            sys.stdout.flush()
    sys.stdout.write("\n")


def main() -> None:
    base_url, api_key, model = resolve_config()
    client = OpenAI(base_url=base_url, api_key=api_key)

    if len(sys.argv) > 1:
        ask(client, model, " ".join(sys.argv[1:]))
        return
    if not sys.stdin.isatty():
        ask(client, model, sys.stdin.read())
        return
    print(f"pi · {model} via {base_url}\n(Enter a blank line on its own to send; Ctrl-D to quit.)")
    while True:
        try:
            lines: list[str] = []
            while True:
                line = input("> " if not lines else "  ")
                if not line:
                    break
                lines.append(line)
            if not lines:
                continue
            ask(client, model, "\n".join(lines))
        except (EOFError, KeyboardInterrupt):
            print()
            return


if __name__ == "__main__":
    main()
