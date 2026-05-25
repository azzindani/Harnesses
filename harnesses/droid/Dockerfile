FROM harness-base:latest
# The installer drops the binary at $HOME/.local/bin/droid (not ~/.factory/bin).
RUN curl -fsSL https://app.factory.ai/cli | sh \
    && ln -sf /root/.local/bin/droid /usr/local/bin/droid
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
