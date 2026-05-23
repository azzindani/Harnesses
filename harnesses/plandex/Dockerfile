FROM harness-base:latest
RUN curl -fsSL https://plandex.ai/install.sh | bash
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
