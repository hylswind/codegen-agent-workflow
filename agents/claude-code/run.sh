#!/usr/bin/env bash
# Run one unattended Claude Code task. Interface: see agents/README.md.
#   run.sh <prompt-file> <workdir> <out-dir> [edit|readonly]
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <prompt-file> <workdir> <out-dir> [edit|readonly]" >&2
  exit 2
fi
prompt_file=$(realpath "$1")
workdir=$(realpath "$2")
out=$(realpath -m "$3")
mode=${4:-edit}
: "${AGENT_AUTH_TOKEN:?AGENT_AUTH_TOKEN is required}"
mkdir -p "$out"

export PATH="$HOME/.local/bin:$PATH"
export DISABLE_AUTOUPDATER=1
case "$AGENT_AUTH_TOKEN" in
  sk-ant-oat01-*) export CLAUDE_CODE_OAUTH_TOKEN="$AGENT_AUTH_TOKEN" ;;  # token from `claude setup-token`
  *)              export ANTHROPIC_API_KEY="$AGENT_AUTH_TOKEN" ;;        # Anthropic API key
esac

# Never add --bare here: bare mode does not read CLAUDE_CODE_OAUTH_TOKEN.
args=(-p --output-format json --dangerously-skip-permissions --no-session-persistence
      --max-turns "${AGENT_MAX_TURNS:-150}" --max-budget-usd "${AGENT_MAX_BUDGET_USD:-15}")
[[ -n "${AGENT_MODEL:-}" ]] && args+=(--model "$AGENT_MODEL")
[[ -n "${AGENT_SYSTEM_PROMPT_FILE:-}" ]] && args+=(--append-system-prompt-file "$(realpath "$AGENT_SYSTEM_PROMPT_FILE")")
[[ "$mode" == readonly ]] && args+=(--disallowedTools "Edit,Write,MultiEdit,NotebookEdit")

version=$(claude --version 2>/dev/null | awk '{print $1}')
start=$(date +%s)
rc=0
(cd "$workdir" && claude "${args[@]}" < "$prompt_file") > "$out/transcript.json" 2> "$out/stderr.log" || rc=$?
duration=$(( $(date +%s) - start ))

ok=false
if [[ $rc -eq 0 ]] && jq -e '.is_error == false and .subtype == "success"' "$out/transcript.json" >/dev/null 2>&1; then
  ok=true
fi
jq -r '.result // ""' "$out/transcript.json" > "$out/result.txt" 2>/dev/null || : > "$out/result.txt"
turns=$(jq '.num_turns // 0' "$out/transcript.json" 2>/dev/null || echo 0)
cost=$(jq '.total_cost_usd // 0' "$out/transcript.json" 2>/dev/null || echo 0)
jq -n --arg agent claude-code --arg version "$version" --arg model "${AGENT_MODEL:-default}" \
      --argjson ok "$ok" --argjson turns "$turns" --argjson cost "$cost" \
      --argjson duration "$duration" --argjson rc "$rc" \
      '{agent:$agent, version:$version, model:$model, ok:$ok, turns:$turns,
        cost_usd:$cost, duration_s:$duration, exit_code:$rc}' > "$out/result.json"

if [[ $ok == true ]]; then
  exit 0
fi
echo "claude-code task failed (exit $rc); see $out/transcript.json and $out/stderr.log" >&2
exit 1
