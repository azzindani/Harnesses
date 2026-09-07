#!/usr/bin/env python3
"""Send every dispatch parameter a value it cannot mean, and see who notices.

The r27 guard catches a wrong argument NAME. This is the other half: a wrong
VALUE on a parameter whose only job is to select behaviour. A server that
refuses and names the legal values is correct; one that returns success:true has
silently done something other than what was asked -- round 28's finding 1, where
`check_outliers(method="zscore")` reported "no outliers" on a column holding
2,178 of them.

## Why the classifier is written the way it is

The first version of this probe decided whether a refusal named its legal values
by looking for words like "allowed", "one of", "valid". That was a sniff at
phrasing, and it lied in both directions:

  * FALSE ALARM -- `append_text` answers a bad style with "Styles here include:
    Normal, Body Text, Heading 1, ..." (27 of them). It names the set about as
    well as a message can, and matched not one keyword, so the probe reported it
    as naming nothing.

  * FALSE PASS -- the refusal test included `"nvalid" in blob` and the naming
    test included `"valid" in probe_free`. Every message containing the single
    word "Invalid" therefore scored itself as listing its legal values, while
    listing none. That is the same shape as the round-28 probe token that
    contained the word its own assertion searched for.

So the question is not "is this message phrased like a good one". It is "does
this message actually name the values the tool takes" -- and since round 29 the
tool answers that itself, in the `enum` its deployed schema publishes. This
probe reads `tools/list` for the ground truth and checks the refusal against it.

Matching is on whole tokens, never substrings: `iqr` must appear as `iqr`, not
inside `iqrx`. The probe's own value is removed by SUBTRACTING ITS TOKENS from
the message's, rather than by deleting the string -- `period_unit`'s legal
values are the single letters D, H, M, Q, W and Y, so a probe token is nearly
certain to contain some of them as substrings, and a textual strip would both
erase evidence and risk splitting a longer word into a token that looks like a
legal value. Subtracting whole tokens cannot do either. A startup assertion
still refuses to report if the probe token itself tokenises to a legal value.

Two parameters have no enum because their set is decided at call time; those
are listed with the reason, and the probe prints their message so a reader can
judge it rather than trust a verdict.

    python3 dispatch_probe.py

Reads the deployed schema and calls the round-28 fixtures. Writes nothing.
"""

from __future__ import annotations

import json
import re
import subprocess

ENV = "/root/Harnesses/.env"

A = "/workspace/data/r28d/ads.csv"
OUT = "/workspace/data/r28d/out"
D = f"{OUT}/d3.docx"
P = f"{OUT}/p2.pptx"
X = "/workspace/data/r28d/book.xlsx"
PDF = "/workspace/data/r28d/filing.pdf"
MODEL = f"{OUT}/reg_model.pkl"

# Shares no substring with any legal value on the fleet, and contains none of
# the words the assertions below search for. Both facts are asserted at startup.
BAD = "zzqq_no_such_choice"


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
                                     "clientInfo": {"name": "dispatch-probe", "version": "29"}}},
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


SESSIONS: dict[str, tuple[str, str, str]] = {}
SCHEMAS: dict[str, dict[tuple[str, str], list[str]]] = {}


def session(label: str) -> tuple[str, str, str]:
    if label not in SESSIONS:
        url, tok = endpoint(label)
        SESSIONS[label] = (url, tok, open_session(url, tok))
    return SESSIONS[label]


def declared(label: str, tool: str, param: str) -> list[str] | None:
    """The legal values as the DEPLOYED schema publishes them, or None.

    Ground truth comes from the server, not from a table in this file: a probe
    carrying its own copy of the answer checks that the copy agrees with itself.
    """
    if label not in SCHEMAS:
        url, tok, sid = session(label)
        obj = payload(post(url, tok, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, sid)) or {}
        table: dict[tuple[str, str], list[str]] = {}
        for tool_spec in obj.get("result", {}).get("tools", []):
            props = (tool_spec.get("inputSchema") or {}).get("properties") or {}
            for name, spec in props.items():
                # A list parameter carries its enum on the ITEM schema.
                if spec.get("type") == "array" and isinstance(spec.get("items"), dict):
                    spec = spec["items"]
                if isinstance(spec, dict) and "enum" in spec:
                    table[(tool_spec["name"], name)] = [str(v) for v in spec["enum"]]
        SCHEMAS[label] = table
    return SCHEMAS[label].get((tool, param))


