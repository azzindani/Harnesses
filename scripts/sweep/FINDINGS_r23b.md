# Round 23b findings — the four starved phases, re-run

Phases 4, 5, 7, 22 on OpenRouter `nemotron-3-super`. These are the phases round
23 never actually ran: its reports were 270-427 bytes of header. Every candidate
below was re-tested by hand — over MCP where the server is registered in this
session, against the source and the live deployment where it is not.

---

## 1. `query_select` is not SELECT-only — it will DELETE (MCP_Web_Browser)

**Confirmed on the deployment.** The tool's own docstring is
*"SELECT-only SQL (parameterless). Bounded."*

`engine/db/query.py:63` guards with a prefix test:

```python
stripped = sql.lstrip().lower()
if not stripped.startswith("select") and not stripped.startswith("with"):
    raise ValueError("select() only accepts SELECT/WITH statements")
```

**SQLite accepts a `WITH` clause in front of `DELETE`, `INSERT` and `UPDATE`** —
that is documented syntax, not a trick. So:

```sql
WITH x AS (SELECT 1) DELETE FROM pages
```

starts with `with`, is a single statement (so `sqlite3`'s one-statement rule does
not catch it), and empties the table. Reproduced locally on a scratch database:
3 rows before, **0 after**.

Then reproduced against `browser.casava.space` with a delete that could not
remove anything — `WITH x AS (SELECT 1) DELETE FROM pages WHERE 1=0`:

```json
{"ok": true, "op": "query_select", "rows": [], "total": 0,
 "progress": [{"status": "ok", "label": "SQL executed", "detail": "0 rows"}]}
```

`ok: true`, **"SQL executed"** — the DELETE was accepted and run. The row count
held at 19 only because of the `WHERE 1=0` this test deliberately added.

The connection is a plain read-write `sqlite3.connect(str(path))`
(`engine/__init__.py:74`) — no `mode=ro`, so nothing downstream stops the write
either.

**Two fixes, and both are wanted.** Neither alone is enough:

* Open the query tier's connection with `sqlite3.connect("file:...?mode=ro", uri=True)`.
  A read-only handle makes the guarantee structural rather than lexical — the
  same reasoning as MCP_Database's rejected design, where read-only was to be
  enforced by the database role and not by the prompt.
* Keep a statement check, but stop pattern-matching the prefix. `sqlite3` ships
  the parser already: `Connection.set_authorizer` can deny anything that is not
  `SQLITE_READ`/`SQLITE_SELECT`, and it sees the parsed statement, not its first
  word.

This is the round's real finding, and the axis did not produce it — the sweep
model called `query_select` with `SELECT COUNT(*) FROM pages`, got 19 twice, and
recorded a pass. It came from reading what the tool claims and asking whether the
guard can actually hold it.

---

## 2. `fs_index list` says truncated and never says of how many (MCP_File_System)

`_basic_index.py:292-305` returns `entries`, `returned: 50`, `truncated: true`
and a hint to narrow — with **no total**. A caller cannot tell 50 of 51 from 50
of 700,000, and the number is one `COUNT(*)` away in a table the same function is
already querying.

This is the family the repo already has a test file for —
`tests/test_a_total_that_was_not_a_total.py` — and the r22 fix that gave
`fs_query` its `total_found`, `scan_complete` and `total_found_is_lower_bound`.
`list` is the sibling that fix did not reach. `stats` in the same module reports
`entry_count`, so the repo does not disagree with itself about whether the number
is worth having; `list` simply never got it.

Minor, and unambiguous.

---

## Ruled out after verification

| candidate from the reports | verdict |
|---|---|
| `docs-read find` returned 16,834 hits — capped silently? | **No.** `hits: 16834, returned: 50, truncated: true, returned_limit: 50`, plus a hint naming both numbers. Round 5's fix is working exactly as intended. The sweep model checked the total against the row count and never noticed it had 50. |
| `fs_index` built **706** entries, `clear` removed **700** | **No.** Different scopes, both honest. `stats.entry_count` counts every row in the table across all roots (`_basic_index.py:491`); `clear` deletes only rows under the root it was given and reports `remaining` beside `cleared` (`:537-554`). The six are indexed under another root. |
| `fs_archive` made a zip of **4** files and a tar.gz of **5** from one directory | **No.** The zip was written into the directory it archived, so the tar that followed contained it. Working as written. |
| `browse_extract` `elapsed_ms` moved 65 → 33 between calls | **No.** Timing, excluded by the axis contract. |

---

## What this round did not cover

Coverage was complete — 7/7 docs-read, 6/6 browser, 5/5 data-basic, 13 rows over
8 fs ops — but the **axis** was applied thinly. In `docs-read` only `probe` got
the full witness treatment; the other six tools have empty cells in the
"called twice" and "after the other tools ran" columns. Tools were exercised;
cross-tool contamination was mostly not tested.

Both findings above came from reading response contents and source, not from the
axis. That is now true of five of the five defects across r23 and r23b.
