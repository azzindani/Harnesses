# Round 23 findings — verified, not relayed

44 reports read. Every candidate below was **re-tested by hand over MCP** before
being written down, because the sweep model's prose is not evidence: five of the
nine candidates it raised (or that its table implied) did not survive that test,
and two of those five were its own transcription errors. The verification calls
live under `/workspace/data/verify_r23/`.

Round 23's own axis — "ask the same question after something else has run" —
produced **no** cross-tool contamination finding on any of the six mature repos.
Every witness that moved, moved because data had actually changed. The three
defects below came from reading the *contents* of tool responses, not from the
axis.

---

## Confirmed — worth fixing

### 1. `office-docx-new.batch_create_from_template` appends `.docx` unconditionally

`MCP_Microsoft_Office`. The `filename_key` value is used as a stem with `.docx`
glued on, so a data row whose filename already carries the extension gets two.

```
data_list=[{... "filename": "alice.docx"}, {... "filename": "bob"}]
  -> files: ["alice.docx.docx", "bob.docx"]
```

`success: true`, `created_count: 2`, both files valid. A caller that names its
outputs the obvious way silently gets a directory of `*.docx.docx`. Fix: strip a
trailing `.docx` (case-insensitively) from the filename value before appending.

### 2. `office-pptx-basic.diff_versions` reports `change_count: 0` for a deleted slide

`MCP_Microsoft_Office`. The response contradicts itself in the same object:

```json
"summary": "Slide count changed: 2 → 1 (removed 1).",
"slide_count_changed": true,
"text_changes": [],
"change_count": 0,
"progress": [... {"msg": "Compared versions", "detail": "0 changes"}]
```

`change_count` counts only `text_changes` and ignores the structural diff it has
already computed. The progress line repeats the wrong number. An LLM reading
`change_count` first — which the return-value contract encourages — concludes
nothing happened after a slide was destroyed. The **docx** `diff_versions` in the
same repo counts correctly (`change_count` went 2 → 1 → 0 as paragraphs were
inserted, deleted and restored), so this is a divergence between two siblings,
not a design choice. Fix: fold the slide-count delta into `change_count` and into
the progress detail.

### 3. `office-pptx-new.create_from_docx` reports success for a 0-slide deck

`MCP_Microsoft_Office`. Given a docx with no paragraphs:

```json
"success": true, "slide_count": 0, "source_paragraph_count": 0,
"progress": [..., {"icon": "✔", "msg": "Saved zeroslides.pptx", "detail": "0 slides"}]
```

Every tick is green and no warning is raised. Measured with a reader that did not
write it: the file has no `<p:sldIdLst>` and no slide parts at all; LibreOffice
opens it and renders **one blank page**. So it is not corrupt — it is an empty
deliverable announced as a success. Fix: `warn` when `slide_count == 0`, the way
`data-visual.generate_chart` warns when it changes an output extension.

---

## Lower confidence — one metric, two answers

`ml-medium.check_data_quality` scores `Ad_Data.csv` **29.6 / 100 with 11 alerts**
(re-measured 2026-09-01, identical). `ml-medium.generate_eda_report` on the same
file reports **29.5 with 13 alerts**. Same server, same input, same named metric.
The extra alerts are `class_imbalance` plus a duplicate graded `low` rather than
`medium`, so the alert sets are genuinely different — this may be deliberate
scope, but nothing in either response says so. Fix, if fixed: share one scorer,
or name the two scores differently.

---

## Ruled out after direct verification

Recording these matters as much as the findings: each was a plausible-looking
line in a report that a fix would have been wasted on.

| candidate | verdict |
|---|---|
| `xlsx-new.create_from_data` returned `row_count: 1` for 3 rows | **No.** Actual call returns `row_count: 3`. Report transcription error. |
| `xlsx-new.create_report` returned `sheets_created: 2` for 3 sheets | **No.** Actual call returns `sheets_created: 3` and `"2 data sheet(s) + Cover"`. Transcription error. |
| `data-visual` silently wrote HTML when asked for `.png` | **No.** It warns by name — `"output_path asked for '.png'; this tool writes HTML, so it was saved as chart.html"` — and returns the corrected `output_path`. This is the behaviour finding 3 should copy. |
| `data-transform.merge_datasets` silently fanned out to 27,728 rows | **No.** It emits a `warn` naming the key, the multiplier (`4.0× the larger input`), the cause (`'Date' repeats on both sides`) and the fix. The sweep model just did not read it. |
| `fs_query` gave 36, then 38, then `total_found: 44` for `report*` | **No.** Other phases were writing `report_r23_*.md` into the same shared `/workspace/data` throughout that window. The r22 fix is in place and correct: `scan_limit = get_max_scan_files()` is independent of `max_results`, and an incomplete walk sets `total_found_is_lower_bound`, `files_scanned` and a warn (`servers/fs_basic/_basic_query.py:164,244`). |

## Not covered by this round

Four phases produced near-empty reports during the OpenRouter quota death and
exercised almost nothing: **`docs-read` (1 of 7 tools, and its axis answer left
as "Not yet known")**, `browser_2` (header row only), `data-basic_1`,
`fs-actions`. `docs-read` was the reason this round existed. Those four need a
re-run before the round can be called complete.

Round 22's five fixes remain verified only for `fs_query` (above, by reading the
code). The other four are still untested since deployment.
