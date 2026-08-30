# MCP_Documents — sweep round 3

Same process as round 2, plus one thing round 2 did not do: **look at the
output.**

The user's report of the defect was "in the word file, table is very bad", and
they were right. Round 2 produced a 34-page report, verified it had 34 pages,
verified every figure was present by grep, and never rendered a single page.
Every check passed and the document was unusable.

**Axis: render the artefact and read it as a reader would.** Not "is the content
present" — that was already true — but "can it be read".

## Phases

| # | phase | verdict | note |
|---|---|---|---|
| 1 | render the round-2 report and read it | **DEFECT 3** | tables were space-aligned text in a proportional font |
| 2 | `add_table` output, rendered | **DEFECT 4** | no borders, equal columns, figures broken mid-number |
| 3 | `optimize` compress vs an independent reader | PASS | 183 pages, text byte-identical, 0 of 501 figures lost |
| 4 | `probe.page_size` on a multi-geometry document | **DEFECT 5** | page 1's geometry reported as the document's |
| 5 | regenerate the report and read it again | PASS | 38 pages, real tables, no broken figures |

## Defects

### DEFECT 3 — a report whose tables were pictures of tables

Round 2's report wrote every table as space-aligned text inside a paragraph.
That is monospace thinking; Word sets body text in a proportional face. Rendered,
the columns did not line up, and in the 501-fact appendix **every row wrapped**,
dropping the value onto the next line at the left margin with nothing tying it
to its fact:

    DecreaseIncreaseInConsumerFinancingReceivables
    CurrentYearDuration          -500.427

A reader cannot tell which number belongs to which fact. In section 11 the same
fault put the word `TOC` alone on a line at the left margin, mid-column.

Mine, not the server's. Fixed by writing prose through `create_from_sections`
and every table through `docx-tables.add_table`, with markers reserving each
table's position. Note that `create_from_sections` puts a whole section body in
ONE paragraph, so a marker is trailing text rather than its own paragraph —
which is still the right insertion anchor.

### DEFECT 4 — `add_table` drew no lines and split the page evenly

In MCP_Microsoft_Office, not MCP_Documents. Found only because the fix for
DEFECT 3 routed real tables through it.

`doc.add_table(rows, cols)` applies python-docx's default "Normal Table", which
draws **no borders at all**, so Word shows columns of text floating in
whitespace. And python-docx writes a `tblGrid` of equal fractions, so a column
holding `DecreaseIncreaseInPlacementsWithOtherBanksAndBankIndonesia` got the
same third of the page as one holding `4.019`, breaking the identifier mid-word
across three lines.

**`table.autofit = True` does not work** — it sets `tblLayout`, and both Word
and LibreOffice still lay out on the grid widths. Explicit widths are honoured
by both, and must be set on every **cell**, not only the column: Word reads
per-cell `tcW` and treats `gridCol` as a hint, so setting only the column looks
right in LibreOffice and changes nothing in Word.

**Two measured iterations of the width rule, both caught by rendering:**

1. Straight proportion to the longest cell → 3.21in / 1.52in / 1.26in, which
   broke `CurrentYearDuration` and `1.640.830.566`. Trading a wrapped
   identifier for a wrapped figure is a loss: the first is cosmetic, the second
   invites a misread.
2. Square-root damping → fixed that case, but on the real appendix (context
   column 120 characters) the value column came out 1.08in and broke
   `-17.906.497` into `-17.906.4 / 97`.
3. Shipped: a column asking for **no more than an even share is given what it
   asks for**, and only the greedy columns compete for the remainder. Rendered,
   every figure fits on one line.

### DEFECT 5 — one page size for a document with three

`probe` reported `page_size: [612.0, 792.0]` for the BBCA filing. That is page
1's geometry. The document is 178 pages of US Letter portrait, **one A4, and
four LANDSCAPE pages carrying /Rotate 90** — and those four hold the widest
tables in it, which is exactly what a caller needs to know before asking for
them.

This is the per-document verdict the module rejects everywhere else: `scanned`
is reported as counts and a selection string precisely because one boolean would
be a lie about half a hybrid document. Geometry was the last property still
answering for the whole document from a sample of one page — and the sample was
not chosen, it was page 1 because page 1 is first.

Now reports the most COMMON size (a cover page is routinely a different size
from the body) and, when the document holds more than one,
`pages_of_other_size: "2,10-11,180-181"` in the same paste-able form as
`scanned_pages`. Omitted entirely for a uniform document, because
`pages_of_other_size: ""` would read as "some differ and we cannot say which".

## What passed

* **`optimize(compress)`** on the 183-page filing: 2,713,904 → 2,654,389 bytes,
  183 pages preserved, extracted text **byte-identical**, 0 of 501 XBRL figures
  lost, and an honest `note_images` that image downsampling needs Ghostscript.
* **The regenerated report**: 38 pages, 14 real tables, 670 rows, and rendered
  every figure fits on one line.

## Outcome

Three defects, all found by looking at output rather than by asserting content
exists. Two in MCP_Documents, one in MCP_Microsoft_Office.

**The technique this round is worth keeping: render the artefact and read it.**
Content-presence checks — page counts, greps for figures, `read_table`
returning cells — all passed on a document that could not be read. There is no
substitute for looking at the pixels, and the fix for the table widths took
three measured attempts, each rejected by a render.

**Round 4:** the `basis` audit across the remaining edit-tier tools, and
`to_markdown` table fidelity on the bilingual pages.
