"""One entry per round. The axis is the question the round asks.

Adding a round means adding one entry here and nothing else. The tool list is
read live from tools/list, the phases are split from it, and every other word of
the prompt comes from blocks.py.

An axis is worth running when it can be wrong in a way no test would catch. Ten
rounds of history, shortest useful summary of each:

     8  argument handling      unknown argument names were silently dropped
     9  write paths            a None-write smeared rows across a sheet
    10  annotations            212 tools declared no MCP annotations at all
    11  retry / idempotence    idempotentHint was assigned by category, never measured

Fields:

  name        short label, for logs
  why         why this axis is worth a round; documentation, never sent
  main        the task block -- what to do to every tool
  unit        what one tool's work is called ("pair", "call"), used by INCREMENTAL
  columns     report columns for a tool-shaped phase
  columns_ops report columns for a File_System operation-shaped phase
  fs_extra    per-File_System-phase sentence, keyed by scratch slug; "" to skip
"""

from __future__ import annotations

AXES: dict[int, dict] = {}


AXES[11] = {
    "name": "call it twice",
    "why": (
        "Round 10 gave all 212 tools their MCP annotations, and idempotentHint was assigned by "
        "category -- reads and creates true, appends false -- not by measurement. That is an "
        "unverified claim, and no sweep in ten rounds had ever made the same call twice, though "
        "a client retrying a timed-out call is the most ordinary thing that happens to a server."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: call every tool TWICE with exactly the same arguments, back "
        "to back, and compare the two answers. This is what a client does when a call times out and "
        "it retries. For each tool record in your report: did the second call succeed, did it return "
        "the same answer as the first, and did anything on disk change the second time. All four of "
        "these are findings worth reporting in detail: a second identical call that FAILS when the "
        "first succeeded; one that quietly writes a SECOND file (a copy, a duplicate row, an extra "
        "version, an extra chart) when the caller asked for one; one that returns a DIFFERENT number "
        "or different rows for the same input; and one that leaves the file it edited CORRUPT or "
        "doubled. Before and after each pair, list the phase's scratch directory so you can say "
        "exactly what appeared. "
    ),
    "unit": "pair",
    "columns": (
        "tool name | call 1 PASS/FAIL | call 2 PASS/FAIL | same answer? | disk changed again? | notes"
    ),
    "columns_ops": (
        "op name | call 1 PASS/FAIL | call 2 PASS/FAIL | what the second call changed on disk | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "Run every op TWICE with identical arguments. Several of these SHOULD differ on the "
            "second call and that is the point: append_file twice must leave the text twice, while "
            "write_file twice must leave one copy of it. move and rename twice must not lose the "
            "file. Say in your report what the second call changed."
        ),
        "fsw2": "Run every op TWICE with identical arguments.",
        "fsr1": (
            "Run every mode TWICE with identical arguments. These are read-only tools, so the two "
            "answers must match exactly -- compare them and say so. A read tool that returns a "
            "different set, a different order, or a different count on the second identical call is "
            "a finding."
        ),
        "fsr2": (
            "Run every action TWICE with identical arguments. Building the SAME index twice, and "
            "creating the SAME archive twice, are the two calls to watch: say whether the second "
            "doubled anything, and whether extracting twice over the same destination is safe."
        ),
    },
}


# Round 12 is not written yet. The candidates below came out of round 11 and are
# kept here so the next round starts from evidence rather than from a fresh idea:
#
#   argument order    every tool called with its arguments supplied by keyword in
#                     reverse declaration order. Round 11 fixed five trainers by
#                     appending output_path last, on the rule that a positional
#                     swap silently rebinds callers -- untested above the rule.
#
#   the empty case    every tool given a real but empty input: a CSV with headers
#                     and no rows, a document with no paragraphs, a workbook with
#                     one blank sheet. Round 11 found auto_detect_schema and
#                     read_model_report both reporting confidently on nothing.
#
#   two clients       the same file touched by two servers in one phase --
#                     data-basic writes it, office-xlsx reads it. Every round so
#                     far has stayed inside one server per phase.
