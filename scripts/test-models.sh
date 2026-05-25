#!/usr/bin/env bash
# Iterate through a list of OpenRouter free models, set MODEL_NAME in .env to
# each one, force-recreate all 13 harness containers, and run
# scripts/test-inference.sh.  Results land under /tmp/multi-model/.
#
# Output: an aggregate matrix harness × model showing which combos produce
# real model output.
#
# Usage: ./scripts/test-models.sh

set -uo pipefail
cd "$(dirname "$0")/.."

MODELS=(
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free"
  "nvidia/nemotron-3-nano-30b-a3b:free"
  "minimax/minimax-m2.5:free"
  "openai/gpt-oss-120b:free"
  "z-ai/glm-4.5-air:free"
)

OUT=/tmp/multi-model
mkdir -p "$OUT"

original_model=$(grep '^MODEL_NAME=' .env | head -1 | cut -d= -f2-)
restore() {
    sed -i "s|^MODEL_NAME=.*|MODEL_NAME=${original_model}|" .env
}
trap restore EXIT

for m in "${MODELS[@]}"; do
    safe=$(echo "$m" | tr '/:' '__')
    echo "===================================================================="
    echo "MODEL: $m"
    echo "===================================================================="
    sed -i "s|^MODEL_NAME=.*|MODEL_NAME=$m|" .env
    docker compose --profile on-demand up --no-start --force-recreate >/dev/null 2>&1
    docker compose up -d auth >/dev/null 2>&1
    sleep 1

    KEEP_OUTPUT=1 bash scripts/test-inference.sh > "${OUT}/test-${safe}.txt" 2>&1
    grep -E '^[a-z-]+ ' "${OUT}/test-${safe}.txt" || cat "${OUT}/test-${safe}.txt"
    grep -E '^INFERENCE:' "${OUT}/test-${safe}.txt"
    echo
done

echo "===================================================================="
echo "AGGREGATE — harness × model (P=PASS, R=PARTIAL, .=fail/skip)"
echo "===================================================================="

python3 - <<PY
import os, re
OUT = "$OUT"
models_in_order = [m.strip() for m in """$(printf '%s\n' "${MODELS[@]}")""".strip().split("\n")]
short = lambda s: s.replace("/","_").replace(":","_")
short_label = lambda s: s.split("/")[-1].replace(":free","")

results = {}
for m in models_in_order:
    path = f"{OUT}/test-{short(m)}.txt"
    if not os.path.exists(path): continue
    for line in open(path):
        match = re.match(r'^([a-z-]+)\s+(PASS|PARTIAL|FAIL|TIMEOUT|MODEL|AUTH|CONFIG|SKIP)\s', line)
        if match:
            h, r = match.group(1), match.group(2)
            results.setdefault(h, {})[m] = r

harnesses = sorted(results.keys())
# table
cols = [short_label(m)[:14] for m in models_in_order]
print(f"{'harness':<14} " + "  ".join(f"{c:<14}" for c in cols))
print(f"{'-'*14} " + "  ".join(f"{'-'*14}" for _ in cols))
def cell(r):
    if r == "PASS": return "PASS"
    if r == "PARTIAL": return "PARTIAL"
    if r == "SKIP": return "skip"
    return r or "-"
for h in harnesses:
    row = [cell(results[h].get(m, "-")) for m in models_in_order]
    print(f"{h:<14} " + "  ".join(f"{c:<14}" for c in row))
PY
