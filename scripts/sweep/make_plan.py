"""Build a sweep phase plan: tools/list output + one axis -> phases_rNN.tsv.

    python3 make_plan.py --round 11 --tools tools_r11.tsv --out phases_r11.tsv

The tools file is two tab-separated columns, server and tool, exactly as
tools/list reports them -- never a list the sweep model wrote itself, which once
silently omitted 19 tools and still reported a clean pass.

Output is one phase per line, tab separated:

    num  label  report  ticks  count  prompt

which is what the driver reads.
"""

from __future__ import annotations

import argparse
from collections import OrderedDict
from pathlib import Path

from axes import AXES
from blocks import FS_PHASES, INCREMENTAL, PREAMBLE, REPORT, REPORT_OPS, REUSE, VERIFY

# No phase names more than eight tools. Round 10 ran 38 of 39 phases on the first
# attempt at this size; at sixteen the model reliably stopped halfway.
MAX_TOOLS = 8

# Poll ticks the driver allows a phase before calling it timed out.
TICKS = "200"


def split(names: list[str], max_tools: int = MAX_TOOLS) -> list[list[str]]:
    """Chunk into as many parts as it takes, not always two.

    The old version halved once, so a fifteen-tool server became 8 + 7 and
    never 4 x 4. Round 15's axis -- open every artifact, count what is in it,
    copy it out alone and re-open it -- costs far more per tool than round 10's,
    and the Office phases only ever finished when they were small: 5 and 7 tools
    completed, 7 and 8 came up short. Pass max_tools=4 for a heavy axis.
    """
    if len(names) <= max_tools:
        return [names]
    parts = -(-len(names) // max_tools)  # ceil
    size = -(-len(names) // parts)  # spread evenly rather than leaving a stub
    return [names[i : i + size] for i in range(0, len(names), size)]


def build(
    round_no: int,
    tools_path: Path,
    fixture: str,
    max_tools: int = MAX_TOOLS,
    include_fs: bool = True,
    report_prefix: str = "report_",
) -> list[str]:
    axis = AXES[round_no]

    by_server: OrderedDict[str, list[str]] = OrderedDict()
    for line in tools_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        server, tool = line.split("\t")
        # File_System is covered as named operations, not as six tool calls.
        if server == "filesystem":
            continue
        by_server.setdefault(server, []).append(tool)

    chunks = []
    for server, names in by_server.items():
        parts = split(names, max_tools)
        for i, part in enumerate(parts, start=1):
            multi = len(parts) > 1
            suffix = f", part {i}" if multi else ""
            slug = server.replace("-", "_") + (f"_{i}" if multi else "")
            body = (
                f"This phase exercises {len(part)} tools on the {server} server. "
                "Give each one a real call with arguments that make sense for "
                f"/workspace/data/{fixture} or for a file you created earlier in this phase."
            )
            # The scratch slug stays the server's own, so a re-run still finds
            # the documents and workbooks earlier phases built. Only the report
            # filename takes the prefix -- the driver rm -f's its report before
            # each phase, and reusing a name would delete rows already collected.
            chunks.append((f"{server}{suffix}", slug, f"{report_prefix}{slug}.md", len(part), body, part))

    fs = []
    if include_fs:
        for label, slug, report, count, body in FS_PHASES:
            extra = axis["fs_extra"].get(slug, "")
            # FS_PHASES carries its report names hardcoded, so --report-prefix
            # used to apply to the generated phases and silently miss these
            # four. A round-16 plan then pointed at report_fs_write_1.md and
            # friends -- the files round 15 had already written -- and the
            # driver rm -f's its report before each phase, so generating the
            # plan was one command away from destroying four finished reports.
            fs.append((label, slug, report.replace("report_", report_prefix, 1), count, f"{body} {extra}".strip(), None))

    rows = fs + chunks
    total = len(rows)

    out = []
    for n, (label, slug, report, count, body, names) in enumerate(rows, start=1):
        prompt = PREAMBLE.format(round=round_no, n=n, total=total, scratch=slug, fixture=fixture)
        prompt += body + " "
        if names:
            prompt += REUSE
        prompt += axis["main"] + VERIFY + INCREMENTAL.format(unit=axis["unit"])
        if names:
            prompt += REPORT.format(
                report=report, count=count, names=", ".join(names), columns=axis["columns"]
            )
        else:
            prompt += REPORT_OPS.format(report=report, count=count, columns=axis["columns_ops"])
        out.append("\t".join([str(n), label, report, TICKS, str(count), prompt]))
    return out


def main() -> None:
    here = Path(__file__).parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--round", type=int, required=True)
    ap.add_argument("--tools", type=Path, required=True)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--fixture", default="Ad_Data.csv")
    ap.add_argument("--max-tools", type=int, default=MAX_TOOLS, help="tools per phase; use 4 for a heavy axis")
    ap.add_argument("--no-fs", action="store_true", help="skip the filesystem phases (already covered)")
    ap.add_argument("--report-prefix", default="report_", help="prefix for report filenames; change it to avoid overwriting an existing round's reports")
    args = ap.parse_args()

    if args.round not in AXES:
        raise SystemExit(f"no axis for round {args.round} -- add one to {here / 'axes.py'}")

    rows = build(
        args.round,
        args.tools,
        args.fixture,
        max_tools=args.max_tools,
        include_fs=not args.no_fs,
        report_prefix=args.report_prefix,
    )
    dst = args.out or here / f"phases_r{args.round}.tsv"
    dst.write_text("\n".join(rows) + "\n", encoding="utf-8")

    axis = AXES[args.round]
    print(f"round {args.round} — {axis['name']}")
    print(f"{len(rows)} phases -> {dst}")
    for line in rows:
        f = line.split("\t")
        print(f"  {f[0]:>2}  {f[1]:<34} {f[4]:>2} tools  -> {f[2]}")
    n_fs = 0 if args.no_fs else len(FS_PHASES)
    generated = sum(int(line.split("\t")[4]) for line in rows[n_fs:])
    fs_ops = 0 if args.no_fs else sum(r[3] for r in FS_PHASES)
    print(f"\n{generated} tools in the generated phases + {fs_ops} filesystem ops")


if __name__ == "__main__":
    main()
