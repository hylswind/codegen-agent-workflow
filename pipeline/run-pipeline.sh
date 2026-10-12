#!/usr/bin/env bash
# Drive the agent on an existing app repository:
#   checkout <base-repo>@<base-commit> → update → gate → review → [fix → gate → review] × up to N
# All state lives in <out>/: the checkout, CONTRACT.md, REVIEW.md, .pipeline/.
#
#   run-pipeline.sh --base-repo <url> --base-commit <sha> --out <dir> \
#                   [--agent <name>] [--max-iterations <n>] [--report <file>]
set -euo pipefail

usage() {
  echo "usage: $0 --base-repo <url> --base-commit <40-hex sha> --out <dir> [--agent <name>] [--max-iterations <n>] [--report <file>]" >&2
  exit 2
}

base_repo=""; base_commit=""; out="app"; agent="claude-code"; max_iter=3; report="pipeline-report.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-repo) base_repo=$2; shift 2 ;;
    --base-commit) base_commit=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --agent) agent=$2; shift 2 ;;
    --max-iterations) max_iter=$2; shift 2 ;;
    --report) report=$2; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n $base_repo && $base_commit =~ ^[0-9a-f]{40}$ ]] || usage

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
agent_run="$root/agents/$agent/run.sh"
[[ -x "$agent_run" ]] || { echo "unknown agent '$agent': $agent_run is missing or not executable" >&2; exit 2; }
prompts="$root/pipeline/prompts"
export AGENT_SYSTEM_PROMPT_FILE="$prompts/system.md"

mkdir -p "$out"
out=$(realpath "$out")
report=$(realpath -m "$report")
[[ -z "$(ls -A "$out")" ]] || { echo "$out must be empty" >&2; exit 2; }

echo "== checking out $base_repo @ $base_commit"
git -C "$out" init -q
git -C "$out" fetch -q --depth 1 "$base_repo" "$base_commit"
git -C "$out" checkout -q -b pipeline FETCH_HEAD
head=$(git -C "$out" rev-parse HEAD)
[[ $head == "$base_commit" ]] || { echo "fetched $head, expected $base_commit" >&2; exit 2; }
[[ -s "$out/SPEC.md" ]] || { echo "SPEC.md is missing or empty at $base_commit" >&2; exit 2; }

rm -f "$out/REVIEW.md"
cp "$root/pipeline/CONTRACT.md" "$out/CONTRACT.md"
mkdir -p "$out/.pipeline"
jq -n --arg repo "$base_repo" --arg commit "$base_commit" '{repo:$repo, commit:$commit}' > "$out/.pipeline/base.json"
printf 'dist/\n.pipeline/\n' > "$out/.git/info/exclude"

commit() {
  git -C "$out" add -A >/dev/null
  git -C "$out" -c user.name=pipeline -c user.email=pipeline@localhost commit -q --allow-empty -m "$1"
}
commit "init: contract (base ${base_commit:0:7})"

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
  jq -n --arg status "$1" --arg agent "$agent" --arg repo "$base_repo" --arg commit "$base_commit" \
        --argjson fix_rounds "$iter" --argjson max_fix_rounds "$max_iter" --argjson stages "$stages" \
        '{status:$status, agent:$agent, base:{repo:$repo, commit:$commit},
          fix_rounds:$fix_rounds, max_fix_rounds:$max_fix_rounds, stages:$stages}' > "$report"
  echo "pipeline: $1 (report: $report)"
}

iter=0
if ! agent_stage "00-update" edit "$prompts/update.md"; then
  commit "update (agent failed)"
  finish failed
  exit 1
fi
commit "update"

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
