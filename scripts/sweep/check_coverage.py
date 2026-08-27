#!/usr/bin/env python3
"""Did every tool a phase was told to call actually get a row?

    python3 check_coverage.py [--plan phases_r15.tsv] [--data /root/Harnesses/data]

The driver already prints "rows: 6 of 6" per phase, but it counts table rows and
nothing more -- six rows covering five tools twice is six rows. And the reports
miscount themselves: one wrote "Total tools: 9, Passed: 4, Failed: 5" above a
table of eight. Neither number is evidence that a named tool was called.

This reads the tool list out of each phase's own prompt -- the sentence the plan
ends with, "There are exactly N tools to call in this phase: a, b, c" -- and
looks for each name in the report the phase wrote. A name that never appears is
a tool the round did not cover, whatever the row count said.

It cannot prove the tool was *called*; the model could name it in a row saying
it skipped it. It proves the weaker thing that was actually going wrong: a tool
silently dropped from the round with a clean-looking report on top.

Exit code 1 if any named tool is missing from its report, so it can gate a
round's conclusions.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# The plan's closing sentence, written by blocks.REPORT.
_NAMED = re.compile(r"tools to call in this phase: (.+?)\.\s*$")

# A table row that is not the header and not the |---|---| separator. The
# leading pipe is optional: models write the table both ways.
_HEADER = re.compile(r"^\|?\s*(tool|op)\b", re.I)


def body_rows(text: str) -> list[str]:
    """Table rows, excluding the header and the |---|---| separator.

    Accepts both styles a model writes -- "| tool | ... |" and "tool | ... ".
    Requiring the leading pipe made ten of round 16's 66 reports look rowless
    while every one of them was complete; the driver carried the same
    assumption and read them as "nothing was written", so each cost its phase
    a second full attempt and fed the three-in-a-row abort.

    This column is reporting only -- the verdict below is whether a named tool
    appears in the text at all -- so widening it re-opens no phase.
    """
    rows = []
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.count("|") < 2:
            continue
        if set(stripped) <= set("|- :"):
            continue
        if _HEADER.match(stripped):
            continue
        rows.append(line)
    return rows


def main() -> int:
    here = pathlib.Path(__file__).parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", type=pathlib.Path, default=here / "phases_r15.tsv")
    ap.add_argument("--data", type=pathlib.Path, default=pathlib.Path("/root/Harnesses/data"))
    args = ap.parse_args()

    if not args.plan.exists():
        print(f"no plan at {args.plan}", file=sys.stderr)
        return 2

    print(f"{'ph':>3}  {'report':<34}{'named':>6}{'rows':>6}   not mentioned")
    gaps: list[str] = []
    written = 0
    total_named = total_rows = 0

    for line in args.plan.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        num, _label, report, _ticks, count, prompt = line.split("\t")
        path = args.data / report
        if not path.exists():
            continue
        written += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        rows = body_rows(text)

        match = _NAMED.search(prompt.strip())
        named = [t.strip() for t in match.group(1).split(",")] if match else []
        # File_System phases name operations in prose rather than a closing
        # list, so fall back to the plan's own count and check nothing.
        expected = len(named) or int(count)
        missing = [t for t in named if t not in text]

        total_named += expected
        total_rows += len(rows)
        if missing:
            gaps.append(f"phase {num} ({report}): {', '.join(missing)}")
        print(f"{num:>3}  {report:<34}{expected:>6}{len(rows):>6}   {', '.join(missing)}")

    print(f"\n{'':>3}  {'TOTAL':<34}{total_named:>6}{total_rows:>6}")
    print(f"{written} of {len(args.plan.read_text(encoding='utf-8').splitlines())} phases have written a report")

    if gaps:
        print("\nTOOLS NAMED IN A PHASE AND ABSENT FROM ITS REPORT:", file=sys.stderr)
        for gap in gaps:
            print(f"  {gap}", file=sys.stderr)
        return 1
    print("\nevery named tool appears in its report")
    return 0


if __name__ == "__main__":
    sys.exit(main())
