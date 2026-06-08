# DuckDuckGo web MCP — free, no API key. Provides `search` and `fetch_content`
# tools over Streamable HTTP so every harness can reach it by URL on the shared
# network (same pattern as the Folio MCP).
FROM python:3.12-slim
RUN pip install --no-cache-dir "duckduckgo-mcp-server>=0.3.0"
COPY run.py /run.py
EXPOSE 7070
# /run.py disables Host-header allow-listing so the service-name host works;
# FastMCP serves the Streamable HTTP endpoint at /mcp.
CMD ["python", "/run.py"]
