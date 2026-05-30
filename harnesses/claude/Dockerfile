FROM harness-base:latest
# Install the latest Claude Code CLI.  npm layers are cached, so a plain rebuild
# would pin whatever version was first built.  Bump CLAUDE_CODE_REF (to any new
# value, e.g. a date) to bust the cache and pull the newest release:
#   docker compose build --build-arg CLAUDE_CODE_REF=$(date +%Y%m%d) harness-claude
ARG CLAUDE_CODE_REF=latest
RUN echo "claude-code ref: ${CLAUDE_CODE_REF}" \
    && npm install -g @anthropic-ai/claude-code@latest \
    && claude --version
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
