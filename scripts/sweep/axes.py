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
    12  the empty case         a zero-row input came back as a confident zero
    13  exactly one row        n=1 statistics returned 0 where there is no value
    14  advertised vocabulary  a catalog listed 52 ops and the tool ran 8 of them
    15  the artifact           the reply was true and the file it named was unusable

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


AXES[14] = {
    "name": "the vocabulary a tool advertises",
    "why": (
        "Every tool teaches a vocabulary -- the ops it lists, the keys it says a dict holds, the "
        "values it names in its own description -- and nothing checks that the vocabulary it "
        "teaches is the one it accepts. Round 14's fixes came from asking exactly that of eight "
        "tools and finding all eight wrong: one listed 52 operations in a catalog tool and ran 8 "
        "of them; one documented a list of dicts and named none of the keys, so a wrong guess "
        "came back as the single quoted word 'label'; one dropped a paragraph written under a "
        "key it did not recognise and saved an empty document under success. This phase re-asks "
        "it of the tools those fixes can reach. The gap matters because it is invisible from "
        "either side on its own: the description looks complete, the tool looks like it works, "
        "and only handing the tool exactly what it told you to hand it shows the two disagree."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: take each tool's own description as a specification and "
        "hold it to it. For every tool, first read what its description, schema and any catalog "
        "tool claim it accepts -- the operations it names, the values it enumerates, the keys it "
        "says a dict or list entry holds -- and write that down. Then call it with exactly that, "
        "one claim at a time. Where a tool names a set of operations or modes, try ones from "
        "different parts of the list, not just the first. Where a tool takes a list of dicts, "
        "build the dict from the keys its description names, and then also try the obvious "
        "synonym a person would reach for -- 'content' for text, 'header' for heading, '>' for "
        "gt, 'then' for label. The three answers that matter are: it worked; it refused and the "
        "refusal named what to write instead; or IT REPORTED SUCCESS AND QUIETLY DID LESS THAN "
        "ASKED. The third is the finding. A tool that refuses a spelling it never promised is "
        "fine and is a PASS in one line -- as long as the error names the accepted spelling. A "
        "tool that accepts a call and drops part of it is the defect this phase exists to find. "
    ),
    "unit": "call",
    "columns": (
        "tool name | what its description claimed | what happened when you sent exactly that "
        "| did anything get silently dropped? | notes"
    ),
    "columns_ops": (
        "op name | what its description claimed | what happened | anything silently dropped? | notes"
    ),
    # Not run this round -- the File_System server was not touched by the fixes
    # under verification -- but present so the axis is complete if it is re-run.
    "fs_extra": {
        "fsw1": (
            "fs_write names its ops in its own description. Run each one named there, and for "
            "each check the argument names the description gives are the ones it actually reads."
        ),
        "fsw2": (
            "Same for the remaining fs_write ops: take the op names and argument names from the "
            "description and use exactly those, then read back what landed."
        ),
        "fsr1": (
            "fs_read names its modes. Call every mode the description lists, and check a mode it "
            "does not list is refused with a message naming the ones it does."
        ),
        "fsr2": (
            "fs_index, fs_manage and fs_archive each name their ops. Call every op named, and "
            "record any that the tool rejects despite naming it."
        ),
    },
}


