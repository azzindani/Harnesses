FROM harness-base:latest
# Pinned: qwen self-updates at launch otherwise, and the in-session npm install
# leaves the TUI blank/unresponsive ("can't type") while it runs. We pin the
# version here AND disable auto-update in settings.json (see entrypoint.sh).
RUN npm install -g @qwen-code/qwen-code@0.17.1
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
