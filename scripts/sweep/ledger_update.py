"""Keep LEDGER_rNN.md current while the round is still running.

The ledger has to be written AS the sweep runs, not after it: a round that is
reconstructed at the end has already lost the distinction between a phase that
passed and a phase that was never reached, which is exactly what the next
re-run needs to know.

    python3 ledger_update.py --round 22
    python3 ledger_update.py --round 22 --log sweep_r22.log --log sweep_r22b.log

A round that is stopped and restarted -- a provider running out of quota
mid-round is the usual reason -- writes a second log, and the ledger still has
to reflect both. Pass --log once per driver log, oldest first; the phase a
driver is *currently* on is taken from the last one, since only one driver runs
at a time.

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

# Verdicts this script is allowed to overwrite: exactly the strings it can
# itself produce, matched whole. Anything else in the cell was written by a
# person reading the report and must survive.
#
# This was a set of bare words compared against `verdict.strip("* ")`, which
# does not survive the script's own output: strip("* ") takes the leading stars
# off "**UNFINISHED** (4/5)" and leaves "UNFINISHED** (4/5)", because the
# trailing ")" is not in the strip set. So a phase this script marked
# unfinished stopped being its own from the next tick onward, and a re-run of
# that phase could never update the cell -- the one case the ledger exists for.
GENERATED = re.compile(r"^(|PASS|\*\*DRY\*\*|\*\*UNFINISHED\*\* \(\d+/\d+\)|RUNNING|NOT REACHED)$")


def count_rows(path: Path) -> int:
    if not path.exists():
        return 0
    n = 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if ROW.match(line) and not SEP.match(line):
            n += 1
    return max(0, n - 1)  # drop the header


def phases_seen(logs: list[Path]) -> tuple[set[int], int | None]:
    """Which phases have been started across every log, and the live one.

    `current` comes from the LAST log only. An earlier log's final phase has no
    `rows:` line when its driver was killed mid-phase, so reading current as
    "any log's unfinished tail" would pin a phase to RUNNING for the rest of
    the round -- the phase the quota ran out on, permanently.
    """
    seen: set[int] = set()
    current: int | None = None
    for index, log in enumerate(logs):
        if not log.exists():
            continue
        started: list[int] = []
        done: set[int] = set()
        for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
            m = re.match(r"PHASE (\d+) ", line)
            if m:
                started.append(int(m.group(1)))
            elif line.strip().startswith("rows:") and started:
                done.add(started[-1])
        seen |= set(started)
        if index == len(logs) - 1:
            current = started[-1] if started and started[-1] not in done else None
    return seen, current


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, required=True)
    ap.add_argument("--log", action="append", default=[], help="driver log, oldest first; repeatable")
    args = ap.parse_args()

    ledger = HERE / f"LEDGER_r{args.round}.md"
    logs = [HERE / name for name in args.log] or [HERE / f"sweep_r{args.round}.log"]
    started, current = phases_seen(logs)

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
        if GENERATED.match(verdict.strip()):
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