AXES[15] = {
    "name": "open the file it wrote",
    "why": (
        "Fourteen rounds judged a tool by its reply. Not one ever opened what the tool produced. "
        "That gap cost a full day of every chart the fleet wrote: generated pages were changed to "
        "load their plotting library from a sidecar written once per output directory, which is "
        "right for a directory served whole and wrong for a deliverable, because a deliverable "
        "travels -- downloaded on its own, copied elsewhere, attached to a message. Every one of "
        "them opened as a title, an empty box, and an error in a console nobody has open. The "
        "replies were true throughout: success, the path, the byte count. The test suites passed "
        "throughout too, because they asserted the sidecar tag was PRESENT, which is the "
        "mechanism and not the property. It was found by a person opening one file and looking "
        "at it. This round opens all of them."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: every time a tool writes a file, open that file afterwards "
        "and hold it to what the reply claimed. The success flag and the byte count are not "
        "evidence -- a file of exactly the right size can be empty of the thing you asked for. "
        "For each artifact check three things and record all three. ONE, IT HOLDS WHAT WAS "
        "ASKED FOR: count the rows, columns, sheets, slides, paragraphs, charts or series that "
        "are actually in it and compare that count to the number the reply itself gave. TWO, IT "
        "STANDS ON ITS OWN: read the file and look for every reference pointing OUT of it -- a "
        "src= or href= naming another file, a link to a sibling the reader would have to be "
        "given as well, an absolute path that only exists on the machine that wrote it, a URL "
        "fetched when the file is opened. Then prove it: copy the file ALONE into a fresh empty "
        "directory INSIDE your own phase directory under /workspace/data (for example "
        "<your phase dir>/standalone_<tool>/) and check it is still complete there. Do not copy "
        "it to /tmp or anywhere outside /workspace/data -- that needs a permission you will sit "
        "waiting for, and the driver reads a blocked session as an idle one. A file that only works while its "
        "neighbours sit beside it is the defect this round exists to find, and it reports "
        "success every single time. THREE, IT IS THE TYPE IT CLAIMS: a .csv must parse with the "
        "row count the reply gave, a workbook or document must open and hold the named sheet or "
        "heading, an .html that says it drew a chart must contain that chart's own data and not "
        "merely an empty container for it. Where a tool writes no file, exercise it normally and "
        "say so in one line -- but if its reply NAMES a path, that path is an artifact and gets "
        "all three checks. "
    ),
    "unit": "call",
    "columns": (
        "tool name | file it wrote (or none) | does it hold what the reply claimed? | does it "
        "reference anything outside itself? | still complete when copied out alone? | notes"
    ),
    "columns_ops": (
        "op name | file it wrote (or none) | does it hold what the reply claimed? | does it "
        "reference anything outside itself? | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "This server writes the files the rest of the sweep checks, so hold it to the same "
            "rule: after every op, read the file back and compare it byte for byte with what you "
            "asked for. copy and move must leave the content identical -- check that, do not "
            "assume it. replace_text and insert_after must change the one place they were told "
            "to and nothing else: read the whole file, not just the edited line."
        ),
        "fsw2": (
            "After every op read the file back and compare it with what you asked for. "
            "patch_lines and delete_lines must touch only the lines named -- read the whole file "
            "afterwards and say what else moved. For download, check the file on disk is the "
            "bytes that were served and not an error page saved under a success flag."
        ),
        "fsr1": (
            "These read files rather than write them, so the check runs the other way: for each "
            "mode, compare what it reports against what the file actually holds. mode=content "
            "must return the real bytes -- confirm the length and the last line, not just the "
            "first. mode=tree must name every file that is really there. diff must describe a "
            "difference you can see yourself in the two files."
        ),
        "fsr2": (
            "The archive ops are the whole point of this phase for this server. Build the .zip "
            "and the .tar.gz, then extract each into a FRESH EMPTY directory and compare every "
            "extracted file byte for byte with its original -- an archive that unpacks into "
            "something subtly different is exactly the defect this round is about. For fs_index, "
            "check the index it built actually names the files on disk."
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


# Round 16 re-runs round 15's axis over the whole fleet, against deployed code
# rather than the code that was live when round 15 ran.
#
# Round 15 found 27 defects and every one of them was fixed, tested and pushed
# while the round was still going -- so its own later phases were measuring a
# build that no longer existed, and its earlier ones a build that had already
# been corrected by the end. That is fine for finding defects and useless as a
# statement about the fleet's current state. This one runs start to finish
# against one build, with every fix deployed, so a clean phase means something.
#
# Same lens, deliberately: opening the artifact is what found all 27, and the
# fixes changed what the tools SAY about what they wrote (counts, samples,
# addresses, disclosures) -- which is exactly what this axis checks. A new axis
# would be a different question, and this one has not been answered yet.
#
# Run it at --max-tools 4. Round 15 proved 7-8 tools per phase is too many for
# this axis: Office phases completed at 3-4 and came up short at 7-8.
AXES[16] = dict(AXES[15])
AXES[16]["name"] = "open the file it wrote (re-run on deployed fixes)"


# Round 17 -- the "two clients" candidate above, finally run.
#
# Sixteen rounds have stayed inside one server per phase. So every defect in the
# HANDOVER between two servers has been structurally invisible: the sweep has
# never once taken the path one server returned and given it to another.
#
# This is the direct successor to round 16 rather than a change of subject.
# Round 16's best finding was that a writer and its own sibling reader share an
# assumption, so a round-trip through one server is self-consistent and still
# wrong -- set_cell stored "16833" as a string, read_cell returned 16833, and
# every same-server check passed. Round 16 caught it because a HUMAN opened the
# file with openpyxl. Round 17 replaces the human with a second server, which is
# what actually happens in production: an LLM chains data-basic -> office-xlsx
# and has only the first tool's reply to go on.
#
# The four servers share /root/Harnesses/data at /workspace/data, verified
# 2026-08-27 on all of mcp-office, mcp-data-analyst, mcp-ml and
# mcp-filesystem-fs-basic. So a handover is physically possible and any failure
# is a real defect, not a mount that was never there.
#
# The phase's own tools stay the writers, and the reader is pulled in from
# another server, so each named tool still owns a row and check_coverage /
# strict_coverage keep working unchanged.
#
# Run it at --max-tools 4, same as 16: this axis costs MORE per tool than
# round 16 (two servers per artifact instead of one), so do not go wider.
AXES[17] = {
    "name": "hand the file to a different server",
    "why": (
        "Every round so far has judged a tool against itself or against its own siblings. A "
        "writer and its sibling reader share an assumption, so the round-trip agrees and is "
        "still wrong -- round 16's set_cell wrote the number 16833 as TEXT, read_cell read it "
        "back as 16833, and only a third party (openpyxl's data_type, or Excel summing the "
        "column to 0) could see it. The production case is a chain: one server writes, another "
        "reads, and the model driving them has nothing but the first reply to go on. This round "
        "makes the second reader a different server."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: every artifact a listed tool writes must then be READ BY A "
        "TOOL ON A DIFFERENT SERVER, and the two readings compared. Writing to /workspace/data "
        "makes the file visible to every server, so this is always possible; if you think it is "
        "not, say which server could not see the path rather than skipping the check. "
        "For each artifact record four things. ONE, THE PATH SURVIVES: take the path EXACTLY as "
        "the writing tool returned it -- do not tidy it, do not swap a public_url for a local "
        "path, do not add or change a directory -- and give that literal string to the reading "
        "tool on the other server. If the reader rejects it, that is the finding: record the "
        "path as returned, the reader's exact error, and what you had to change to make it work. "
        "A caller has only the first reply to go on, so any edit the handover required is a "
        "defect however small. TWO, BOTH SERVERS SEE THE SAME DATA: compare the row and column "
        "counts the two servers report, and pick at least one NUMERIC column and one TEXT column "
        "and check the actual values agree. Numbers are where this breaks -- a number stored as "
        "text, an integer that came back 0.0, a rounded decimal, a date turned into a serial "
        "number. State the values you compared, not just that they matched. THREE, THE TYPES "
        "AGREE: where a reader reports a column type, dtype or cell type, say whether it is the "
        "type the writer claimed to store. A column of numbers that the second server reads as "
        "text is exactly this round's defect and BOTH tools will report success. FOUR, IT "
        "SURVIVES THE ROUND TRIP: hand it back -- have the second server write the data out "
        "again and the first server read that -- and say what changed between the original and "
        "the final file. Where a tool writes no file, pass its OUTPUT to a tool on another "
        "server that should consume it (a column list, a model id, a set of statistics) and "
        "apply the same four checks to that handover. "
    ),
    "unit": "handover",
    "columns": (
        "tool name | file or output it produced | reader tool on the OTHER server | did the "
        "reader accept the path exactly as returned? | same counts, values and types on both "
        "sides? | what the caller had to change | notes"
    ),
    "columns_ops": (
        "op name | file or output it produced | reader tool on the OTHER server | did the reader "
        "accept the path exactly as returned? | same counts, values and types both sides? | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "This server is the universal second client -- it can read anything the others write "
            "-- so run this phase BOTH ways. First write a file with these ops and have a domain "
            "server read it (a .csv to data-basic load_dataset, for instance). Then take a file "
            "one of the domain servers wrote earlier and read it back with fs_read, comparing "
            "byte for byte against what that server said it contained. copy and move must not "
            "change a file another server can still open: after each, have the owning server "
            "re-read it."
        ),
        "fsw2": (
            "Run this phase both ways as well. patch_lines and delete_lines on a .csv that a "
            "data server is using: after the edit, have that server re-load the file and say "
            "whether its row count moved by exactly the number of lines you touched. For "
            "download, hand the downloaded file to the server that should own that file type "
            "and check it opens as that type rather than as a saved error page."
        ),
        "fsr1": (
            "These read rather than write, so they ARE the second client. For each mode, read a "
            "file that another server wrote and compare what fs reports against what the writing "
            "server claimed: mode=content against the writer's byte count, mode=tree against the "
            "list of files the writer said it produced. diff two files written by two different "
            "servers from the same data and describe what differs."
        ),
        "fsr2": (
            "Archive files written by OTHER servers -- a workbook from office, a chart from "
            "data-visual -- then extract into a fresh empty directory and have the ORIGINAL "
            "server re-open the extracted copy. An archive that unpacks into something its own "
            "server can no longer read is this round's defect in its clearest form. For "
            "fs_index, check the index names the files those other servers actually wrote."
        ),
    },
}


# Round 18 -- do what the hint told you to do.
#
# Every tool in the fleet returns a `hint` on failure. CLAUDE.md makes it a
# contract ("must name a specific tool or fix, never 'Invalid input.'"), and it
# is the field an LLM actually acts on: the error explains, the hint is the
# instruction. Seventeen rounds have read hints and none has ever FOLLOWED one.
#
# The evidence that this is worth a round is that every time a hint has been
# checked in passing, it was wrong -- and each was found by accident while
# chasing something else:
#
#   e7ec243  read_document on a .mcp_versions path: the error named the
#            timestamp route, the hint said "Check that file_path is a valid
#            .docx file". The file IS a valid .docx. The hint argued the caller
#            out of the answer the error had just given them.
#   e7ec243  every PermissionError answered "is open in Word, Excel or
#            PowerPoint" -- a Windows file-lock answer given to a Linux
#            ownership problem. A round-15 phase was told to close an
#            application that was not running and retried into the same error.
#   (r16)    every "Sheet 'X' not found" said "Use list_sheets to get available
#            sheet names" -- a second call to learn something the workbook
#            already open in front of it knew.
#
# Three for three, in a field nobody has ever swept. A hint that names a
# specific WRONG fix is worse than a vague one, because the caller acts on it.
#
# This is the cheapest axis since round 13: two calls per tool (make it fail,
# then do exactly what it said) and no artifact to open. It is also the first
# round to judge a tool by its RECOVERY rather than its success, which is the
# path a model actually spends its time on -- models get arguments wrong
# constantly, and the hint is the whole of the fleet's answer to that.
AXES[18] = {
    "name": "do what the hint told you to do",
    "why": (
        "Every tool returns a hint on failure and the standards make it a contract: name a "
        "specific tool or fix, never 'Invalid input.' It is the field an LLM acts on -- the "
        "error explains, the hint instructs. Seventeen rounds have READ hints and none has "
        "FOLLOWED one. Every time a hint has been checked in passing it was wrong: a valid "
        ".docx called invalid, a Linux ownership error answered with 'close Excel', a sheet "
        "name answered with a second call to learn what was already on screen. A hint naming a "
        "specific wrong fix is worse than a vague one, because the caller obeys it."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: make each tool FAIL, then do EXACTLY what its hint tells "
        "you to do, and report whether that worked. Two calls per tool, minimum. "
        "FIRST, make it fail in a way a careful caller would plausibly fail: a column or sheet "
        "or slide that does not exist, a file path that does not exist, a value of the wrong "
        "type, a required argument omitted, an op or format name that is close to a real one. "
        "Do NOT invent nonsense arguments -- the point is a realistic mistake, not garbage. Say "
        "exactly what you called and what came back. "
        "SECOND, READ THE HINT AND OBEY IT LITERALLY. If it names a tool, call that tool. If it "
        "names a parameter or value, use it. If it says 'use X to get Y', do that and then "
        "retry the original call with what you got. Do not use your own knowledge to fix the "
        "call -- follow the hint and only the hint, because that is what a model with no other "
        "information would do. Then say whether the retry SUCCEEDED. "
        "Record four judgements per tool. ONE, IS THE HINT ACTIONABLE: does it name a specific "
        "tool, parameter, value or command, or is it a generic 'check your input' that tells "
        "you nothing you did not know? TWO, IS IT TRUE: does the thing it names actually exist "
        "and actually apply -- a tool that is really there, a parameter really accepted, a "
        "cause that is really the cause? A hint naming a tool or argument that does not exist "
        "is this round's clearest defect. THREE, DID FOLLOWING IT WORK: after doing exactly "
        "what it said, did the call succeed? If it did not, quote what you did and the second "
        "error. FOUR, DOES IT CONTRADICT THE ERROR ABOVE IT: if the error already said what to "
        "do, does the hint agree, or does it send you somewhere else? Also flag a hint that "
        "asks for a call whose answer the tool already had -- being told to list the sheets of "
        "a workbook the tool has open is a round trip the response should have saved you. "
        "Where a tool cannot be made to fail at all, say so and record what you tried."
    ),
    "unit": "recovery",
    "columns": (
        "tool name | the realistic mistake you made | the error | the hint, quoted | what you "
        "did to obey it | did the retry succeed? | notes"
    ),
    "columns_ops": (
        "op name | the realistic mistake you made | the hint, quoted | what you did to obey it | "
        "did the retry succeed? | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "Write ops fail in ways with real consequences, so check the hint does not send you "
            "somewhere destructive. For create_dir and write_file try a path whose parent does "
            "not exist; for copy and move try a destination that already exists and a source "
            "that does not. If a hint suggests overwriting or deleting to recover, say so "
            "plainly -- a hint that recommends data loss as the fix is a finding on its own."
        ),
        "fsw2": (
            "For delete_request and delete_tree_request, deliberately reuse a spent token and "
            "obey whatever the refusal tells you to do next. For patch_lines and delete_lines "
            "use a line number past the end of the file. For set_permissions use a mode string "
            "in the wrong format, and for download a URL that returns an error page rather than "
            "a file -- then check whether the hint tells you the download failed at all."
        ),
        "fsr1": (
            "Read ops are where a wrong hint costs least to obey, so obey every one exactly. "
            "Give fs_read a directory where it wants a file, a mode name that does not exist, "
            "and mode=diff with only one path. Give fs_query a pattern that matches nothing and "
            "a root that does not exist. A hint that answers 'no matches' with advice about the "
            "pattern when the ROOT was wrong is the defect to watch for."
        ),
        "fsr2": (
            "For fs_archive try extracting a file that is not an archive and creating an archive "
            "of a path that does not exist. For fs_index query before building the index at all "
            "-- the hint should tell you to build it first, and following that hint should then "
            "make the query work. For fs_manage use an action name that does not exist and check "
            "whether the hint lists the actions that do."
        ),
    },
}


