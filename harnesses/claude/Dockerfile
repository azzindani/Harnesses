# Pipeline's binary, baked in so it runs over stdio on /workspace -- the files
# this harness edits.  Its remote endpoint is read_only and works on its own
# /work, so it can neither write nor see them.  The source is a locally built
# image (PIPELINE_MCP_IMAGE, e.g. pipeline:latest); unset, it falls back to
# harness-base, which has no binary, and the wildcard COPY below matches nothing
# -- BuildKit allows an empty match, so the harness builds without Pipeline.
ARG PIPELINE_MCP_IMAGE=harness-base:latest
FROM ${PIPELINE_MCP_IMAGE} AS pipeline

FROM harness-base:latest
# Install the latest Claude Code CLI.  npm layers are cached, so a plain rebuild
# would pin whatever version was first built.  Bump CLAUDE_CODE_REF (to any new
# value, e.g. a date) to bust the cache and pull the newest release:
#   docker compose build --build-arg CLAUDE_CODE_REF=$(date +%Y%m%d) harness-claude
ARG CLAUDE_CODE_REF=latest
RUN echo "claude-code ref: ${CLAUDE_CODE_REF}" \
    && npm install -g @anthropic-ai/claude-code@latest \
    && claude --version
COPY --from=pipeline /usr/local/bin/pipelin[e] /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
COPY statusline.py /opt/claude-statusline.py
CMD ["/entrypoint.sh"]
