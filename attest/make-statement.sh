#!/usr/bin/env bash
# Print the build-result statement: the SPEC's sha256, the base repository and commit the build
# started from, and the image's PCR reference values.
#   make-statement.sh <spec.md> <pcr_measurements.json> <base-repo> <base-commit> > statement.json
set -euo pipefail

if [[ $# -ne 4 ]]; then echo "usage: $0 <spec.md> <pcr_measurements.json> <base-repo> <base-commit>" >&2; exit 2; fi
spec=$1
pcr=$2
base_repo=$3
base_commit=$4
zero96=$(printf '0%.0s' {1..96})   # PCR12 default when nothing overrides the kernel command line

jq -n --arg sha "$(sha256sum "$spec" | cut -d' ' -f1)" --arg zero "$zero96" \
      --arg repo "$base_repo" --arg commit "$base_commit" --slurpfile m "$pcr" '
  ($m[0].Measurements) as $M |
  {
    spec: { sha256: $sha },
    base: { repo: $repo, commit: $commit },
    measurements: {
      hashAlgorithm: (($M.HashAlgorithm // "SHA384") | split(" ")[0]),
      PCR4:  ($M.PCR4  | ascii_downcase),
      PCR7:  ($M.PCR7  | ascii_downcase),
      PCR12: (($M.PCR12 // $zero) | ascii_downcase)
    }
  }'
