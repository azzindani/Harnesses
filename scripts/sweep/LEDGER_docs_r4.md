# MCP_Documents — sweep round 4

Same process as rounds 2 and 3: one hard document, every tool, an oracle from a
different tool chain, and the output rendered and read.

**Axis: what a tool LEAVES BEHIND — for its caller, for the next tool, and on
disk.** Rounds 1-3 asked whether each answer was right. This round asks whether
two of this server's own answers about the same page can both be right, and
whether the files the edit tier writes are the files a caller wanted.

## Phases

| # | phase | verdict | note |
|---|---|---|---|
| 1 | `to_markdown` table fidelity, bilingual pages | **DEFECT 1** | drops every PDF table and reports `tables: 0` |
| 2 | `basis` audit across the edit tier | PASS | absent by design where nothing is extracted |
| 3 | render every edit-tier artefact and read it | **DEFECT 3, 4** | `convert(to='images')` resolution; its refusal hint |
| 3b | ruled table cells, read as a reader | **DEFECT 2** | multi-line cells come back word-scrambled |
| 4 | cross-tool contamination (#55) across all 13 | **DEFECT 5** | probe under-reports by 12.9% once pages are read |
| 5 | handover chains (#12), no hand-written constants | PASS | every suggested range works when followed |
| 6 | re-extract all 183 pages, rebuild the report, read it | PASS | 501/501 figures, 39 pages, 11 real tables |

## Defects

### DEFECT 5 — a document that shrank by 12.9% as it was read

The best of the round, and found by the cheapest thing here: ask a tool, run a
different tool, ask again, diff. Round 2 found one such pair by accident; this
was the full matrix, 9 calls × 8 others, on a PDF and an HTML file.

    probe()                        -> 171,634 tokens, 8 pages fit
    extract(pages='6-7'); probe()  -> 171,516 tokens
    (all 183 pages read); probe()  -> 149,410 tokens, 9 pages fit

`Page.char_count` summed the spans of whatever blocks were cached, and
`load_page_words` REPLACES a page's line blocks with one block per WORD —
dropping every space. So the count falls by one character for every space on
every page anyone has looked at.

`token_estimate_full` is the number whose entire job is telling a caller why
they must not ask for the whole document, and it moves **downward** as they
read — the dangerous direction — far enough to move
`pages_that_fit_one_response` from 8 to 9, so the range `probe` recommends
overflows the response it was sized for.

Round 2 introduced `Page.raw_text` and routed `Page.text` and
`Page.is_scanned` through it; both carry a comment explaining exactly this
hazard. `char_count` sits **between those two properties in the file** and was
left counting blocks. *A fix that stops at its own siblings is half a fix* —
and the two neighbours documenting the trap did not prevent it.

### DEFECT 2 — a ruled cell read across its own lines

`core/tables._rows_from_words` ended `inside.sort(key=lambda w: w["x0"])`.
Right for a cell holding one line; a cell holding wrapped text is read ACROSS
the lines instead of down:

    x0 order : Name: Title: President Edward Rogers and CEO
    reading  : Name: Edward Rogers Title: President and CEO

    x0 order : SITE (Date signed agreements) purchase COMMITMENT for DATES leases delivery or of
    reading  : SITE COMMITMENT DATES (Date for delivery of signed leases or purchase agreements)

Measured across 54 corpus PDFs, 189,463 filled cells: 285 span more than one
line, **254 come back scrambled, and all 254 are from `ruled` tables** —
`confidence: 0.95`, the highest in the vocabulary. Zero from whitespace tables,
which build one row per text line and so cannot have a multi-line cell. 18 of
54 documents; one pharmaceutical supply agreement had 45 such cells, each an
entire contract clause turned into word salad.

Every table fixture in the repo had one line per cell, which is exactly why 326
tests missed it: for a single-line cell, x order IS reading order.

**Four candidate fixes, scored against an oracle before any was shipped.**
pdfplumber's own `extract_text_lines()` is a different code path in the same
library that segments a page into lines without knowing tables exist; 170
documents, 181,240 filled cells:

|  rule | agrees with the oracle | single-line cells it disturbed |
|---|---|---|
| sort by x0 (the bug) | 99.12% | — |
| sort by `(top, x0)` | **98.31%** | 2,874 |
| group tops within a measured 0.5pt | 99.45% | 932 |
| **vertical overlap (shipped)** | **99.63%** | **0** |

`(top, x0)` needs no constant and is the obvious fix. **It is worse than the
bug.** A line set in two type sizes has two different `top` values, so it gets
split and then ordered by type size. The 0.5pt tolerance was measured properly
— words pdfplumber puts on one line differ by 0.00pt at p99, and the step to
the next line is never under 0.62pt — and it still disturbed 932 cells that
were already correct, for the same reason. What shipped asks whether two words'
vertical extents overlap, needs no constant, and cannot change a single-line
cell at all.

### DEFECT 1 — a markdown conversion that reported no tables

Page 6 of the committed filing is a consolidated balance sheet. Three answers,
one session, one page:

| tool | answer |
|---|---|
| `extract_tables(pages='6')` | `count: 1`, shape `[38, 9]` |
| `read_page(6)` | the same table, in `result.tables` |
| `to_markdown(pages='6')` | **`"tables": 0`**, no table in the markdown |

`to_markdown` rendered only tables the FORMAT DECLARES. A PDF declares none —
its tables are reconstructed by `core/tables.py` — so no PDF table was ever
rendered, and the count of what HAD been rendered was published as `tables`.
21 of 21 sampled pages. Control: HTML and XLSX agree exactly (1↔1, 9↔9, 1↔1).
`convert(to='md')` routes through the same function.

Fixed by splicing **ruled** tables into the markdown — the file's own grid —
removing the word blocks the grid covers so no cell is printed twice, and
leaving `whitespace` reconstructions as text, because a pipe table asserts the
grid is real.

**The first version of the fix was itself a false claim, and measuring killed
it.** It reported `tables_left_as_text`, and pdfplumber's text strategy
proposes a grid for *essentially every page*, so a three-page prose document
came back claiming three tables — an over-claim replacing an under-claim.
There is no shape that separates the two: on this corpus a page of plain prose
has **100%** of its rows holding two or more cells and the real balance sheet
has **81%**, so any threshold rates the prose as more table-like. What ships is
a note with no number.

A two-row, two-column floor was added after rendering the result: pdfplumber
calls the two ruled boxes on the filing's cover page a 2×1 table, and rendering
that turned a readable title page into a one-column markdown table.

### DEFECT 3 — `convert(to='images')` used the memory ceiling as its quality setting

`budget.dpi_that_fits()` answers "the largest render that fits the budget".
`convert` used that answer as the resolution, so resolution became a property
of the batch:

| pages asked for | DPI | pixels per page |
|---|---|---|
| 1 | **600** | 33.7 MPx |
| 4 | 423 | 16.7 MPx |
| 20 | 189 | 3.3 MPx |
| 183 | 62 | refused |

Confirmed against the deployment: page 6 came back **5100 × 6601** in a
one-page call and **3596 × 4653** in a four-page call. Nothing about the page
changed, only its company. Four pages came to 8.8 MB of PNG.

The low end was guarded (it refuses under 72 DPI); the high end was not, and no
default existed anywhere. The sibling shows the standard the repo already
holds: `ocr()` renders at a fixed `DOCS_OCR_DPI=200` with its measurement in a
comment beside it. Now `convert` does the same — `DOCS_RENDER_DPI=150`,
measured by rendering this filing at 72/100/150/200 and reading the 6pt note
references — and the budget is a ceiling that can only lower it, saying so in
`progress` when it does.

### DEFECT 4 — the refusal named a tool that renders nothing

    "hint": "Render fewer pages, or accept 62 DPI by rendering a range with read_page()."

`read_page()` returns text, tables and links; it renders no image and has no
DPI. And `convert` has no `pages` parameter, so "render fewer pages" was not
available through the tool that had just refused either. **Both halves were
impossible.** The caller has to `assemble` a range first, which the hint never
said. It now names that, with the page count that fits.

## What passed

* **Cross-tool contamination, everything except `probe`.** 9 tools × 8 others
  on a PDF and an HTML file: `extract`, `find` (multi-word, single-word and
  regex), `read_page`, `extract_tables`, `to_markdown` and `outline` all return
  byte-identical answers whatever ran between two calls. The round-2 `raw_text`
  fix holds; only the count beside it did not.
* **Handover chains.** `probe` says 8 pages fit and `to_markdown`'s refusal
  suggests `1-9`; the two disagree because one counts every page and the other
  samples, and **following the suggestion works** — `to_markdown(pages='1-9')`
  returns 4,571 tokens against an 8,000 ceiling. `find`'s `pages` covers all 26
  hits while `matches` returns 4, with `truncated: true` saying so.
* **`assemble` rotation, rendered.** Source page 10 carries `/Rotate 90`; `r90`
  composes to 180 and the page renders portrait with its table running
  bottom-to-top. Correct.
* **`redact`, diffed as pixels.** The before/after renders differ in exactly
  one bounding box, `259.358.793` is gone from the image, and nothing else on
  the page moved. It removes the ink, not just the extractability.
* **`basis` on the edit tier.** `assemble`, `redact` and `protect` return none,
  which is right — `ok()` documents basis as required for anything *extracted*.
  `convert` inherits the read engine's basis for txt/md/html and claims
  `native` for pdf/images; `ocr` claims `ocr`. No constant left to strip.

## Phase 6 — the same measurement, after four fixes

Three of the five fixes touch extraction paths, so the round closed by re-running
round 2's measurement end to end against the redeployed server:

* **183 pages, 26 chunks, 0 failures, 699,641 characters, 80.9s.**
* **501 of 501 printed figures recovered** against the XBRL instance — the same
  number as rounds 2 and 3, and the 85 misses are the same taxonomy roll-ups
  that are absent from the PDF's own text layer.
* The report rebuilt: **39 pages, 11 real bordered tables**, rendered and read.
  Every figure fits on one line; the 586-row appendix wraps its identifiers in
  their own column and never breaks a number. The round-3 width rule holds.

## Outcome

Five defects. Two were found by the cheapest check available — call a tool, run
a different tool, call it again — and three by asking whether two of this
server's own answers about the same page could both be true.

**368 tests** green in both modes (was 326), CI green on all six jobs at
`ebda1a5`, container rebuilt, **13/13 smoke against the deployment**, and the
smoke test now covers `convert(to='images')` and `to_markdown` on a PDF, both of
which the coverage guard had been satisfied about by a sibling call.

**The technique worth keeping: measure the candidate fix, not the bug.** Two of
the five fixes had an obvious form that was worse than what it replaced —
sorting cell words by `(top, x0)` scored *below* the defect it fixed, and
counting a PDF's unrendered tables turned a three-page prose document into a
document with three tables. Both looked right in the code and in the one
document they were written against. Only running them across the whole corpus,
against an oracle produced by a different tool chain, separated them from the
rules that shipped.

**Round 5:** `outline` and `find` are the two read tools this round did not
put under a second, independent computation; and no round has yet asked what
`protect` leaves behind — an encrypted file's own metadata, and whether a
permissions-only change is visible to a reader that is not this server.
