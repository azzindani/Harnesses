FROM harness-base:latest
ENV PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
RUN pipx install gptme
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
