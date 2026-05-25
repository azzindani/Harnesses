FROM harness-base:latest
# No canonical "Pi" CLI exists on npm or PyPI as of build time — the
# `pi-agent` PyPI package is a Python *library*, not a CLI.  Ship a small
# self-contained `pi` script that mirrors the conventional Pi shape: read
# stdin/argv, call the configured OpenAI-compatible provider, stream the
# response.  Replace with the real Pi binary once you have one.
RUN pip install --break-system-packages --no-cache-dir openai==1.55.3

COPY pi.py /usr/local/bin/pi
RUN chmod +x /usr/local/bin/pi

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
CMD ["/entrypoint.sh"]
