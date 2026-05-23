# Kilo Code is a VS Code extension — we ship it inside code-server (browser
# VS Code) and configure the OpenAI-compatible provider at first launch.
FROM lscr.io/linuxserver/code-server:latest

# linuxserver/code-server listens on 8443 by default; we expose 8080 to keep
# all harness ports in the same shape (HARNESS_PORT_OVERRIDES knows about it).
ENV PORT=8080 \
    DEFAULT_WORKSPACE=/workspace

COPY entrypoint.sh /custom-cont-init.d/10-kilocode-bootstrap.sh
RUN chmod +x /custom-cont-init.d/10-kilocode-bootstrap.sh
