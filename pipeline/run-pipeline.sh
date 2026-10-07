#!/usr/bin/env bash
# Drive the agent: generate → gate → review → [fix → gate → review] × up to N.
# All state lives in <out>/ (SPEC.md, CONTRACT.md, the app, REVIEW.md, .pipeline/).
#
#   run-pipeline.sh --spec <spec.md> --out <dir> [--agent <name>] [--max-iterations <n>] [--report <file>]
set -euo pipefail

usage() {
  echo "usage: $0 --spec <spec.md> --out <dir> [--agent <name>] [--max-iterations <n>] [--report <file>]" >&2
  exit 2
}

spec=""; out="app"; agent="claude-code"; max_iter=3; report="pipeline-report.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) spec=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --agent) agent=$2; shift 2 ;;
    --max-iterations) max_iter=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -f "$spec" ]] || usage

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
agent_run="$root/agents/$agent/run.sh"
[[ -x "$agent_run" ]] || { echo "unknown agent '$agent': $agent_run is missing or not executable" >&2; exit 2; }
prompts="$root/pipeline/prompts"
export AGENT_SYSTEM_PROMPT_FILE="$prompts/system.md"

mkdir -p "$out"
out=$(realpath "$out")
report=$(realpath -m "$report")
cp "$spec" "$out/SPEC.md"
cp "$root/pipeline/CONTRACT.md" "$out/CONTRACT.md"
mkdir -p "$out/.pipeline"
[[ -d "$out/.git" ]] || git -C "$out" init -q
printf 'dist/\n.pipeline/\n' > "$out/.git/info/exclude"

commit() {
  git -C "$out" add -A >/dev/null
  git -C "$out" -c user.name=pipeline -c user.email=pipeline@localhost commit -q --allow-empty -m "$1"
}

stages='[]'
record() { # <name> <status> <extra-json>
  stages=$(jq -c --arg n "$1" --arg s "$2" --argjson x "$3" '. + [{name:$n, status:$s} + $x]' <<< "$stages")
}

agent_stage() { # <name> <edit|readonly> <prompt-file>
  local name=$1 mode=$2 prompt=$3 dir="$out/.pipeline/$1" rc=0
  echo "== $name ($mode)"
  mkdir -p "$dir"
  "$agent_run" "$prompt" "$out" "$dir" "$mode" || rc=$?
  local res
  res=$(cat "$dir/result.json" 2>/dev/null || echo '{}')
  record "$name" "$([[ $rc -eq 0 ]] && echo ok || echo failed)" "$res"
  return $rc
}

gate_stage() { # <name>
  local name=$1 dir="$out/.pipeline/$1" rc=0
  echo "== $name"
  bash "$root/pipeline/gate.sh" "$out" "$dir" || rc=$?
  rm -rf "$out/.pipeline/gate-report"
  cp -r "$dir" "$out/.pipeline/gate-report"   # stable path the prompts refer to
  record "$name" "$([[ $rc -eq 0 ]] && echo ok || echo failed)" \
         "$(jq -c '{steps, failed_step}' "$dir/summary.json" 2>/dev/null || echo '{}')"
  return $rc
}

review_stage() { # <name>; sets $verdict
  local name=$1 dir="$out/.pipeline/$1"
  verdict=ERROR
  if agent_stage "$name" readonly "$prompts/review.md"; then
    cp "$dir/result.txt" "$out/REVIEW.md"
    verdict=$(grep -E '^VERDICT:' "$out/REVIEW.md" | tail -1 | awk '{print $2}')
    [[ "$verdict" == APPROVE || "$verdict" == CHANGES_REQUESTED ]] || verdict=INVALID
  fi
  stages=$(jq -c --arg v "$verdict" '.[-1].verdict = $v' <<< "$stages")
  echo "   verdict: $verdict"
}

finish() { # <success|failed>
  jq -n --arg status "$1" --arg agent "$agent" --argjson fix_rounds "$iter" \
        --argjson max_fix_rounds "$max_iter" --argjson stages "$stages" \
        '{status:$status, agent:$agent, fix_rounds:$fix_rounds, max_fix_rounds:$max_fix_rounds, stages:$stages}' \
        > "$report"
  echo "pipeline: $1 (report: $report)"
}

iter=0
if ! agent_stage "00-generate" edit "$prompts/generate.md"; then
  commit "generate (agent failed)"
  finish failed
  exit 1
fi
commit "generate"

while :; do
  tag=$(printf '%02d' "$iter")
  gate_ok=true
  gate_stage "$tag-gate" || gate_ok=false
  review_stage "$tag-review"
  commit "review $iter: gate=$($gate_ok && echo pass || echo fail) verdict=$verdict"
  if $gate_ok && [[ "$verdict" == APPROVE ]]; then
    finish success
    exit 0
  fi
  if (( iter >= max_iter )); then
    finish failed
    exit 1
  fi
  iter=$((iter + 1))
  tag=$(printf '%02d' "$iter")
  agent_stage "$tag-fix" edit "$prompts/fix.md" || true   # a failed fix is still gated and reviewed
  commit "fix $iter"
done