def call(label: str, tool: str, args: dict) -> tuple[dict | None, str]:
    url, tok, sid = session(label)
    body = {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": tool, "arguments": args}}
    raw = post(url, tok, body, sid)
    if re.search(r"session not found|Missing session ID|Bad Request", raw, re.I):
        sid = open_session(url, tok)
        SESSIONS[label] = (url, tok, sid)
        raw = post(url, tok, body, sid)
    obj = payload(raw)
    if obj is None:
        return None, f"TRANSPORT: {raw[:200]}"
    if "error" in obj:
        return None, f"MCP_ERROR: {json.dumps(obj['error'])[:200]}"
    text = result_text(obj)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None, f"NOT_JSON: {text[:200]}"
    return (parsed, text) if isinstance(parsed, dict) else (None, f"NOT_AN_OBJECT: {text[:200]}")


def tokens(text: str) -> set[str]:
    """Whole tokens, lowercased, so a value can never match inside a word.

    `std` must appear as `std` -- in `'std'`, `std,` or `std.` -- and never
    inside `understand`. Dotted values such as `tar.gz` stay one token, and each
    token is also offered with surrounding punctuation stripped so a value that
    ends a sentence still counts.
    """
    found = re.findall(r"[A-Za-z0-9_.\-]+", text)
    out: set[str] = set()
    for token in found:
        out.add(token.lower())
        out.add(token.strip("._-").lower())
    out.discard("")
    return out


def strip_probe(text: str) -> str:
    """Remove the probe value from TEXT being shown or scanned as prose.

    Some servers echo it upper-cased, so this is case-insensitive -- without
    that, `period_comparison`'s `'ZZQQ_NO_SUCH_CHOICE'` survives the strip.

    Value matching does NOT go through here; it subtracts tokens instead. See
    the module docstring for why deleting a substring is the wrong tool.
    """
    return re.sub(re.escape(BAD), " ", text, flags=re.I)


def about_the_value(blob: str, param: str) -> bool:
    """Did the server refuse the VALUE, or complain about something else?

    A refusal that never mentions the poisoned value or its parameter is
    answering a different question -- almost always because this probe sent an
    incomplete call. That is the probe's bug and is reported as such, never
    counted as coverage.
    """
    if re.search(re.escape(BAD), blob, re.I):
        return True
    return param.lower() in tokens(blob) and bool(
        re.search(r"unknown|unsupported|invalid|not supported|must be|one of", blob, re.I)
    )


CASES: list[tuple[str, str, str, dict]] = [
    # (endpoint, tool, poisoned parameter, otherwise-valid arguments)
    #
    # `fs_query.grep_mode` was probed here until round 29 with the value True.
    # True is a legal value for a boolean, so the call was correct and the
    # server was right to accept it -- the probe then reported that acceptance
    # as a silent defect, every round, for the whole of round 28. A boolean has
    # no wrong-value axis to test; a wrong TYPE is the contract_errors axis and
    # belongs to verify_r28_fixes.sh. The case is gone rather than excused.
    ("filesystem", "fs_read", "mode", {"path": A, "mode": BAD}),
    ("filesystem", "fs_index", "action", {"action": BAD, "path": OUT}),
    ("filesystem", "fs_manage", "action", {"action": BAD, "path": OUT}),
    ("filesystem", "fs_archive", "action", {"action": BAD, "path": f"{OUT}/r28.zip"}),
    ("filesystem", "fs_archive", "format_", {"action": "create", "path": f"{OUT}/z2.zip", "target": OUT, "format_": BAD}),
    # `content` is required: without it the refusal is about the missing search
    # term and says nothing about type_.
    ("filesystem", "fs_query", "type_", {"path": OUT, "content": "x", "type_": BAD}),

    ("data-medium", "compute_aggregations", "agg_func", {"file_path": A, "group_by": ["device"], "agg_column": "spends", "agg_func": BAD}),
    ("data-medium", "cross_tabulate", "agg_func", {"file_path": A, "row_column": "device", "col_column": "campaign_type", "values_column": "spends", "agg_func": BAD}),
    ("data-medium", "cross_tabulate", "normalize", {"file_path": A, "row_column": "device", "col_column": "campaign_type", "normalize": BAD}),
    ("data-medium", "pivot_table", "agg_func", {"file_path": A, "index": ["device"], "values": ["spends"], "agg_func": BAD}),
    ("data-medium", "sample_data", "method", {"file_path": A, "method": BAD}),
    ("data-medium", "detect_anomalies", "method", {"file_path": A, "method": BAD}),
    ("data-medium", "statistical_tests", "test", {"file_path": A, "test": BAD, "column_a": "spends"}),

    ("data-statistics", "check_outliers", "method", {"file_path": A, "method": BAD}),
    ("data-statistics", "correlation_analysis", "method", {"file_path": A, "method": BAD}),
    ("data-statistics", "lag_correlation", "method", {"file_path": A, "date_column": "Date", "x_column": "clicks", "y_column": "spends", "method": BAD}),
    ("data-statistics", "statistical_test", "test", {"file_path": A, "test": BAD, "column_a": "spends"}),
    ("data-statistics", "regression_analysis", "model_type", {"file_path": A, "x_columns": ["clicks"], "y_column": "spends", "model_type": BAD}),
    ("data-statistics", "period_comparison", "period_unit", {"file_path": A, "date_column": "Date", "metrics": ["spends"], "period_unit": BAD}),

    ("data-transform", "reshape_dataset", "mode", {"file_path": A, "mode": BAD}),
    ("data-transform", "reshape_dataset", "agg_func", {"file_path": A, "mode": "pivot", "index": ["device"], "columns": ["campaign_type"], "values": ["spends"], "agg_func": BAD}),
    ("data-transform", "aggregate_dataset", "mode", {"file_path": A, "mode": BAD}),
    ("data-transform", "aggregate_dataset", "normalize", {"file_path": A, "mode": "crosstab", "row_column": "device", "col_column": "campaign_type", "normalize": BAD}),
    ("data-transform", "resample_timeseries", "agg_func", {"file_path": A, "date_column": "Date", "value_columns": ["spends"], "freq": "M", "agg_func": BAD}),
    ("data-transform", "merge_datasets", "how", {"file_path": A, "right_file_path": A, "left_on": "device", "right_on": "device", "how": BAD}),
    ("data-transform", "concat_datasets", "direction", {"file_paths": [A, A], "direction": BAD}),
    ("data-transform", "list_derive_ops", "op", {"op": BAD}),

    ("data-visual", "run_eda", "mode", {"file_path": A, "mode": BAD}),
    ("data-visual", "generate_correlation_heatmap", "method", {"file_path": A, "method": BAD}),
    ("data-visual", "generate_chart", "chart_type", {"file_path": A, "chart_type": BAD, "value_column": "spends"}),
    ("data-visual", "generate_chart", "agg_func", {"file_path": A, "chart_type": "bar", "value_column": "spends", "category_column": "device", "agg_func": BAD}),
    ("data-visual", "generate_multi_chart", "chart_type", {"file_path": A, "chart_type": BAD, "value_columns": ["spends"]}),
    ("data-visual", "generate_multi_chart", "agg_func", {"file_path": A, "chart_type": "bar", "value_columns": ["spends"], "category_column": "device", "agg_func": BAD}),
    ("data-visual", "generate_3d_chart", "chart_type", {"file_path": A, "chart_type": BAD, "x_column": "spends", "y_column": "clicks", "z_column": "impressions"}),
    ("data-visual", "export_data", "format", {"file_path": A, "format": BAD}),

    ("docs-edit", "convert", "to", {"source": PDF, "to": BAD, "out": f"{OUT}/x.txt"}),
    ("docs-edit", "optimize", "action", {"source": PDF, "action": BAD, "out": f"{OUT}/x.pdf"}),
    ("docs-edit", "protect", "action", {"source": PDF, "action": BAD, "password": "p", "out": f"{OUT}/x.pdf"}),

    ("ml-basic", "train_classifier", "model", {"file_path": A, "target_column": "device", "model": BAD}),
    ("ml-basic", "train_regressor", "model", {"file_path": A, "target_column": "spends", "model": BAD}),
    # `columns` is required: without it the refusal is about the missing list.
    ("ml-medium", "detect_outliers", "method", {"file_path": A, "columns": ["spends"], "method": BAD}),
    ("ml-medium", "train_with_cv", "model", {"file_path": A, "target_column": "spends", "model": BAD, "task": "regression"}),
    ("ml-medium", "train_with_cv", "task", {"file_path": A, "target_column": "spends", "model": "lir", "task": BAD}),
    ("ml-medium", "compare_models", "task", {"file_path": A, "target_column": "spends", "task": BAD, "models": ["lir"]}),
    ("ml-medium", "compare_models", "models", {"file_path": A, "target_column": "spends", "task": "regression", "models": [BAD]}),
    ("ml-medium", "anomaly_detection", "method", {"file_path": A, "feature_columns": ["spends"], "method": BAD}),
    ("ml-medium", "run_clustering", "algorithm", {"file_path": A, "feature_columns": ["spends"], "algorithm": BAD}),
    ("ml-advanced", "tune_hyperparameters", "model", {"file_path": A, "target_column": "spends", "model": BAD, "task": "regression"}),
    ("ml-advanced", "tune_hyperparameters", "task", {"file_path": A, "target_column": "spends", "model": "lir", "task": BAD}),
    ("ml-advanced", "export_model", "format", {"model_path": MODEL, "format": BAD, "output_dir": f"{OUT}/exp"}),
    ("ml-advanced", "apply_dimensionality_reduction", "method", {"file_path": A, "feature_columns": ["spends", "clicks"], "method": BAD}),
    ("ml-advanced", "plot_learning_curve", "task", {"file_path": A, "target_column": "spends", "model": "lir", "task": BAD}),

    ("office-docx-basic", "insert_paragraph", "style", {"file_path": D, "after_index": 0, "text": "x", "style": BAD}),
    ("office-docx-basic", "append_text", "style", {"file_path": D, "text": "x", "style": BAD}),
    ("office-pptx-design", "add_chart", "chart_type", {"file_path": P, "slide_index": 0, "chart_type": BAD, "data": {"categories": ["a"], "series": {"s": [1]}}}),
    # `anchor_cell` is required: without it the refusal is about the anchor.
    ("office-xlsx-charts", "add_chart", "chart_type", {"file_path": X, "sheet_name": "Data", "chart_type": BAD, "data_range": "A1:B4", "anchor_cell": "E2"}),
    ("office-xlsx-formulas", "set_conditional_format", "rule", {"file_path": X, "sheet_name": "Data", "range_address": "B2:B4", "rule": BAD, "value": "1", "color": "green"}),
    ("office-xlsx-formulas", "set_data_validation", "validation_type", {"file_path": X, "sheet_name": "Data", "range_address": "A2:A4", "validation_type": BAD}),
    ("browser", "browse_extract", "mode", {"url": "https://example.com", "selector": "h1", "mode": BAD}),
]

# No enum on the deployed schema because the set is decided at call time. The
# probe cannot check these against ground truth, so it prints the message and
# only asserts that the refusal offers candidates.
#
# verify_r29_enums.sh's NO_ENUM_IS_CORRECT carries a third entry,
# generate_geo_map.location_mode. It is absent here on purpose: that tool needs
# a .geojson this fleet has no fixture for, so it is not in CASES, and an entry
# for a parameter this probe never reaches would be an excuse for a check that
# never ran. The schema side of it is covered by verify_r29_enums.sh.
DYNAMIC_SET = {
    "office-docx-basic/insert_paragraph.style": "the .docx defines its own styles; resolve_style reads the real set",
    "office-docx-basic/append_text.style": "the .docx defines its own styles; resolve_style reads the real set",
}

# A refusal that names only part of its schema's enum, for a reason: another
# argument has already narrowed which values could apply. Naming the whole enum
# here would be worse -- it would offer values this call cannot use.
PARTIAL_IS_EXPECTED = {
    "ml-medium/compare_models.models": "task=regression narrows 13 models to the 7 regressors",
    "ml-medium/train_with_cv.model": "task=regression narrows 13 models to the 7 regressors",
    "ml-advanced/tune_hyperparameters.model": "task=regression narrows 13 models to the 7 regressors",
}


def main() -> int:
    silent, named_all, partial, named_none, dynamic, probe_error, broken = [], [], [], [], [], [], []

    for label, tool, param, args in CASES:
        key = f"{label}/{tool}.{param}"
        body, raw = call(label, tool, args)
        if body is None:
            broken.append((key, raw))
            continue
        if body.get("success", body.get("ok")) is True:
            silent.append((key, str(body.get(param, ""))[:40]))
            continue

        blob = f"{body.get('error', '')} {body.get('hint', '')}".strip()
        if not about_the_value(blob, param):
            probe_error.append((key, blob[:150]))
            continue

        legal = declared(label, tool, param)
        # The probe's own tokens come out; nothing else is disturbed.
        clean = tokens(blob) - tokens(BAD)
        if legal is None:
            # Nothing to check against; assert only that candidates are offered,
            # and show the message so the reader judges it.
            offers = bool(re.search(r":\s*\S+\s*,", blob)) or bool(re.findall(r"'[^']+'", strip_probe(blob)))
            dynamic.append((key, offers, blob[:110]))
            continue

        # Whole-token match against the values the deployed schema publishes.
        hit = [v for v in legal if v.lower() in clean]
        if len(hit) == len(legal):
            named_all.append((key, len(legal)))
        elif hit:
            partial.append((key, len(hit), len(legal), sorted(set(legal) - set(hit))))
        else:
            named_none.append((key, legal, blob[:110]))

    # ---- safety: the probe must not be able to score its own assertion ----
    # Round 28 lost a whole pass to `definitely_not_a_valid_value`, whose text
    # contained the word the assertion searched for, so every refusal echoing it
    # scored itself as passing. The equivalent here is a probe token that
    # tokenises to a legal value: the message would appear to name a value the
    # server never offered.
    every_value = {v.lower() for table in SCHEMAS.values() for values in table.values() for v in values}
    overlap = sorted(every_value & tokens(BAD))
    if overlap:
        print(f"REFUSING TO REPORT: probe token {BAD!r} tokenises to legal value(s) {overlap}, "
              "so a refusal echoing it would score itself as naming them. Change BAD.")
        return 2

    print(f"{len(CASES)} dispatch parameters poisoned, on {len({c[0] for c in CASES})} endpoints")
    print(f"  refusal names every legal value:  {len(named_all)}")
    print(f"  names part of the set:            {len(partial)}")
    print(f"  names none of it:                 {len(named_none)}")
    print(f"  set is dynamic, candidates shown: {len(dynamic)}")
    print(f"  SILENTLY ACCEPTED:                {len(silent)}")
    print(f"  probe sent an incomplete call:    {len(probe_error)}")
    print(f"  transport / non-JSON:             {len(broken)}")

    if silent:
        print("\nSILENTLY ACCEPTED -- these are defects:")
        for key, echoed in silent:
            print(f"  {key:56} echoed={echoed}")

    if named_none:
        print("\nREFUSED but named none of its own enum -- these are defects:")
        for key, legal, blob in named_none:
            print(f"  {key:56} schema says {legal}")
            print(f"  {'':56} said: {blob}")

    unexplained = [row for row in partial if row[0] not in PARTIAL_IS_EXPECTED]
    if partial:
        print("\nnamed part of the set:")
        for key, hit, total, missing in partial:
            why = PARTIAL_IS_EXPECTED.get(key)
            print(f"  {key:56} {hit}/{total}  {why or '<-- UNEXPLAINED'}")
            if not why:
                print(f"  {'':56} never named: {missing}")

    undeclared_dynamic = [key for key, _, _ in dynamic if key not in DYNAMIC_SET]
    silent_dynamic = [key for key, offers, _ in dynamic if not offers]
    if dynamic:
        print("\nset decided at call time -- the message, for a human to judge:")
        for key, offers, blob in dynamic:
            why = DYNAMIC_SET.get(key, "<-- NOT IN DYNAMIC_SET")
            print(f"  {key:56} {'offers candidates' if offers else '<-- OFFERS NOTHING'}  ({why})")
            print(f"  {'':56} said: {blob}")

    stale = [key for key in DYNAMIC_SET if key not in {k for k, _, _ in dynamic}]

    if probe_error:
        print("\nthe probe's own bug -- refusal was about another argument, so this")
        print("parameter was NOT tested. Fix the call, do not file the row:")
        for key, blob in probe_error:
            print(f"  {key:56} {blob}")

    if broken:
        print("\nno usable answer:")
        for key, raw in broken:
            print(f"  {key:56} {raw}")

    print()
    failures = []
    if silent:
        failures.append(f"{len(silent)} silently accepted")
    if named_none:
        failures.append(f"{len(named_none)} named none of their enum")
    if unexplained:
        failures.append(f"{len(unexplained)} unexplained partial")
    if silent_dynamic:
        failures.append(f"{len(silent_dynamic)} dynamic offering nothing")
    if undeclared_dynamic:
        failures.append(f"{len(undeclared_dynamic)} dynamic not in DYNAMIC_SET")
    if stale:
        failures.append(f"{len(stale)} stale DYNAMIC_SET entries ({stale})")
    if probe_error or broken:
        failures.append(f"{len(probe_error) + len(broken)} untested (probe's fault)")

    if failures:
        print("FAILED: " + "; ".join(failures))
        return 1
    print(f"ALL {len(CASES)} dispatch parameters refuse a value they cannot mean, and name what they do take")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
