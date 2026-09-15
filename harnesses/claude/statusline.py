#!/usr/bin/env python3
# Claude Code status line for harness-claude. One line, or two when the
# terminal is too narrow:
#   muse-spark-1.3-contributor ✻ high · /workspace · ▰▱▱▱▱▱▱▱ 15% 153k/1M · est $1.12
# Model, thinking effort, directory, how full the context is, and Claude Code's
# estimated session cost. That estimate is only as good as the rates Claude Code
# prices with, so the entrypoint hands it OpenCode Go's real ones (modelPricing
# in /etc/claude-code/managed-settings.json). Cheap on purpose: stdin only, no
# git, no files, since every open session re-runs it after each response.
import json
import os
import re
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    data = {}

RS, DIM, BOLD = "\033[0m", "\033[2m", "\033[1m"
GREEN, AMBER, RED = "\033[32m", "\033[33m", "\033[31m"
CYAN, MAGENTA, BLUE = "\033[36m", "\033[35m", "\033[34m"
CELLS = 8
SEP = f" {DIM}·{RS} "


def short(n):
    n = int(n or 0)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}".rstrip("0").rstrip(".") + "M"
    if n >= 1000:
        return f"{n / 1000:.0f}k"
    return str(n)


def visible_len(s):
    return len(re.sub(r"\x1b\[[0-9;]*m", "", s))


model_info = data.get("model") or {}
model = model_info.get("display_name") or model_info.get("id") or "?"
for prefix in ("anthropic/", "opencode-go/"):
    if model.startswith(prefix):
        model = model[len(prefix):]
model = model.replace("[1m]", "")

thinking = (data.get("thinking") or {}).get("enabled")
effort = (data.get("effort") or {}).get("level")
if thinking is False:
    think = f"{DIM}no thinking{RS}"
elif effort:
    think = f"{MAGENTA}✻ {effort}{RS}"
elif thinking:
    think = f"{MAGENTA}✻ on{RS}"
else:
    think = ""

cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or ""
home = os.environ.get("HOME", "")
if home and home != "/" and cwd.startswith(home):
    cwd = "~" + cwd[len(home):]

ctx = data.get("context_window") or {}
size = int(ctx.get("context_window_size") or 200_000)
pct = ctx.get("used_percentage")
used = ctx.get("total_input_tokens")
if used is None and pct is not None:
    used = pct / 100 * size
pct = min(max(float(pct or 0), 0.0), 100.0)
level = GREEN if pct < 50 else AMBER if pct < 75 else RED
filled = round(pct / 100 * CELLS)
bar = f"{level}{'▰' * filled}{RS}{DIM}{'▱' * (CELLS - filled)}{RS}"
context = f"{bar} {level}{BOLD}{pct:.0f}%{RS} {DIM}{short(used)}/{short(size)}{RS}"

cost = float((data.get("cost") or {}).get("total_cost_usd") or 0)
cost_str = f"${cost:.2f}" if cost == 0 or cost >= 0.01 else f"${cost:.4f}"
spend = f"{DIM}est{RS} {cost_str}"

head = f"{CYAN}{BOLD}{model}{RS}" + (f" {think}" if think else "") + (f"{SEP}{BLUE}{cwd}{RS}" if cwd else "")
tail = context + SEP + spend
one_line = head + SEP + tail

try:
    cols = int(os.environ.get("COLUMNS") or 0)
except ValueError:
    cols = 0
out = one_line if not cols or visible_len(one_line) <= cols - 4 else head + "\n" + tail
sys.stdout.write(out + "\n")
