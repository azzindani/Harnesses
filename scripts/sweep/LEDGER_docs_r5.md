# MCP_Documents — sweep round 5

Same process as rounds 2-4: real documents, an oracle from a different tool
chain, the output read rather than counted, and the candidate fix measured
before it ships.

**Axis: the claims nobody checks — a zero, a permission, and a file read back
by something that is not this server.** Rounds 1-4 checked answers that say
something. A `0`, an empty list and a `verified: true` all look like clean
passes.

## Phases

| # | phase | verdict | note |
|---|---|---|---|
| 1 | `find` — construct the match and demand it be seen | **DEFECT 1, 2, 3** | exact on every value; the failure modes were elsewhere |
| 2 | `outline` vs `to_markdown` vs a second computation | PASS | exact against lxml, python-docx and pikepdf |
| 3 | `protect` read back by a reader that is not this server | **DEFECT 4, 5** | it removed the lock and called it a permission change |
| 4 | `redact` verified by something other than what wrote it | PASS | pypdfium2 agrees, and the page survives |
| 5 | every negative claim across all 13 tools | **DEFECT 6** | `basis: "empty"` beside `found_before_filter: 1` |
| 6 | rebuild the report, render it, read it | | |

## Defects

### DEFECT 1 — a regular expression that never came back

`find(regex=True)` compiles a pattern the CALLER wrote and runs it over every
page. `re` has no timeout and no step limit, so `(\s*\w+)+$` — the textbook
nested quantifier — backtracks super-exponentially. Against **one page** of the
BBCA filing it was still running when it was killed at **120 seconds**.

On a deployed HTTP server that is not a slow answer, it is a worker that never
returns: the client times out, the process keeps burning a core, and nothing in
the response, the log or the health check says why. The module's own docstring
advertises regex as "the custom-parsing path", so the pattern arrives from
outside by design.

Fixed by running the match in a child process the parent can kill, with three
measurements deciding the shape rather than an argument:

* the worst **legitimate** pattern over all 183 pages — ten were timed,
  including a two-named-group parser and a leading `.*` — takes **0.324s**, so
  a 10s ceiling is thirty times the real worst case and unreachable by anything
  that finishes;
* the child costs **~10ms warm, ~78ms on a process's first call**, against the
  seconds `find` already spends reading the document. Python 3.14 starts
  children with `forkserver` on Linux, which is safe from a server's worker
  thread; plain `fork` inherits locks other threads hold;
* a terminated child stops the backtracking dead — alive after 3s, SIGTERM,
  exitcode −15, parent unharmed.

A literal query has been through `re.escape`, holds no quantifier and cannot
backtrack, so it stays in-process and pays nothing.

### DEFECT 4 — `protect(action='permissions')` removed the lock

Permission flags live inside a PDF's encryption dictionary, so changing them
means re-encrypting, which needs the owner password. Without one the code fell
through to `encryption=False`, and pikepdf saving with no `encryption=`
argument writes an **unencrypted** file.

Handed a document encrypted with printing and copying forbidden:

    success: true, action: "permissions", encrypted: false
    progress: ["permission flags cleared"]

and the output opens in any reader with no password at all. The action is named
after the flags, the progress line describes the flags, and the one field that
told the truth — `encrypted: false` — sits next to an action name that says
nothing about encryption.

Found by reading the result back with **pypdfium2** instead of pikepdf, which
is what wrote it. A writer and its own reader agree with each other.

Now refused, like `encrypt` and `decrypt` already were, and the refusal writes
no file.

### DEFECT 5 — `pikepdf.Permissions()` is a set of defaults, not an empty set

Writing the report field exposed two more, both from the same habit. The
default constructor sets `modify_assembly=False`:

* **`protect(action='encrypt')` passed no `allow=` at all**, so encrypting a
  document quietly withdrew permission to reorder its own pages — from the
  caller holding the password.
* **`permissions` cleared seven of the eight flags** for the same reason, while
  its no-password path (the one that dropped encryption) cleared all eight. One
  action, two outcomes, neither stated anywhere.

And the docstring said "**set** permissions" for a tool that takes no
permissions argument and can only ever clear them.

Every flag is now spelled out, both paths use the same set, and the response
carries `restrictions` — what the file still forbids, read back off the disk —
so the claim is checkable by a reader that is not this server.

### DEFECT 3 and 6 — `basis: "empty"` about documents that are not empty

`empty` is the only basis worth 0.0 confidence, and `core/ir` defines it as
"nothing here to obtain". Two tools said it about pages they had just read:

* **`find` returned it whenever nothing MATCHED.** A fruitless search of the
  183-page born-digital filing described the document the way it describes a
  blank page — in a session where `probe` reported 182 born-digital pages and a
  full text layer.
