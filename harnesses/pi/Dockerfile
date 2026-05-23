FROM harness-base:latest
# Pi (also known as `pi-agent`) — install via npm.  Adjust the package name
# if upstream renames; the entrypoint expects the binary on $PATH as `pi`.
RUN npm install -g @pi-labs/pi || npm install -g pi-agent || true
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
