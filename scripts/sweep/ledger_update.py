"""Keep LEDGER_rNN.md current while the round is still running.

The ledger has to be written AS the sweep runs, not after it: a round that is
reconstructed at the end has already lost the distinction between a phase that
passed and a phase that was never reached, which is exactly what the next
re-run needs to know.

    python3 ledger_update.py --round 22

Reads the driver's log for what it did to each phase and the reports themselves
for how many rows landed, then rewrites only the `rows` and `verdict` cells of
the ledger table. Anything already written by hand in a verdict cell is kept --
a human verdict ("DEFECT x2, both in the count field") outranks a row count,
and losing it to an automatic pass would be worse than not running at all.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

HERE = Path(__file__).parent
DATA = Path("/root/Harnesses/data")

# Same rule as the driver's count_rows: at least two pipes after an optional
# leading one, minus markdown separator rows. Anchoring on a leading pipe sees
# roughly one report in seven as empty, because models write both styles.
ROW = re.compile(r"^[ \t]*\|?[^|]*\|[^|]*\|")
SEP = re.compile(r"^[\s|:*-]+$")

# Verdicts this script is allowed to overwrite. Anything else in the cell was
# written by a person reading the report and must survive.
OWNED = {"", "PASS", "UNFINISHED", "DRY", "RUNNING", "NOT REACHED"}


def count_rows(path: Path) -> int:
    if not path.exists():
        return 0
    n = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ROW.match(line) and not SEP.match(line):
            n += 1
    return max(0, n - 1)  # drop the header


def phases_seen(log: Path) -> tuple[set[int], int | None]:
    """Which phases the driver has started, and which one it is on now."""
    if not log.exists():
        return set(), None
    started: list[int] = []
    done: set[int] = set()
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(r"PHASE (\d+) ", line)
        if m:
            started.append(int(m.group(1)))
        elif line.strip().startswith("rows:") and started:
            done.add(started[-1])
    current = started[-1] if started and started[-1] not in done else None
    return set(started), current


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, required=True)
    args = ap.parse_args()

    ledger = HERE / f"LEDGER_r{args.round}.md"
    started, current = phases_seen(HERE / f"sweep_r{args.round}.log")

    out, changed = [], 0
    for line in ledger.read_text(encoding="utf-8").splitlines():
        cells = [c.strip() for c in line.split("|")]
        # | phase | label | report | tools | rows | verdict |  -> 8 with the
        # empty edges the split leaves either side.
        if len(cells) != 8 or not cells[1].isdigit():
            out.append(line)
            continue
        num, tools = int(cells[1]), int(cells[4])
        rows = count_rows(DATA / cells[3].strip("`"))
        verdict = cells[6]
        if verdict.strip("* ") in OWNED:
            if num == current:
                verdict = "RUNNING"
            elif num not in started:
                verdict = "NOT REACHED"
            elif rows == 0:
                verdict = "**DRY**"
            elif rows < tools:
                verdict = f"**UNFINISHED** ({rows}/{tools})"
            else:
                verdict = "PASS"
        new = f"| {num} | {cells[2]} | {cells[3]} | {tools} | {rows or ''} | {verdict} |"
        changed += new != line
        out.append(new)

    ledger.write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"round {args.round}: {len(started)} phases started, {changed} ledger rows updated")


if __name__ == "__main__":
    main()
