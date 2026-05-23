FROM harness-base:latest
RUN curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh \
        | CONFIGURE=false bash \
    && mv /root/.local/bin/goose /usr/local/bin/goose
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
