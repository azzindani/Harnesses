#!/usr/bin/env python3
"""Launch the DuckDuckGo MCP server reachable by its docker service name.

The mcp SDK enables DNS-rebinding protection (Host-header allow-listing) which
rejects requests whose Host is the compose service name (`web-mcp:7070`).  The
harnesses_net network is private, so that protection adds no security here — we
disable it by overriding the FastMCP transport-security settings before the
Streamable-HTTP app is built.
"""
import sys

from mcp.server.transport_security import TransportSecuritySettings
from duckduckgo_mcp_server import server

# Built at import time as `mcp = FastMCP("ddg-search")`; override before main()
# constructs the streamable-http app.
server.mcp.settings.transport_security = TransportSecuritySettings(
    enable_dns_rebinding_protection=False
)

if __name__ == "__main__":
    if len(sys.argv) == 1:
        sys.argv += ["--transport", "streamable-http", "--host", "0.0.0.0", "--port", "7070"]
    server.main()