# Round 22. Rounds 20 and 21 established that the tools ANSWER -- 207 calls, one
# defect -- and that what is left is whether the answer is right. This round
# narrows that to a specific cause: between rounds 21 and 22 all six repos moved
# from Python 3.12 to 3.14 and from third-party fastmcp 2.x to the official MCP
# SDK, in one week. CI proves every tool still answers; the e2e job proves the
# transport, the auth and one real call per tool. None of that can see a value
# that changed SHAPE in the move -- a float that now arrives as a string, a NaN
# where JSON has no token for one, a warning or an object repr that leaked into a
# field because a library started emitting it. Math and Web_Browser are back in
# the harness for this round: both migrated with the others, and browser's
# five-round zero is partly that a success-checking sweep dismisses all 13 of its
# tools for answering `ok`.
AXES[22] = {
    "name": "the answer as data, after the runtime moved",
    "why": (
        "A migration does not break tools loudly. It breaks the edges of values: json.dumps "
        "writing a bare NaN that no conformant parser accepts, numpy scalars reaching a "
        "response as numpy.float64(0.83), a DeprecationWarning text captured into a field, a "
        "default argument evaluated at a different time under PEP 649. Every one of those "
        "returns success: true and reads correctly to a human. Sixteen rounds have judged "
        "responses as prose -- is the number right, is the hint useful. None has judged one as "
        "DATA: is every field a type a non-Python client can read. The fleet's own history says "
        "this is where it hides: read_column_stats returned \"mean\": Infinity, which "
        "round-trips perfectly through Python and breaks every JS or Go client, and only a "
        "second server disagreeing ever surfaced it."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: call each tool for real, then read its RESPONSE AS DATA "
        "rather than as prose, and report whether that data is still well formed. These servers "
        "changed Python version and MCP library at once. That every tool still answers is "
        "already proven -- what is not proven is that the VALUE it answers with survived. "
        "Check five things on every response, and quote the exact offending text when one fails. "
        "ONE, NUMBERS: every number must be a real JSON number. A number delivered as a quoted "
        "string, or as NaN, Infinity, -Infinity, nan, inf or null where a number was promised, "
        "is a finding -- those are not valid JSON and a non-Python client cannot read them. "
        "TWO, LEAKS: no field may carry a Python object repr (anything like <... object at "
        "0x...>), a type wrapped round a value (numpy.float64(...), Timestamp(...), "
        "PosixPath(...), dtype(...)), a traceback fragment (Traceback, File \"...\", line N), or "
        "any warning text (DeprecationWarning, FutureWarning, RuntimeWarning, \"is deprecated\"). "
        "Those are the fingerprints a runtime change leaves. "
        "THREE, THE ENVELOPE: success, op and token_estimate must be present on EVERY response, "
        "failures as well as successes. Say which are missing. "
        "FOUR, EMPTINESS: a field the tool's own description promises that comes back missing, "
        "null, [] or {} on a call that plainly should have produced something counts the same as "
        "a wrong value. \"No results\" and \"no changes\" are claims -- check them against what "
        "you know is there. "
        "FIVE, for at least THREE tools in this phase RECOMPUTE one number a second way and "
        "compare it digit for digit. A right-looking number that is wrong is worth more than "
        "every well-formed one. "
        "Also call ONE tool in this phase TWICE with byte-identical arguments and diff the two "
        "responses. Anything that differs and is not a timestamp, a duration or a generated "
        "filename is a finding: library defaults moved in this migration, and a value that "
        "changes between two identical calls is the tell. "
        "Not every server here takes a data file: arithmetic tools take an expression or a "
        "formula, browser tools take a URL -- use https://example.com/ for those. And one "
        "server answers ok instead of success and carries no op or token_estimate. If that is "
        "the shape of EVERY response from that server, record it ONCE as that server's contract "
        "and judge its other fields on their own terms, rather than reporting a dozen tools as "
        "each missing a field."
    ),
    "unit": "response",
    "columns": (
        "tool name | what you called | are all numbers real JSON numbers? | anything leaked "
        "(repr / type wrapper / traceback / warning / NaN / Infinity)? | success, op and "
        "token_estimate present? | cross-check: what you recomputed and did it match | notes"
    ),
    "columns_ops": (
        "op name | what you called | are all numbers real JSON numbers? | anything leaked "
        "(repr / traceback / warning / NaN / Infinity)? | success, op and token_estimate "
        "present? | cross-check | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "Every one of these ops reports what it did -- a byte count, a line count, a path. "
            "Check each of those numbers against the file itself with fs_read, and check the "
            "path it echoes back is the path you passed, not a rewritten or repr'd one. A size "
            "that rounds to 0 KB for a file that is not empty, a line count off by one, and a "
            "path printed as PosixPath(...) are each a finding here."
        ),
        "fsw2": (
            "set_permissions must report the mode actually set -- read it back with fs_manage "
            "action permissions and compare the two strings. download must report the real byte "
            "count of what it fetched; use https://example.com/ as the url. The delete_*_request "
            "ops return a token: carry it to the matching confirm, then reuse the spent token "
            "once, which must be refused -- and check that refusal is still a well-formed "
            "response carrying success, op and token_estimate, not a bare string or a raised "
            "exception."
        ),
        "fsr1": (
            "fs_read mode=meta reports a size and an mtime: compare both against fs_manage for "
            "the same path. mode=content must return the bytes the file really holds, so compare "
            "a checksum rather than eyeballing it. fs_query reports a count and a truncated "
            "flag -- count the results it actually lists and check the number agrees, and check "
            "truncated reflects whether another file MATCHED, not whether files were left "
            "unscanned."
        ),
        "fsr2": (
            "fs_index action stats prints counts: check each against what action list actually "
            "returns. fs_archive create must report the real member count and size -- open the "
            "archive and count them. After extract, compare the extracted files to the originals "
            "byte for byte. fs_manage action disk_usage returns numbers in some unit: check the "
            "unit is stated and that a small file does not round to zero."
        ),
    },
}