* **`extract_tables` returned it whenever `min_confidence` filtered every table
  out** — in the same response object as `found_before_filter: 1`, about a page
  whose table it had just read at confidence 0.95. Two fields of one object,
  contradicting each other.

Both describe the OUTCOME of a query with a field that describes how the
CONTENT was obtained. Finding nothing is a fact about the query; filtering is a
fact about the caller. `empty` still applies where it belongs — a page with no
text layer, a format with no tables at all — and tests hold both directions.

### DEFECT 2 — a hint that asked for more than it could give

`find` returns `min(max_hits, what the response budget affords)` matches — 400
by default, 100 constrained. Past that point `max_hits` is not the limit that
bit, and the hint said to raise it anyway:

    max_hits=500     hits=2360  returned=400  "... or raise max_hits."
    max_hits=5000    hits=2360  returned=400  "... or raise max_hits."
    max_hits=50000   hits=2360  returned=400  "... or raise max_hits."

A caller who follows a hint and gets a byte-identical response has been told
nothing. Same shape as round 1's budget refusal that named a range its own
estimator refused, and round 4's refusal that named a tool which renders no
images. The hint now names whichever limit actually bit, and `returned_limit`
puts the ceiling in the response instead of leaving it to be found by bisection.

## What passed

* **`find`'s correctness, exhaustively.** Against page text read by
  **pypdfium2** — a different engine from the one the server extracts with —
  plain queries (5/5, 26/26, 20/20 exact), four queries that must return zero,
  case folding consistent with itself, four regexes, the `pages=` filter
  per page, and `max_hits` bounding what is returned while never touching
  `hits` or `pages`. One apparent disagreement on `^Catatan` was **my oracle**:
  `find` sets `re.MULTILINE` deliberately, so `^` anchors per line, which is
  the right definition for a document search.
* **`outline`, exact against three independent computations** — lxml's own
  `h1`-`h6`, python-docx's style names, and pikepdf's outline tree — and its
  never-before-asserted twin agrees: `to_markdown` marks the same titles at the
  same levels, and reports the same count where there are none.
* **`redact`, verified by an engine that did not write it.** pypdfium2 sees the
  figure before and not after, the page count is unchanged, a neighbouring
  figure survives, and **4,755 of 4,767 characters remain** — the 11-digit
  figure and one space. A redaction that empties the page would also pass "the
  secret is gone", so the survival check is the one that matters. (A fourth
  check, searching the raw content streams, found the digits in *neither* file:
  a subset font addresses glyphs by index, which is the documented reason
  `redact` decodes via `/ToUnicode`. My oracle, not a defect.)

## Phase 6 — the same measurement, after six fixes

Three of the six touch the read path, so the round closed by re-running round
2's measurement end to end against the redeployed server:

* **183 pages, 26 chunks, 0 failures, 699,641 characters, 79.8s.**
* **501 of 501 printed figures recovered** against the XBRL instance — the same
  number as rounds 2, 3 and 4, with the same 85 taxonomy roll-ups proven absent
  from the PDF's own text layer.
* Report rebuilt: **39 pages, 11 bordered tables**, rendered and read. Every
  figure on one line, identifiers wrapping inside their own column.

## A seventh, found by CI

The regex guard named `"forkserver"` explicitly. That type-checks on Linux and
**fails pyright on the Windows runner**, where it is not a valid start method
at all, so the overload collapses to `BaseContext` and `.Process` is unknown.
One error, one platform, invisible on the machine it was written on — the
fourth time this repo has been corrected by a second machine.

`mp.get_context()` with no argument is the one spelling that resolves
everywhere, and the default is already the right method on each platform:
forkserver on Linux since 3.14, spawn on macOS and Windows. All three pickle
their arguments, which is the property the guard actually needs.

## Outcome

Six defects plus the CI one. Two of them — the runaway regex and the silent
decrypt — are the kind that do not show up as a wrong number: one is a worker
that never returns, the other is a lock that is gone.

**407 tests** green in both modes (was 368), ruff and pyright clean, container
rebuilt, **13/13 smoke against the deployment** including four new checks for
exactly the answers this round changed.

**The technique worth keeping: read the artefact back with something that did
not write it.** Every previous check of `protect` used pikepdf, which is what
`protect` writes with, and a writer and its own reader agree with each other.
One call to pypdfium2 said the "permission change" had removed the encryption.
The same move confirmed `redact` genuinely works, and a third reader —
pypdfium2's text layer — confirmed every value `find` returns is exact.

**And: a negative answer is a claim.** Three of the six were a `0`, an empty
list, or a `basis: "empty"` — all of which look like clean passes and none of
which had a test.

**Round 6:** `assemble`'s selection grammar has never been fuzzed against
inputs that are valid strings but nonsense selections; and `optimize(repair)`
has only ever been run on a file that did not need repairing.
