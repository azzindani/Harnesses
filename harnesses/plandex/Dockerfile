FROM harness-base:latest
# plandex.ai/install.sh 404s in CI; use the GitHub release tarball.  Bump
# PLANDEX_VERSION as upstream releases new CLI builds:
#   https://github.com/plandex-ai/plandex/releases
ARG PLANDEX_VERSION=2.2.1
RUN curl -fsSL "https://github.com/plandex-ai/plandex/releases/download/cli%2Fv${PLANDEX_VERSION}/plandex_${PLANDEX_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin plandex \
    && chmod +x /usr/local/bin/plandex
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
