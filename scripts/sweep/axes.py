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


AXES[12] = {
    "name": "the empty case",
    "why": (
        "Ten rounds have handed every tool a 16,834-row dataset. Nothing has ever asked what "
        "happens when the input is real, valid, well-formed and holds nothing -- a CSV with "
        "headers and no rows, a document with no paragraphs, a workbook with one blank sheet. "
        "It is the most ordinary edge case there is, and round 11 hit two of them by accident: "
        "auto_detect_schema and read_model_report both reported confidently on nothing. A mean "
        "of no numbers, a quality score of 100 on no rows, and '0 outliers found' offered as a "
        "clean bill of health are all wrong answers wearing success: true."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: give every tool an input that is real, valid and EMPTY, and "
        "find out whether it says so. First build ONE empty input of the kind this phase's tools "
        "read -- a CSV with a correct header row and no data rows, a .docx with no paragraphs, a "
        "workbook with a single blank sheet, whichever fits -- and check it is genuinely valid by "
        "opening it with a read or inspect tool. Then call every tool in the phase on it, once. "
        "For each tool record which of these happened: it REFUSED and the message named the "
        "emptiness; it REFUSED but the message blamed something else, or named no cause at all; "
        "it SUCCEEDED and returned a number, a score, a chart or a file. The third is the finding "
        "this round is looking for, and the ones worth the most detail are a statistic computed "
        "from no observations, a quality or confidence score on nothing, a count of zero presented "
        "as a good result, an empty chart or an empty document written to disk as though it held "
        "something, and a model trained on no rows. Write down the exact number or file it "
        "produced. A clean refusal that names the cause is a PASS and needs one line. "
    ),
    "unit": "call",
    "columns": (
        "tool name | refused / refused-wrong-cause / succeeded | what it returned or wrote | "
        "is that answer real? | notes"
    ),
    "columns_ops": (
        "op name | refused / refused-wrong-cause / succeeded | what it returned or wrote | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "The empty input for this phase is an existing but zero-byte file, and an existing but "
            "empty directory. Run each op against those rather than against a populated tree: "
            "copying, moving and renaming a zero-byte file must all still work and say so, while "
            "replace_text and insert_after have nothing to match and should say that rather than "
            "report a successful edit of nothing."
        ),
        "fsw2": (
            "Use a zero-byte file and an empty directory as the targets. delete_lines and "
            "patch_lines on a file with no lines, and the delete_tree pair on a directory with no "
            "entries, are the calls to watch: an op that reports it removed something from an "
            "empty file is the finding."
        ),
        "fsr1": (
            "Read a zero-byte file and an empty directory. fs_read mode=content on no bytes, "
            "mode=tree on no entries, and fs_query over a directory holding nothing must each be "
            "distinguishable from an error and from a directory that does not exist -- round 11 "
            "fixed exactly that ambiguity in fs_index, and this is the same question one tool over."
        ),
        "fsr2": (
            "Build the index over an empty directory, archive an empty directory, and extract an "
            "archive that holds nothing. An index reporting 0 entries, an archive of nothing, and "
            "disk_usage on an empty tree all have a right answer and a plausible wrong one."
        ),
    },
}


AXES[13] = {
    "name": "exactly one row",
    "why": (
        "Round 12 asked what happens with no observations and found four tools answering "
        "confidently about nothing -- a type inferred from an empty set, a quality score of "
        "30/100 on zero rows, two library exceptions surfacing as the error message. One row is "
        "the same question one step along, and it is harder: an empty frame at least looks "
        "obviously wrong, while n=1 produces numbers that are individually plausible. Variance, "
        "standard deviation, correlation, skewness, every confidence interval and every "
        "regression slope is undefined or degenerate at a single observation, and the usual "
        "wrong answer is 0.0 -- which reads as 'no variation measured' rather than 'not "
        "measurable'. A single row is also a real thing to be handed: a filter that matched one "
        "record, a report for one day, a dataset still being loaded."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: give every tool an input holding EXACTLY ONE row, and find "
        "out whether the numbers it returns are real. Build one input of the kind this phase's "
        "tools read -- a CSV with a header and a single data row, a document with one paragraph, "
        "a workbook with one row under its header -- and confirm it is valid by opening it with a "
        "read or inspect tool. Then call every tool in the phase on it, once. For each tool "
        "record what it returned and whether that answer is defined at n=1. The findings to look "
        "hardest for are a spread reported as a number: a standard deviation or variance of 0.0, "
        "a correlation of 0.0 or 1.0, a confidence interval of zero width, an R-squared of 1.0, a "
        "skewness or kurtosis at all, a percentile spread where every percentile is the same "
        "value, a trend or forecast extrapolated from one point, and a model reporting perfect "
        "accuracy because it was trained and scored on the same single row. Each of those has a "
        "right answer -- undefined, null, or a refusal naming n -- and a plausible wrong one. "
        "Say which you got. A tool that refuses and names the single row is a PASS in one line. "
    ),
    "unit": "call",
    "columns": (
        "tool name | refused / succeeded | what it returned | is that defined at n=1? | notes"
    ),
    "columns_ops": ("op name | refused / succeeded | what it returned or wrote | notes"),
    "fs_extra": {
        "fsw1": (
            "The one-row input here is a file holding a single line with no trailing newline. "
            "Run each op against it: append_file to a file whose last line has no newline, "
            "replace_text and insert_after matching that only line, and copy/move/rename of a "
            "one-line file. Whether the append lands on the same line or a new one is the thing "
            "to check, and to read back rather than assume."
        ),
        "fsw2": (
            "Use a single-line file and a directory holding exactly one entry. delete_lines "
            "removing the only line, patch_lines on a one-line file, and delete_tree on a "
            "directory with one child are the calls to watch: leaving a zero-line file and "
            "reporting it as an edit is different from refusing."
        ),
        "fsr1": (
            "Read a file of exactly one line, and a directory with exactly one entry. Check "
            "fs_read mode=content start_line=0 end_line=1 returns that line and reports "
            "total_lines=1, that truncated is not set when the whole file was returned, and "
            "that mode=diff against an identical one-line copy reports no difference."
        ),
        "fsr2": (
            "Index a directory holding one file, archive it, and extract it. An index of one "
            "entry, an archive of one file, and disk_usage over a single-file tree each have an "
            "exact right answer that is cheap to verify by hand -- so verify it."
        ),
    },
}


# Candidates left over, kept so the round after this starts from evidence rather
# than from a fresh idea:
#
#   argument order    every tool called with its arguments supplied by keyword in
#                     reverse declaration order. Round 11 fixed five trainers by
#                     appending output_path last, on the rule that a positional
#                     swap silently rebinds callers -- untested above the rule.
#
#   two clients       the same file touched by two servers in one phase --
#                     data-basic writes it, office-xlsx reads it. Every round so
#                     far has stayed inside one server per phase.
