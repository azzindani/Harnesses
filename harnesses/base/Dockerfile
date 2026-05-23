# Common base for ttyd+tmux harness containers. Per-harness images install
# their CLI on top of this and ship an entrypoint that wires NIM env vars.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget git tmux ttyd \
        python3 python3-pip python3-venv pipx \
        jq unzip xz-utils \
        build-essential \
        gnupg locales \
    && locale-gen C.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# Node 20 (used by claude-code, opencode, crush, qwencode, codex, droid)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# ttyd default port. OpenHands/Kilo override (different process).
EXPOSE 7681
