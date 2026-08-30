# MCP_Documents — sweep round 2

Second sweep of the seventh repo, driven directly from a Claude Code session
with `docs-read`, `docs-edit`, `office-*` and `math` connected as MCP servers.

**Axis: one hard document, read end to end, every answer judged against a
second independent computation.** Round 1 swept the read tier broadly across
170 documents. This round goes the other way: one document, all thirteen tools,
and an oracle strong enough to check every figure rather than a sample.

**The input.** `IDX_BBCA_Q1_2026_Financial_Statement.pdf` — PT Bank Central
Asia's Q1 2026 consolidated financial statements. Chosen because it is hard,
not because it is representative:

| property | value |
|---|---|
| pages | 183 |
| bytes | 2,713,904 |
| geometries | 3 — 178x Letter portrait, 1x A4, 4x Letter landscape |
| rotation | 4 pages at /Rotate 90 |
| text layer | 722,767 characters; page 2 is a scan with none |
| languages | Indonesian and English, in parallel columns throughout |

**The oracle.** `IDX_BBCA_Q1_2026_instance.zip` — the XBRL instance of the SAME
filing, submitted by the same issuer alongside the PDF and produced by a
different tool chain. It states 586 numeric facts of a million rupiah or more
machine-readably. This is what makes the round different from round 1: not a
sample checked by eye, but every figure in the document checked against the
number its issuer filed.

**Both files are now committed** to `tests/fixtures/real_corpus/`, on the
owner's decision, so CI exercises them on every push. Round 1's four defects
were all found by real documents and every test that could have caught them was
a skip in CI.

## Pre-sweep

| check | result |
|---|---|
| `Ad_Data.csv` md5 | `9a16b9248526466960194df4eb7a3e90` ✅ pristine |
| corpus mount | 170 PDFs at `/corpus`, read-only ✅ |
| endpoint | `/health` ok, 401 without a token ✅ |
| independent page/char count | 183 pages, 722,767 chars (pypdfium2) ✅ |

## Phases

| # | phase | verdict | note |
|---|---|---|---|
| 1 | probe vs an independent reader | PASS | 183/182/1 exact; page_size is page 1's, noted |
| 2 | outline vs the PDF's own TOC | PASS | 4/4 bookmarks, titles and anchors exact |
| 3 | find vs an independent extractor | **DEFECT 2** | phrase queries silently lose pages |
| 4 | extract, full document, 25 chunks | PASS | 0 failures, 76.1s, budget hint fits first time |
| 5 | every figure vs the XBRL | PASS | 501/501 printed figures recovered |
| 6 | read_page on landscape/rotated pages | **DEFECT 1** | a total came back with two extra digits |
| 7 | extract_tables vs a real ruled table | PASS | no invented values; low confidence flagged |
| 8 | assemble page count, order, rotation | PASS | 90+90=180 composed correctly |
| 9 | convert .docx → pdf, 74k chars | PASS | 34 pages, verified independently |
| 10 | optimize | NOT RUN | carried to round 3 |
| 11 | ocr on the real scan | PASS | 0 → 3,422 chars; self-report truthful |
| 12 | protect encrypt/decrypt | PASS | AES-256 R=6, wrong password rejected |
| 13 | redact on a real figure | PASS | 1/1 removed, verified unextractable |
| 14 | to_markdown at scale | PASS | shares the read path; no separate fault |
| 15 | `basis` honesty across formats | PARTIAL | PDF paths audited; other formats not |

## Defects

### DEFECT 1 — a bank's total equity came back as a number that does not exist

    read_page(filing, 10).text   ->  ... 259.358.79331 March 2026
    the PDF's text layer         ->  ... 259.358.793\r\nBalance,\r\n31 March 2026
    the issuer's XBRL            ->  Equity = 259,358,793,000,000

`success: true`, `basis: "text_layer"` — the highest-confidence basis this
server has. The extra `31` is the start of the adjacent English date label,
1.92pt away, closer than pdfplumber's 3pt word tolerance, so the two came back
as one token. `extract` returns the same corruption; both go through the word
path.

Nine other tokens on four other pages are glued the same way
(`8.450.933receivables`, `208.351Unaccepted`). Those glue a WORD to a figure
and a reader recovers the number. This one produces a plausible twelve-digit
figure found nowhere in the document, and it is the single number the statement
of changes in equity exists to report.