# Round 23. The seventh repo joins the sweep, and the axis is the one technique
# that found MCP_Documents' two worst defects in its own rounds 2 and 4 -- and
# has never been run across the fleet. Round 22 asked one tool the same question
# twice in a row; that only catches plain non-determinism. This asks it again
# after ANOTHER tool has touched the same thing. Every server here holds state a
# caller cannot see: a reader LRU, a loaded dataset, a workspace, an open
# workbook, a cached model. `find('JUMLAH EKUITAS')` returned 5 hits, then 3
# after an unrelated extract() on the same document, and `probe` reported a
# document 12.9% smaller once its pages had been read -- both success: true,
# both invisible to a repeat call, and both in the number whose whole job is to
# stop the caller asking for too much. The tools that LOOK read-only are the
# ones nobody suspects of writing anything.
AXES[23] = {
    "name": "ask the same question after something else has run",
    "why": (
        "Determinism checks repeat one call and prove nothing about this: the state that "
        "changes the answer is written by a DIFFERENT tool. Two defects of exactly this shape "
        "were found by accident on one pair of tools, and running it as a matrix on nine tools "
        "found a third in minutes. It is cheap, it needs no ground truth, and nothing in CI can "
        "see it -- every call succeeds, every response reads correctly, and only the comparison "
        "between the first answer and the third one shows anything at all. The mirror case is "
        "the same question backwards and just as unchecked: after a write tool really changes "
        "something, a reader that reports no change is the tool whose entire job is confirming "
        "the edit landed saying the edit did nothing."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: find out whether these tools change each other's answers. "
        "Pick a target -- a file, a dataset, a document, a workbook, a model -- and work on that "
        "ONE target for the whole phase wherever the tools allow it. "
        "STEP ONE, pick a WITNESS: a read-only tool in this phase that answers with numbers or a "
        "list. Call it and keep the whole response. "
        "STEP TWO, call the witness a SECOND time immediately, with byte-identical arguments. If "
        "those two differ at all, stop and record it -- a tool whose answer changes with nothing "
        "in between is the worst finding available here. "
        "STEP THREE, call the phase's other tools on the SAME target, one at a time, in the "
        "order the tools' own descriptions suggest a caller would use them. "
        "STEP FOUR, call the witness a THIRD time, byte-identical to the first. Diff it against "
        "the first response field by field. Anything that differs and is not a timestamp, a "
        "duration or a generated filename is a finding: quote the field, the value before and "
        "the value after. If you can say which tool in between changed it, say so -- re-run the "
        "witness after a single suspect if that is quick. "
        "Do this for at least THREE different witnesses in this phase, not one. Prefer as "
        "witnesses the tools that count, measure, size or estimate something -- a page count, a "
        "row count, a token estimate, a match count, a list of columns -- because a number that "
        "silently moves is worth more than a sentence that changes wording. "
        "AND THE SAME QUESTION BACKWARDS: where this phase has a tool that WRITES, make a change "
        "you can describe in one sentence, then ask a reader about it. A reader that reports the "
        "same answer as before, 'no changes', or an empty list, after a change you know landed, "
        "is a finding of exactly equal weight -- verify the change really landed first, by "
        "reading the file itself or with a tool on a different server. "
        "Do not report an answer that changes because the DATA changed. A count that moves "
        "because you added a row is correct; a count that moves because something merely LOOKED "
        "at the target is the defect. Say which one you are reporting. "
        "Not every server here takes a data file: arithmetic tools take an expression or a "
        "formula, browser tools take a URL -- use https://example.com/ for those, and there the "
        "witness is asking for the same page again after fetching another. Document tools take a "
        "document, not a dataset: use /workspace/data/BBCA_filing.pdf, a real 183-page filing, "
        "and do not modify, overwrite or delete it -- write every output under your own scratch "
        "directory. It is a big document: ask about a few pages at a time rather than all of it, "
        "and if a tool refuses because the answer would be too large, that refusal is an answer "
        "-- record what it suggested and whether following the suggestion worked. "
        "Two contracts that are deliberate, so they are not findings: one server answers ok "
        "rather than success and carries no op or token_estimate -- record that once as that "
        "server's shape. And bold and italic are the quoted strings \"true\", \"false\" and \"\" "
        "rather than JSON booleans, because a boolean cannot say 'turn it off'; a refusal naming "
        "the quoted form is that contract working, so send the quoted form and carry on. "
    ),
    "unit": "witness",
    "columns": (
        "tool name | what you called | witness or actor | called twice back to back: identical? "
        "| after the other tools ran, is the same call still identical -- and if not, which field "
        "moved, from what to what | if this tool wrote something, did a reader see the change? | "
        "notes"
    ),
    "columns_ops": (
        "op name | what you called | witness or actor | called twice back to back: identical? | "
        "after the other ops ran, is the same call still identical -- which field moved, from "
        "what to what | did a read op see what this op did? | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "The witness here is fs_read: take mode=meta on one file you wrote first, and take "
            "it again after the copy, move, rename and replace_text ops have run on OTHER files "
            "in the same directory. The size, the line count and the path must not have moved. "
            "Then the backwards check: after replace_text and after insert_after, fs_read the "
            "file and confirm the new bytes are really there -- an op that reports a count of "
            "lines changed and leaves the file alone is the finding. And after copy, move and "
            "rename, ask fs_read about the ORIGINAL path: a moved file must be gone from where "
            "it was, and a copied one must still be there."
        ),
        "fsw2": (
            "The witness is fs_read mode=meta on a file you keep untouched for the whole phase. "
            "set_permissions must report the mode actually set -- read it back and compare the "
            "two strings. download must report the real byte count; use https://example.com/ as "
            "the url. The delete_*_request ops return a token their matching confirm needs -- "
            "carry it across, then reuse a spent token, which must be refused. Between each of "
            "those, re-ask the witness: nothing you did to other files may change what fs_read "
            "says about this one."
        ),
        "fsr1": (
            "This phase is the axis itself. Run fs_query with one pattern and record the count. "
            "Run it again with no changes -- the two counts must agree. Then use fs_write to add "
            "ONE file that matches the pattern, and run the identical query a third time: the "
            "count must go up by exactly one, and the new file must be in the list. A count that "
            "does not move is a stale answer; a count that moves by more than one is counting "
            "something else. Then run the SAME query with a smaller and a larger max_results and "
            "check whether the total it reports moves with it -- a total that changes when you "
            "only asked for fewer results is reporting how much it searched, not how much is "
            "there. Do the same pairing with fs_read mode=content and mode=meta on one file: read "
            "it, run the queries, read it again, and compare."
        ),
        "fsr2": (
            "Witness with fs_index action stats, then action query. Record the counts. Add a "
            "file with fs_write, then ask both again: an index that answers exactly as before "
            "has either not noticed or is answering from a cache, and its response should say "
            "which. For fs_archive, create an archive, then extract it somewhere else and "
            "compare the extracted files to the originals byte for byte; then ask fs_manage "
            "action disk_usage about the directory before and after, and check the number moved "
            "in the direction and roughly the amount you expect."
        ),
    },
}


