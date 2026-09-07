#!/usr/bin/env python3
"""Send every tool an argument name it does not declare, and see who notices.

This is r27's guard, checked on the deployed fleet. The probe is deliberately
ONLY the invented argument, with no other arguments at all, which makes it safe
to fire at every tool including the destructive ones: every required argument is
absent, so nothing can execute even where the guard is missing. The outcomes
stay distinguishable because enforce_known_arguments runs before argument
validation --

    guard installed  -> "<tool> does not take definitely_not_a_parameter"
    guard missing    -> pydantic's "Field required" for the real arguments
    guard missing AND the tool takes no required args -> success: true

## Two things this file used to get wrong

**It trusted a saved inventory.** The tool list came from a TSV built by an
earlier run, so a rebuild that added or renamed a tool would sweep a fleet that
no longer existed and still report a clean pass. It now reads `tools/list` at
the start of every run and sweeps what is actually listening.

**It judged the hint by its phrasing.** Whether a refusal named the tool's real
arguments was decided by `"accepts:" in hint` -- a word, not a fact. The same
mistake in the sibling dispatch probe hid two live defects for two rounds (see
FINDINGS_r28.md, round 29b). The hint is now checked against the argument names
the tool's own schema declares: at least one has to appear, matched as a whole
token so `path` cannot match inside `file_path`.

    python3 unknown_arg_sweep.py [out.tsv]

Reads tools/list and calls every tool once. Writes only the optional TSV.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ENV = "/root/Harnesses/.env"

# Contains no word any assertion here searches for: not "accepts", not the name
# of any argument on the fleet, and it is echoed back verbatim by the guard.
BOGUS = "definitely_not_a_parameter"

LABELS = [
    "browser", "data-basic", "data-ingest", "data-medium", "data-statistics",
    "data-transform", "data-visual", "data-workspace", "docs-edit", "docs-read",
    "filesystem", "math", "ml-advanced", "ml-basic", "ml-medium",
    "office-docx-basic", "office-docx-layout", "office-docx-new", "office-docx-tables",
    "office-pptx-basic", "office-pptx-design", "office-pptx-new",
    "office-xlsx-basic", "office-xlsx-charts", "office-xlsx-formulas", "office-xlsx-new",
]


def env(key: str) -> str:
    with open(ENV, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    return ""


def endpoint(label: str) -> tuple[str, str]:
    if label.startswith("docs-"):
        return f"{env('DOCS_MCP_BASE_URL')}/{label[5:]}/mcp", env("DOCS_MCP_TOKEN")
    if label.startswith("data-"):
        return f"{env('DATA_MCP_BASE_URL')}/{label[5:]}/mcp", env("DATA_MCP_TOKEN")
    if label.startswith("ml-"):
        return f"{env('ML_MCP_BASE_URL')}/{label[3:]}/mcp", env("ML_MCP_TOKEN")
    if label.startswith("office-"):
        return f"{env('OFFICE_MCP_BASE_URL')}/{label[7:]}/mcp", env("OFFICE_MCP_TOKEN")
    return {
        "filesystem": (env("FS_MCP_URL"), env("FS_MCP_TOKEN")),
        "math": (env("MATH_MCP_URL"), env("MATH_MCP_TOKEN")),
        "browser": (env("BROWSER_MCP_URL"), env("BROWSER_MCP_TOKEN")),
    }[label]


def post(url: str, tok: str, body: dict, sid: str = "", headers: bool = False) -> str:
    cmd = ["curl", "-s", "--max-time", "120", "-X", "POST", url,
           "-H", f"Authorization: Bearer {tok}",
           "-H", "Content-Type: application/json",
           "-H", "Accept: application/json, text/event-stream"]
    if sid:
        cmd += ["-H", f"mcp-session-id: {sid}"]
    if headers:
        cmd += ["-D", "-", "-o", "/dev/null"]
    cmd += ["-d", json.dumps(body)]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=180).stdout


def open_session(url: str, tok: str) -> str:
    raw = post(url, tok, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                          "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                                     "clientInfo": {"name": "unknown-arg-sweep", "version": "29"}}},
               headers=True)
    match = re.search(r"(?im)^mcp-session-id:\s*(\S+)", raw)
    if not match:
        return ""
    sid = match.group(1)
    post(url, tok, {"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    return sid


def payload(raw: str) -> dict | None:
    """Streamable HTTP delivers one JSON object per `data:` line."""
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("data:"):
            line = line[5:].strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None


def result_text(obj: dict) -> str:
    """A tool result arrives as the JSON *string* result.content[0].text."""
    try:
        return obj["result"]["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        return json.dumps(obj)


def tokens(text: str) -> set[str]:
    """Whole tokens, so `path` cannot match inside `file_path`."""
    return {t.lower() for t in re.findall(r"[A-Za-z0-9_]+", text)}


def classify(label: str, tool: str, declared: set[str], raw: str) -> dict:
    row = {"endpoint": label, "tool": tool, "verdict": "?", "error": "",
           "hint": "", "names_real_args": "", "declared": len(declared)}
    obj = payload(raw)
    if obj is None:
        row["verdict"] = "TRANSPORT"
        row["error"] = raw[:200].replace("\n", " ")
        return row
    if "error" in obj:
        row["verdict"] = "MCP_ERROR"
        row["error"] = json.dumps(obj["error"])[:200]
        return row
    text = result_text(obj)
    try:
        body = json.loads(text)
    except json.JSONDecodeError:
        body = {}
    if isinstance(body, dict):
        row["error"] = str(body.get("error", ""))[:300]
        row["hint"] = str(body.get("hint", ""))[:300]
        if body.get("success") is True:
            row["verdict"] = "IGNORED"
            return row

    blob = row["error"] or text[:300]
    if BOGUS in blob:
        row["verdict"] = "REFUSED"
    elif re.search(r"Field required|missing|required", blob, re.I):
        row["verdict"] = "NO_GUARD_VALIDATION"
    else:
        row["verdict"] = "REFUSED_OTHER"
    row["error"] = blob.replace("\n", " ")[:300]

    # Does the refusal name arguments this tool really has? Fact, not phrasing:
    # `"accepts:" in hint` was the old test, and it measured a colon.
    if not declared:
        row["names_real_args"] = "n/a"  # a tool with no arguments can name none
    else:
        named = declared & tokens(f"{row['error']} {row['hint']}")
        row["names_real_args"] = f"{len(named)}/{len(declared)}" if named else "NONE"
    return row


def sweep(label: str) -> list[dict]:
    url, tok = endpoint(label)
    sid = open_session(url, tok)
    if not sid:
        return [{"endpoint": label, "tool": "-", "verdict": "NO_SESSION", "error": "",
                 "hint": "", "names_real_args": "", "declared": 0}]

    obj = payload(post(url, tok, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)) or {}
    specs = obj.get("result", {}).get("tools", [])
    if not specs:
        return [{"endpoint": label, "tool": "-", "verdict": "NO_TOOLS", "error": "",
                 "hint": "", "names_real_args": "", "declared": 0}]

    rows = []
    for spec in specs:
        tool = spec["name"]
        declared = {k.lower() for k in ((spec.get("inputSchema") or {}).get("properties") or {})}
        body = {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                "params": {"name": tool, "arguments": {BOGUS: 1}}}
        raw = post(url, tok, body, sid)
        if re.search(r"session not found|Missing session ID|Bad Request", raw, re.I):
            sid = open_session(url, tok)
            raw = post(url, tok, body, sid)
        rows.append(classify(label, tool, declared, raw))
    return rows


def main() -> int:
    rows: list[dict] = []
    with ThreadPoolExecutor(max_workers=6) as pool:
        for future in [pool.submit(sweep, label) for label in LABELS]:
            rows.extend(future.result())
    rows.sort(key=lambda r: (r["endpoint"], r["tool"]))

    if len(sys.argv) > 1:
        with open(sys.argv[1], "w", encoding="utf-8") as fh:
            fh.write("endpoint\ttool\tverdict\tnames_real_args\terror\thint\n")
            for r in rows:
                fh.write(f"{r['endpoint']}\t{r['tool']}\t{r['verdict']}\t"
                         f"{r['names_real_args']}\t{r['error']}\t{r['hint']}\n")

    tally: dict[str, int] = {}
    for r in rows:
        tally[r["verdict"]] = tally.get(r["verdict"], 0) + 1
    print(f"{len(rows)} tools across {len({r['endpoint'] for r in rows})} endpoints, listed live")
    for verdict, count in sorted(tally.items(), key=lambda kv: -kv[1]):
        print(f"  {verdict:22} {count}")

    not_refused = [r for r in rows if r["verdict"] != "REFUSED"]
    if not_refused:
        print("\nnot REFUSED:")
        for r in not_refused:
            print(f"  {r['endpoint']}/{r['tool']}: {r['verdict']} -- {r['error'][:160]}")

    silent_hint = [r for r in rows if r["verdict"] == "REFUSED" and r["names_real_args"] == "NONE"]
    if silent_hint:
        print(f"\nREFUSED but named none of the tool's own arguments: {len(silent_hint)}")
        for r in silent_hint:
            print(f"  {r['endpoint']}/{r['tool']} ({r['declared']} declared): {r['hint'][:120]}")

    print()
    if not_refused or silent_hint:
        print(f"FAILED: {len(not_refused)} not refused; {len(silent_hint)} refused without naming a real argument")
        return 1
    print(f"ALL {len(rows)} tools refuse an argument they do not declare, and name ones they do")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
