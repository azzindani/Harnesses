# Round 19b ledger — phases 49, 53, 54

Round 19b's last three phases, run **2026-08-29** from the Claude Code session's
own MCP mounts rather than the opencode harness, because both free tiers were
exhausted. Same live endpoints (`https://office.casava.space/...`), same axis
("do what the hint told you to do"), same two-calls-per-tool rule.

**Read the caveat before trusting a PASS here.** The driver was the model that
wrote the round-18 fixes. That is the wrong model for *discovery* — it knows
which branches were changed and will not pick inputs at random the way an
uninformed client does. These three phases were re-runs confirming a known fix,
which is the one job that bias does not spoil. Round 20 still needs an
uninformed driver on a fresh axis.

| phase | server | tools | verdict |
|---|---|---|---|
| 53 | office-xlsx-basic p2 | search_cells, set_cell, set_range, insert_row | **PASS** — r18 fix confirmed live on all three write tools |
| 54 | office-xlsx-basic p3 | delete_row, add_sheet, sort_sheet, rename_sheet | **DEFECT ×5** |
| 49 | office-pptx-design p2 | duplicate_slide, export_pdf, add_image_to_all_slides, set_font_all_slides | **DEFECT ×2** |

Round 18's fix (`a35e06f`) is confirmed working: `set_cell`/`set_range`/`insert_row`
with a row-0 address all answer *"Nothing was written -- this is an argument
error, so there is no snapshot to restore."* and every obeyed retry succeeded.

Seven new defects, none of which round 18 could have seen — its axis reads the
`hint` field, and five of these live outside it.

---

## 1. `sort_sheet` silently corrupts the sheet — SEVERE

`sort_sheet(sheet_name="Data", column="A")` on a sheet whose row 1 is blank
returned `success: true, rows_sorted: 4` and **sorted the header row into the
data**:

```
before                    after
  1  ⌀      ⌀               1  ⌀      ⌀
  2  name   qty             2  alpha  3
  3  beta   2               3  beta   2
  4  alpha  3               4  gamma  1
  5  gamma  1               5  name   qty     <- the header, sorted as a value
```

`helpers.py:330` — `has_header` skips `all_rows[0]`, the *physical* first row,
not the header. Any sheet with a leading blank or title row loses its header
into the body. `insert_row(1)` produces exactly that state, so two ordinary
calls in sequence corrupt the file with no failure anywhere.

The same function already carries a long comment about a *different* silent
corruption bug fixed earlier (the None-skip write-back, `helpers.py:342-360`).
One silent-corruption bug was found and fixed here and its sibling left in place.

## 2. `sort_sheet` leaks raw Python exceptions

- `column="qty"` (header name instead of the letter) → `list index out of range`.
  `column_index_from_string("QTY")` is *valid* — it resolves to column 12347 —
  so the guard at `helpers.py:257` passes and `r[col_idx]` then indexes off the
  end of every row.
- `column="B"` on a column holding both the string `qty` and ints →
  `'<' not supported between instances of 'int' and 'str'`. The sort key at
  `helpers.py:338` compares values of mixed type directly.

Neither error names an argument, and neither is actionable.

## 3. The round-18 hint promises something the error often cannot deliver

The fix's sentence ends *"Fix the value named in the error and call again."*
That holds for openpyxl's coordinate errors, which do name the value. It does
not hold for a leaked exception. Three observed this round:

| call | error | is a value named? |
|---|---|---|
| `sort_sheet(column="B")` | `'<' not supported between instances of 'int' and 'str'` | no |
| `set_font_all_slides(color_hex="red")` | `invalid literal for int() with base 16: 're'` | no |
| `sort_sheet(column="qty")` | `list index out of range` | no |

The call site knows which argument it was validating even when the exception
does not. The hint should name it.

## 4. `hint_for_error` is too narrow — the old wrong hint is still reachable

`file_utils.py:235` gates the fix on `isinstance(e, (ValueError, TypeError))`.
Everything else still falls through to `"Use restore_version to undo if a
snapshot was taken."` — the exact advice round 18 existed to remove. Reached
twice this round, on two different servers:

- xlsx `sort_sheet(column="qty")` → `IndexError`
- pptx `add_image_to_all_slides` on a corrupt PNG → PIL `UnidentifiedImageError`

Both wrote nothing and both were told to restore a snapshot.

## 5. Every failed argument call writes a snapshot, and the response contradicts itself

Three failed `set_cell`/`set_range`/`insert_row` calls left three `.bak` copies
of the workbook on disk. Each response said, in the same object:

```json
"hint":   "Nothing was written -- ... there is no snapshot to restore.",
"backup": "/workspace/data/r19b_verify/.mcp_versions/p53_...xlsx.bak",
"progress": [{"icon": "✔", "msg": "Snapshot saved"}]
```

The hint denies the snapshot the other two fields advertise. Round 18's fix
corrected the advice and left the contradiction — before it, the hint at least
*agreed* with `backup`.

**`shared/version_control.py:109` already has the fix.**
`discard_unused_snapshot(backup_path, file_path)` drops a snapshot that is still
byte-identical to its source, is conservative on every doubt, and has eight
passing tests in `test_a_hint_that_named_the_wrong_cause.py`. **Nothing in
production calls it.** It was written in an earlier round and never wired in.

## 6. `add_sheet` hints at a tool that does not exist

Duplicate sheet name → `"Choose a different name or delete the existing sheet
first."` There is no `delete_sheet` tool on `xlsx-basic`, `xlsx-charts`,
`xlsx-formulas` or `xlsx-new` — nowhere in the Office fleet. Half the hint is
unfollowable.

## 7. A heap address in an error string

```
"error": "cannot identify image file <_io.BytesIO object at 0x7170edaa6a70>"
```

A Python object repr, pointer included, in a JSON API response. Non-deterministic,
useless to the caller, and it never says the real cause: the file is not a
readable image.

---

## Confirmed working (no action)

- `search_cells`, `rename_sheet`, `delete_row` — errors name the problem, hints
  name the fix (`Available sheets: Data`, `Use list_sheets to get current row count`).
- `export_pdf` — creates a missing parent directory rather than failing.
- `set_font_all_slides(color_hex="#FF0000")` — the `#` is stripped and the colour
  really is applied; verified in the XML (`srgbClr val="FF0000"`), not from the
  response.
- `duplicate_slide`, `add_image_to_all_slides` — correct once given valid input.

## Ported to the one sibling that shared it

Data_Analyst had the same snapshot-on-failure defect at 18 sites, confirmed live:

    apply_patch(ops=[{"op": "log_transform", "column": "name"}])   # text column
      -> "applied": 0, "backup": ".mcp_versions/d_...csv.bak",
         "hint": "... Call restore_version() if you want to reset to the snapshot."

The comment three lines above that return reads "Do NOT write the modified df --
leave the original intact". `discard_snapshot_if_unchanged` has been in that repo
since round 11, wired only into the paths that succeed. ML and File_System have no
failure return that carries a backup, so the port stops there. Commit `3d339d6`.

## Fixture

`/root/Harnesses/data/Ad_Data.csv` md5 `9a16b9248526466960194df4eb7a3e90` before
and after. Untouched — all work in `r19b_verify/`.
