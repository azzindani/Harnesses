FROM harness-base:latest
# Pinned for reproducibility. Codex (>=0.84) speaks ONLY the OpenAI /responses
# API — chat-completions was removed — so the entrypoint points codex straight
# at OpenRouter's /responses-capable endpoint (not the auth proxy, which only
# implements /chat/completions). See entrypoint.sh.
RUN npm install -g @openai/codex@0.134.0
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
