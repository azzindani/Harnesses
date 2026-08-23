"""The prose a sweep prompt is assembled from.

Every block here is stable across rounds. What changes from one round to the
next is the *axis* -- the question the round is asking -- and that lives in
axes.py, one entry per round. Keeping the two apart is the point of this
package: for ten rounds the axis was a constant inside a throwaway generator
script, so changing the round's theme meant rewriting the generator, and the
wording of the parts that were working fine drifted every time it was retyped.

Edit a block here when a rule needs to change for good. Edit axes.py when the
round changes. Do not paste round-specific wording into a block.

None of this text may name a host, domain or token: these prompts are sent to a
third-party model on every phase.
"""

from __future__ import annotations

# --------------------------------------------------------------------------
# Stable blocks
# --------------------------------------------------------------------------

PREAMBLE = (
    "Coverage sweep round {round}, phase {n} of {total}. Work only inside /workspace/data. "
    "NEVER modify, move, rename, delete or overwrite /workspace/data/{fixture} -- it is "
    "the fixture every later phase depends on; copy it if you need a writable version. "
    "Do all scratch work under /workspace/data/{scratch}/. Create that directory with the "
    "filesystem server's fs_write create_dir op, NOT with a bash mkdir: the MCP services write "
    "as a different user than your shell, so a directory bash creates is not writable by them "
    "and the first tool that tries to save into it fails with Permission denied. "
    "Call EVERY tool named below, one at a time, even ones that look redundant: this is a "
    "coverage sweep, not a task, so do not skip a tool because it resembles one you already "
    "ran. Work out the arguments from each tool's own description -- if you cannot, that is "
    "a finding, so record the exact error text and move on rather than guessing repeatedly. "
    "Keep your replies short. "
)

# Some servers only have anything to say about an artifact an earlier phase
# built. Without this the model builds a fresh empty one and reports that
# everything works on it.
REUSE = (
    "Some tools here need something an earlier phase produced -- a trained model, a document, "
    "a workbook. Find it first with the matching list or inspect tool and reuse it; build a new "
    "one yourself only if none exists. "
)

# Round 10: nearly every defect that round came from a PASS row with a
# recomputation beside it, and none from a row that only read back the tool's
# own success flag.
VERIFY = (
    "Do not trust the success flag. For at least THREE of the tools in this phase, also check "
    "the answer against something else: read the written file back and confirm it holds what you "
    "asked for, or recompute one number a second way and compare. A tool that reports success "
    "while returning a wrong number, an empty file, or a value it silently ignored an argument "
    "to produce is the most valuable finding in this sweep -- more valuable than any refusal. "
)

# Two attempts at round 11 phase 1 did the work and stopped before writing
# anything. A phase that produces no report produces no findings however much it
# exercised.
INCREMENTAL = (
    "WRITE THE REPORT AS YOU GO, not at the end. After the FIRST tool's {unit}, create the report "
    "file with its header row and that tool's row. After every tool after that, append its row "
    "to the file immediately, before you call the next tool. A report covering six tools is "
    "worth far more than a complete one you never got to write. "
)

REPORT = (
    "At the end write a markdown report to /workspace/data/{report} with one row per tool and "
    "these columns: {columns}. Put the exact error text in notes for any failure, and for the "
    "tools you cross-checked, what you compared against and whether it matched. "
    "There are exactly {count} tools to call in this phase: {names}."
)

REPORT_OPS = (
    "At the end write a markdown report to /workspace/data/{report} with one row per "
    "operation and these columns: {columns}. Put the exact error text in notes "
    "for any failure. There are {count} operations to run in this phase."
)


# --------------------------------------------------------------------------
# File_System phases
# --------------------------------------------------------------------------
# File_System exposes six tools that each carry a dozen operations behind an
# `op`/`action` argument, so "call every tool" covers it in six calls and proves
# nothing. These phases name the operations instead. The {axis_fs} slot is where
# a round says what to do with each operation; a round that has nothing
# File_System-specific to add leaves it empty.

FS_PHASES = [
    (
        "filesystem: fs_write, part 1",
        "fsw1",
        "report_fs_write_1.md",
        8,
        "This phase exercises ONE tool -- filesystem: fs_write -- across eight of its ops. Run "
        "each op as its own fs_write call. The ops are: "
        "write_file, append_file, create_dir, copy, move, rename, replace_text, insert_after. "
        "After every call use fs_read to confirm what is actually on disk.",
    ),
    (
        "filesystem: fs_write, part 2",
        "fsw2",
        "report_fs_write_2.md",
        8,
        "This phase exercises ONE tool -- filesystem: fs_write -- across the other eight of its "
        "ops. The ops are: delete_lines, patch_lines, "
        "set_permissions, download, delete_request, delete_confirm, delete_tree_request, "
        "delete_tree_confirm. The two delete_*_request ops return a token that its matching "
        "confirm op needs -- carry it across, and try REUSING a spent token a second time, which "
        "must be refused. For download use https://example.com/ as the url. After every call use "
        "fs_read to confirm what is on disk.",
    ),
    (
        "filesystem: fs_read modes and fs_query",
        "fsr1",
        "report_fs_read.md",
        7,
        "This phase exercises two tools -- filesystem: fs_read and fs_query -- across every mode "
        "each accepts. fs_read: modes auto, content, "
        "meta, tree and diff (diff needs a second path). fs_query: search /workspace/data once by "
        "filename pattern and once by file content. Also "
        "check fs_read mode=content returns the same bytes the file really holds.",
    ),
    (
        "filesystem: fs_index, fs_manage, fs_archive",
        "fsr2",
        "report_fs_actions.md",
        8,
        "This phase exercises three tools -- filesystem: fs_index, fs_manage and fs_archive -- "
        "across every action they accept. fs_index: "
        "action build, query, list, stats, receipt and clear. fs_manage: action disk_usage, "
        "permissions, symlink_info and versions. fs_archive: action create to build a .zip and "
        "again a .tar.gz, then action extract. Confirm the extracted "
        "files match the originals byte for byte.",
    ),
]