**Three candidate fixes were measured and two were rejected.** This is the part
worth keeping:

* *Lower the word tolerance.* Rejected. Measured across the corpus, a negative
  figure's own closing bracket sits 1.26pt from its digits in one filing and
  2.58pt in another — FURTHER than this glue. A tighter tolerance strips the
  bracket off `(90.901.000)` and turns a loss into a gain. **A one-document
  measurement said 1.0pt was safe; a five-document measurement said it ships a
  worse defect than it fixes.**
* *Reconcile against pypdfium2's text.* Rejected. On the twelve supreme-court
  judgments whose rotated margin watermark interleaves with the body, it split
  `intelektual` into `intelektunal` — 104 bad splits across 11 documents.
* *Split on the shape of the token, confirmed by a real gap at that exact
  boundary.* Shipped, after two iterations of the pattern. The first two
  versions truncated `1.424.901.522` to `1.424.901` and `10.000,00` to
  `10.000,0` in six other documents. The final rule fires on ten tokens across
  32 real documents and on nothing else.

### DEFECT 2 — find returned fewer hits because extract had run

    find('JUMLAH EKUITAS')                      ->  5 hits, pages 7,178,180-181
    extract(pages='7'); find('JUMLAH EKUITAS')  ->  3 hits, pages 178,180-181

Same document, same call, same process. `success: true` both times, no warning,
no change of basis. The pages that disappear are the ones the caller has just
been reading — on `probe -> find -> extract`, the workflow this server
documents and that `probe`'s own hint recommends.

`find` had already printed the phrase it now denies, in its own snippet for the
query `EKUITAS`, which returns 54 hits either way.

Cause: `load_page` builds one block per LINE; `load_page_words` builds one per
WORD and REPLACES the cached page. `Page.text` joins blocks with `\n`, so after
any geometry call the page's text has a newline everywhere it had a space, and
`re.escape("JUMLAH EKUITAS")` — which contains a literal space — matches
nothing. Single-word queries always worked, which is why 248 tests did not
catch it.

Fixed by giving `Page` a `raw_text` set by the reader and never rebuilt from
blocks.

## What was checked and found correct

Recorded because a sweep that lists only failures is not a measurement.

* **501 of 501 printed figures recovered.** All 586 XBRL facts were rendered as
  the statements print them and searched for in the extracted text; 501 found.
  All 85 not found were then checked against the PDF's own text layer and are
  absent from it too — XBRL taxonomy roll-ups the printed statements never show
  as a line. Nothing printed was lost, and no figure was invented.
* **Round 1's budget fix holds at scale.** The refusal on a 158,000-token
  document named `1-9`, and `1-9` fitted on the first attempt.
* **The full document walks cleanly.** 183 pages in 25 chunks, 0 failures,
  76.1 seconds, ~3s per 8-page chunk.
* **assemble composes rotation onto an already-rotated page** — 90 + 90 = 180,
  verified with pypdfium2.
* **ocr's self-report is truthful** — `pages_still_without_text: ""` after the
  scanned page went from 0 to 3,422 characters of correct bilingual text, read
  by an `eng` model.
* **protect** does what it says: AES-256 R=6, wrong password rejected.
* **redact** found 1 of 1 occurrence and its verification step was honest.

## Known limitation, not a defect

The wide bilingual tables read as a block of labels followed by a block of bare
numbers rather than as rows. A page with more column gaps than any prose layout
has falls back to one column and is reported as `looks_tabular` with a pointer
to `extract_tables()`. That is documented and signposted. It is still the
weakest result in the round.

`probe.page_size` reports page 1's geometry for a document with three. Terse
rather than wrong, but the same shape as the per-document verdicts this repo
rejects elsewhere. Carried to round 3.

## Outcome

Two defects, both fixed, each with a regression test named after the wrong
answer and each verified to FAIL with its fix stashed (12 and 4 failures
without, 14 and 5 passing with). Suite **267 passed, 1 skipped**, up from 248.

The BBCA filing and its XBRL oracle are committed to the repo, so both defects
are now guarded on every push by a real 183-page document rather than by a
fixture built to have the property.

**Round 3:** `optimize`, the `basis` audit across non-PDF formats, and
`probe.page_size` on a multi-geometry document.
