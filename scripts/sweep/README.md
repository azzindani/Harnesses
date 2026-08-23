# Sweep prompts

The prompts the coverage sweep sends into the harness session, kept as source
rather than retyped each round.

For ten rounds these lived in a throwaway generator in a scratch directory. Each
round I rewrote it, which meant re-deriving the wording of the parts that were
working fine, and the round's own question was a constant pasted into all 39
prompts. Round 11 took a bad turn out of exactly that: a rule about running each
op twice was woven into four File_System prompts by hand, in four slightly
different phrasings.

So the split here is:

| file | changes | holds |
|---|---|---|
| `blocks.py` | rarely, when a rule changes for good | the preamble, the verification rule, the write-as-you-go rule, the File_System phase bodies |
| `axes.py` | once per round | the round's question, its report columns, its File_System notes |
| `make_plan.py` | almost never | splitting the tool list into phases and assembling the prompt |

## Running it

```sh
python3 make_plan.py --round 11 --tools tools_r11.tsv --out phases_r11.tsv
```

`--tools` is two tab-separated columns, server and tool:

```
data-medium	pivot_table
data-medium	sample_data
```

Take it from `tools/list` on each endpoint. **Never** from a list the sweep
model writes for itself — asked to "list the tools then call each", it once
listed some, called none, and reported a clean pass over 19 tools it never
touched.

## Starting a round

1. Refresh the tools file from `tools/list`.
2. Add an entry to `AXES` in `axes.py`. The commented candidates at the bottom
   of that file are the leftovers from round 11, kept so the next round starts
   from evidence.
3. Regenerate the plan and run the driver.

Nothing else needs editing. If you find yourself changing `make_plan.py` to
express a round, the axis is probably trying to be two axes.

## What an axis is for

An axis is worth a round when it can be wrong in a way no test would catch —
something every tool claims implicitly and nothing checks. Round 11's was
`idempotentHint`, which had been assigned by category rather than measured; the
sweep found five tools whose second identical call wrote a second file.

## House rules

- No host, domain or token in any prompt. These go to a third-party model on
  every phase.
- No phase names more than eight tools. At sixteen the model reliably stops
  halfway; at eight, round 10 ran 38 of 39 phases on the first attempt.
- File_System is covered as named operations, not as six tool calls — its six
  tools carry a dozen operations each behind an `op`/`action` argument.