AXES[24] = {
    "name": "believe the description",
    "why": (
        "An MCP client sees one sentence per tool and nothing else -- no README, no examples, "
        "no source. In this fleet that sentence is the tool's docstring, capped at 80 characters "
        "by a CI check, which is exactly the pressure that makes a description over-promise: "
        "'SELECT-only', 'Bounded always', 'Returns names only, no data', 'preserving run "
        "formatting'. Round 23b's best defect was found this way and not by its own axis -- "
        "query_select says SELECT-only and enforces it by testing whether the string starts with "
        "'select' or 'with', so WITH x AS (SELECT 1) DELETE FROM pages walks past the guard and "
        "empties the table under ok: true. Nothing in CI can see this class: CI asserts what the "
        "code does and never that the sentence above it is true. And it needs no ground truth, "
        "because every tool ships its own oracle."
    ),
    "main": (
        "THE MAIN TASK OF THIS PHASE: treat each tool's own DESCRIPTION as a contract and try to "
        "prove it wrong. The description is the one-line summary your client shows you for that "
        "tool -- the same text you would read to work out how to call it. "
        "STEP ONE, before calling anything, copy the tool's description into your report row "
        "VERBATIM. If you paraphrase it the row is worthless, because the whole question is "
        "whether those exact words are true. "
        "STEP TWO, find the CLAIM in it. Nearly every description here carries one: a limiting "
        "word (only, never, always, bounded, in-place, literal, permanently), an automatic "
        "behaviour (auto-detect, auto-select), a promise about the answer's shape (returns names "
        "only, returns a path only, reports the real change), a number (max 50 paragraphs), or an "
        "argument contract (content is literal unless regex=True). Say which claim you picked. "
        "STEP THREE, make ONE ordinary call designed to make that claim false. Ordinary is the "
        "point: the caller who gets hurt is the one who believed the sentence, not one hunting "
        "for an exotic input. If it says only, try the thing it excludes. If it says bounded or a "
        "maximum, hand it something far bigger and see whether the bound bites AND says so. If it "
        "says auto-detect, give it something plausible and check what it actually chose. If it "
        "promises the answer's shape, read the response and check nothing else came back. "
        "STEP FOUR, the other direction: name anything the tool DOES that its description does "
        "not mention. List your scratch directory before and after every call, so you can say "
        "exactly what appeared: a second file, a backup, a chart you did not ask for, a "
        "directory. Also check whether the INPUT you passed came back modified. An undeclared "
        "side effect counts the same as a broken claim. "
        "Record each tool as HELD, BROKEN or VAGUE. VAGUE is for a description carrying no "
        "checkable claim, or one you could not work out a call from: say what you had to guess "
        "and whether the guess worked. "
        "Two things that are NOT findings: a tool refusing exactly what its description says it "
        "refuses is the contract working, so record HELD; and a capability the description never "
        "claims is not a broken promise -- judge the sentence that is there. "
        "Not every server takes a data file: arithmetic tools take an expression, browser tools "
        "take a URL -- use https://example.com/. Document tools take a document: "
        "/workspace/data/BBCA_filing.pdf, a real 183-page filing, and /workspace/data/"
        "BBCA_instance.zip, which is an archive and not a document at all -- what a tool claiming "
        "to identify a document says about a container is exactly this round's question. Do not "
        "modify or delete either; write every output under your own scratch directory. The filing "
        "is big: ask about a few pages at a time, and a refusal because the answer would be too "
        "large is that tool testing its own 'bounded' claim -- record what it suggested and "
        "whether following the suggestion worked. "
        "Two contracts that are deliberate, so they are not findings: one server answers ok "
        "rather than success and carries no op or token_estimate -- record that once as that "
        'server\'s shape. And bold and italic are the quoted strings "true", "false" and "" '
        "rather than JSON booleans, because a boolean cannot say 'turn it off'; a refusal naming "
        "the quoted form is that contract working, so send the quoted form and carry on. "
    ),
    "unit": "claim",
    "columns": (
        "tool name | its description quoted EXACTLY | the claim you tested | the call you made "
        "to break it | HELD / BROKEN / VAGUE | what it did that its description never mentions | "
        "notes"
    ),
    "columns_ops": (
        "op name | the description sentence that covers this op, quoted | the claim you tested | "
        "the call you made to break it | HELD / BROKEN / VAGUE | what it did that the description "
        "never mentions | notes"
    ),
    "fs_extra": {
        "fsw1": (
            "fs_write's entire description is 'Write, edit, move, copy, download a URL, restore. "
            "Delete needs a token.' -- six verbs for sixteen ops, so most of what you run here is "
            "undeclared and that is the phase's main question. For each op say whether the "
            "description names it at all. Then test the verbs it does name: does copy leave the "
            "original where it was, and does move remove it? Is restore a real op, and what does "
            "it restore? Does replace_text report a count that matches the number of replacements "
            "actually in the file -- read it back and count them yourself."
        ),
        "fsw2": (
            "'Delete needs a token' is the claim, so attack it three ways: delete with no token, "
            "delete with a token from a DIFFERENT request, and delete twice with the same token. "
            "All three must be refused and the refusal must say which case it hit. download is "
            "the only verb in that sentence that reaches the network: use https://example.com/ "
            "and check the byte count it reports against the file it actually wrote. "
            "set_permissions and the line-editing ops are not in the description at all -- record "
            "them as undeclared, and check set_permissions reports the mode it really set by "
            "reading it back."
        ),
        "fsr1": (
            "One claim per tool, and both are unusually precise. fs_read says 'Bounded always': "
            "find the bound and make it bite -- read the biggest file in /workspace/data with "
            "mode=content, and record whether it truncates, whether it SAYS it truncated, and "
            "whether it tells you the true total. A bound that is silent breaks the word always. "
            "fs_query says 'content is literal unless regex=True': search for a string containing "
            "regex metacharacters -- a dot, a bracket, .* -- with regex unset. Literal means those "
            "characters must match themselves and nothing else. Then run the identical pattern "
            "with regex=True and compare the two counts; if they are equal, one of the two modes "
            "is not doing what the sentence says."
        ),
        "fsr2": (
            "Three descriptions, three argument or shape claims. fs_index claims "
            "'build/query/list file index or read operation receipt history' -- run all four and "
            "check whether list tells you how many entries EXIST or only how many it returned. "
            "fs_manage claims four things including a 'snapshot version list' -- run all four and "
            "check versions actually shows the snapshots the write ops in earlier phases left "
            "behind. fs_archive's description is an argument contract, 'path=archive, target=what "
            "goes in it' -- swap the two deliberately and check the error names the right one, "
            "then create and extract for real and compare the files byte for byte."
        ),
    },
}
