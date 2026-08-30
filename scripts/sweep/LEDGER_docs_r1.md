# MCP_Documents — sweep round 1

First sweep of the seventh repo. Not run through the opencode harness: driven
directly from a Claude Code session that has `docs-read` and `docs-edit`
connected as MCP servers, because the axis needs a second method and only a
session with the full toolchain can recompute an answer independently.

**Axis: judge every answer against a second, independent computation.**
Never against the response's own success flag, and never against another tool
in the same server. Where a claim can be checked with pikepdf, pypdfium2,
pdfplumber or a shell tool, it is.

**Inputs are real documents.** `/root/Evals` is mounted read-only at `/corpus`
in the container: 170 PDFs — invoices that are photographs, 600-page
regulations with scanned plates, court judgments, resumes. Five of this repo's
six pre-deployment defects came from documents like these and none from a test
anyone thought to write.

Target: `https://docs.casava.space` — the deployment, not a local container.

## Pre-sweep

| check | result |
|---|---|
| `Ad_Data.csv` md5 | `9a16b9248526466960194df4eb7a3e90` ✅ pristine |
| tools enumerated from `tools/list` | 7 read + 6 edit = 13 ✅ matches the documented ceiling |
| corpus reachable from the container | 170 PDFs at `/corpus`, read-only ✅ |
| endpoint | `/health` ok, 401 without a token ✅ |

## Phases

| # | phase | verdict | note |
|---|---|---|---|
| 1 | probe vs an independent reader | **DEFECT 1** | page counts exact; `page_kinds.scanned` always 0 |
| 2 | outline vs the document's real headings | PASS | 89/89 tagged entries exact; empty path correct + honest hint |
| 3 | find vs an independent extractor's count | PASS | 35 hits / 30 pages, exact on a 238-page regulation |
| 4 | extract vs independent text, and the budget refusal | **DEFECT 2** | text correct; the range the refusal names does not fit |
| 5 | extract_tables vs a real table | **DEFECT 4** | no invented values; ruled cells truncated |
| 6 | read_page vs independent page text | **DEFECT 3** | word-exact where it runs; crashes on 12/170 documents |
| 7 | to_markdown structure fidelity | **DEFECT 2,3** | shares the budget hint and the crash |
| 8 | assemble page counts and order | UNFINISHED | round 2 |
| 9 | convert, every target | UNFINISHED | crash confirmed + fixed; targets not yet swept |
| 10 | optimize byte deltas and repair | UNFINISHED | round 2 |
| 11 | ocr on a real scan, verified by re-reading | UNFINISHED | round 2 |
| 12 | protect encrypt/decrypt round trip | UNFINISHED | round 2 |
| 13 | redact on a real subset-font document | UNFINISHED | round 2 |
| 14 | determinism: identical call twice, diffed | PASS | 35 tool/document pairs x 3 calls, byte-identical |
| 15 | `basis` honesty across formats | UNFINISHED | round 2 |

Verdicts: PASS · DEFECT · UNFINISHED.

## Defects

### DEFECT 1 — `page_kinds.scanned` is always 0, and contradicts `scanned_pages`

`probe` of a 1 MB scanned invoice, 1 page, zero extractable characters:

    "page_kinds": {"born_digital": 0, "scanned": 0, "empty": 1},
    "scanned_pages": "1",
    "basis": "empty"

`scanned: 0` for a document that is nothing but a scan, while `scanned_pages`
in the same response says page 1 is scanned. Confirmed independently: the page
carries one image XObject and a 44-byte content stream — it is a scan, not a
blank. Same on `IDX_BBCA_Q1_2026_Financial_Statement.pdf` (183 pages, one
scanned signature page): `scanned: 0, empty: 1` beside `scanned_pages: "2"`.

Cause, `servers/docs_read/_read_probe.py:88-94` and `:142`:

    if page.char_count == 0:
        empty.append(number)
        scanned.append(number)      # <- both lists
    elif page.is_scanned:
        scanned.append(number)
    ...
    "scanned": len(scanned) - len(empty),

A zero-character page is counted twice and then subtracted back out. Only a
page in the 1..31 character band (`MIN_CHARS_FOR_TEXT_LAYER`) can ever be
reported as scanned — and a real scan extracts exactly zero.

**Why 216 tests missed it:** the `hybrid.pdf` fixture's pages measure
`[769, 769, 0, 1]`. The page with **1** character lands in the counted band, so
`page_kinds` reads `{born_digital: 2, scanned: 1, empty: 1}` and looks right.
The fixture masks the defect because it was built with a stray glyph.

**Why it matters:** `page_kinds` is the count a caller branches on to decide
whether to OCR. It says there is nothing to OCR while `scanned_pages` hands
over a page range to OCR.

### DEFECT 2 — the page range a budget refusal names does not fit

    extract(UU Nomor 20 Tahun 2025.pdf)        -> refused, "Use extract(pages='1-23')"
    extract(..., pages='1-23')                 -> refused, "Use extract(pages='1-20')"
    extract(..., pages='1-20')                 -> success

Following the hint verbatim fails. The whole point of `refuse()` over `fail()`
is that the caller did nothing wrong and the hint carries a value that works.

Cause: `core/budget.pages_that_fit(total_chars, page_count)` divides the
document's TOTAL characters by its page count and applies that mean to the
FIRST n pages. Measured on this document: mean 1,358 chars/page, but pages 1-23
average 1,522 — front matter is denser than the mean, so 23 pages is 35,027
characters against a 32,000 budget. The true cumulative answer is 21.

The second refusal is right, because a range was supplied and the estimate was
computed over those pages. Only the no-range case is wrong — which is the one
every caller hits first.


### DEFECT 3 — IndexError out of five tools, on 12 of 170 real documents

    read_page(a supreme-court judgment, page 1)
      -> isError: true, "Error executing tool read_page: list index out of range"

No `success`, no `error`, no `hint`, no `token_estimate`. The contract says
every failure is a dict carrying all four and that no exception leaves an
engine module.

`core.order.gutter_positions` sizes its crossings array to `int(page.width) + 1`
and then scans `range(left, right + 1)` where `right` comes from the BLOCKS.
Writes into the array were clamped with `min(width, ...)`; reads were not.
Measured: page width 595.3, rightmost block 645.8, so `crossings[645]` on an
array of 596.

Every Indonesian supreme-court judgment in the corpus carries a rotated margin
watermark outside its own MediaBox — 12 of 170 documents. Five of thirteen
tools go through `detect_columns` and all five raised: **outline, extract,
read_page, to_markdown, convert**. `probe` and `find` do not, so the documented
probe -> find -> extract path answered twice and then threw.

### DEFECT 4 — the ruled table path truncates cell values too

    ruled cell: "Ditambah/(Dikurangi)Keberata"      the page says "Keberatan"

The whole-word rebuild had been applied to the `whitespace` strategy only, on
the reasoning that a ruled table's rules sit between cells so no word can
straddle one. pdfplumber assigns characters by position and clips at the cell
edge whichever strategy found the cell. High confidence made it worse: 0.95 on
a word missing its last letter, under a note that only warns about the shape.

## Outcome

Four defects, all confirmed against real documents and against a second,
independent computation. All four fixed, each with a regression test named for
the wrong answer, and each verified to FAIL with its fix stashed (13 failures
without, 41 passing with). Suite: 248 tests green in both modes, up from 216.

Phases 8-13 and 15 — the docs-edit tier and the `basis` audit — are unfinished
and carried to round 2.
