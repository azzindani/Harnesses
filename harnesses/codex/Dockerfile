FROM harness-base:latest
RUN npm install -g @openai/codex
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
