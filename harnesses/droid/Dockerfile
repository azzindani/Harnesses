FROM harness-base:latest
RUN curl -fsSL https://app.factory.ai/cli | sh \
    && ln -sf /root/.factory/bin/droid /usr/local/bin/droid
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
