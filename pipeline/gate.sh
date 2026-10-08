#!/usr/bin/env bash
# Deterministic gate for a generated app (language-agnostic; only runs what app.yaml says):
#   1. validate app.yaml against pipeline/schema/app.schema.json
#   2. in a clean amazonlinux:2023 container: install build+runtime packages, run build
#      (must create ./dist), run test
# Writes <report-dir>/{summary.json,app.json,validate.log,packages.log,build.log,test.log}.
#
#   gate.sh <app-dir> <report-dir>
set -uo pipefail

app=$(realpath "$1")
rep=$(realpath -m "$2")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${GATE_IMAGE:-amazonlinux:2023}
inner="$root/pipeline/gate-in-container.sh"
mkdir -p "$rep"
rm -f "$rep"/*.log "$rep"/failed

declare -A status=([validate]=skipped [packages]=skipped [build]=skipped [test]=skipped)
failed_step=""

# 1. validate ---------------------------------------------------------------------------------
if python3 "$root/pipeline/validate-app.py" "$app/app.yaml" "$root/pipeline/schema/app.schema.json" \
     > "$rep/app.json" 2> "$rep/validate.log"; then
  status[validate]=ok
else
  status[validate]=failed; failed_step=validate
fi

# 2. build + test ------------------------------------------------------------------------------
if [[ -z $failed_step ]]; then
  docker run --rm -v "$app:/work" -w /work -v "$inner:/gate.sh:ro" -v "$rep:/report" \
    -v "$rep/app.json:/app.json:ro" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$image" bash /gate.sh > "$rep/container.log" 2>&1
  rc=$?
  failed=$(cat "$rep/failed" 2>/dev/null || true)
  for s in packages build test; do
    if [[ $s == "$failed" ]]; then status[$s]=failed; failed_step=$s; break; fi
    status[$s]=ok
  done
  if [[ $rc -ne 0 && -z $failed_step ]]; then failed_step=build; status[build]=failed; fi
fi

# summary -------------------------------------------------------------------------------------
ok=$([[ -z $failed_step ]] && echo true || echo false)
jq -n --argjson ok "$ok" --arg failed "$failed_step" \
      --arg v "${status[validate]}" --arg p "${status[packages]}" --arg b "${status[build]}" \
      --arg t "${status[test]}" \
      '{ok:$ok, failed_step:(if $failed == "" then null else $failed end),
        steps:{validate:$v, packages:$p, build:$b, test:$t}}' > "$rep/summary.json"
echo "gate: $(jq -c . "$rep/summary.json")"
[[ $ok == true ]]
