#!/usr/bin/env bash
# Round 29: does the DEPLOYED schema name its legal values?
#
# Round 28 censused all 244 tools and found 55 parameters whose whole job is to
# select behaviour, not one of which declared an `enum` -- so every legal value
# lived in prose, and a caller learned the spelling by burning a call. This
# checks the fix where it has to be true: in what `tools/list` actually returns
# from the running servers, not in the source.
#
#   ./verify_r29_enums.sh
#
# Reads nothing but tools/list. Writes nothing at all.

set -uo pipefail

exec python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys

ENV_FILE = "/root/Harnesses/.env"


def get(key: str) -> str:
    with open(ENV_FILE, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return ""


def endpoint(label: str) -> tuple[str, str]:
    if label.startswith("docs-"):
        return f"{get('DOCS_MCP_BASE_URL')}/{label[5:]}/mcp", get("DOCS_MCP_TOKEN")
    if label.startswith("data-"):
        return f"{get('DATA_MCP_BASE_URL')}/{label[5:]}/mcp", get("DATA_MCP_TOKEN")
    if label.startswith("ml-"):
        return f"{get('ML_MCP_BASE_URL')}/{label[3:]}/mcp", get("ML_MCP_TOKEN")
    if label.startswith("office-"):
        return f"{get('OFFICE_MCP_BASE_URL')}/{label[7:]}/mcp", get("OFFICE_MCP_TOKEN")
    return {
        "filesystem": (get("FS_MCP_URL"), get("FS_MCP_TOKEN")),
        "math": (get("MATH_MCP_URL"), get("MATH_MCP_TOKEN")),
        "browser": (get("BROWSER_MCP_URL"), get("BROWSER_MCP_TOKEN")),
    }[label]


LABELS = [
    "browser", "data-basic", "data-ingest", "data-medium", "data-statistics",
    "data-transform", "data-visual", "data-workspace", "docs-edit", "docs-read",
    "filesystem", "math", "ml-advanced", "ml-basic", "ml-medium",
    "office-docx-basic", "office-docx-layout", "office-docx-new", "office-docx-tables",
    "office-pptx-basic", "office-pptx-design", "office-pptx-new",
    "office-xlsx-basic", "office-xlsx-charts", "office-xlsx-formulas", "office-xlsx-new",
]

DISPATCH = re.compile(
    r"^(action|mode|method|agg_func|chart_type|how|direction|normalize|format|format_|task|model|"
    r"model_type|models|algorithm|op|test|test_type|period_unit|rule|validation_type|to|type_?|"
    r"output_format|location_mode|style)$"
)

# Parameters that correctly have no fixed list, each with the reason. A caller
# reading this file should be able to check the reason, not just trust it.
NO_ENUM_IS_CORRECT = {
    "office-docx-basic/append_text.style": "the .docx defines its own styles; resolve_style reads the real set",
    "office-docx-basic/insert_paragraph.style": "the .docx defines its own styles",
    "data-visual/generate_geo_map.location_mode": "plotly's set, auto-detected when omitted",
}


def post(url: str, tok: str, body: dict, sid: str = "", headers: bool = False) -> str:
    cmd = ["curl", "-s", "--max-time", "60", "-X", "POST", url,
           "-H", f"Authorization: Bearer {tok}",
           "-H", "Content-Type: application/json",
           "-H", "Accept: application/json, text/event-stream"]
    if sid:
        cmd += ["-H", f"mcp-session-id: {sid}"]
    if headers:
        cmd += ["-D", "-", "-o", "/dev/null"]
    cmd += ["-d", json.dumps(body)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=90).stdout


def tools_for(label: str) -> list[dict]:
    url, tok = endpoint(label)
    raw = post(url, tok, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                          "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                     "clientInfo": {"name": "verify-r29", "version": "29"}}}, headers=True)
    match = re.search(r"(?im)^mcp-session-id:\s*(\S+)", raw)
    if not match:
        return []
    sid = match.group(1)
    post(url, tok, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    raw = post(url, tok, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            line = line[5:].strip()
        if line.startswith("{"):
            return json.loads(line).get("result", {}).get("tools", [])
    return []


declared, undeclared, tools_seen = [], [], 0
for label in LABELS:
    for tool in tools_for(label):
        tools_seen += 1
        props = (tool.get("inputSchema") or {}).get("properties") or {}
        for param, spec in props.items():
            if not DISPATCH.match(param):
                continue
            if spec.get("type") == "array" and isinstance(spec.get("items"), dict):
                spec = spec["items"]
            key = f"{label}/{tool['name']}.{param}"
            (declared if "enum" in spec else undeclared).append((key, spec.get("enum")))

print(f"{tools_seen} tools on {len(LABELS)} endpoints")
print(f"dispatch parameters: {len(declared) + len(undeclared)}")
print(f"  naming their values: {len(declared)}")
print(f"  not naming them:     {len(undeclared)}")
print()
for key, values in sorted(declared):
    print(f"  {key:56} {', '.join(values)}")

unexplained = [k for k, _ in undeclared if k not in NO_ENUM_IS_CORRECT]
if undeclared:
    print("\nwithout an enum:")
    for key, _ in sorted(undeclared):
        why = NO_ENUM_IS_CORRECT.get(key)
        print(f"  {key:56} {why or '<-- UNEXPLAINED'}")

print()
if unexplained:
    print(f"FAILED: {len(unexplained)} dispatch parameter(s) still name no values")
    sys.exit(1)
print(f"ALL {len(declared)} dispatch parameters name their legal values on the deployed servers")
PY
