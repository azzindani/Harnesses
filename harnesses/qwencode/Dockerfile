FROM harness-base:latest
RUN npm install -g @qwen-code/qwen-code
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
