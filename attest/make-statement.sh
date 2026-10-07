#!/usr/bin/env bash
# Print the build-result statement: the SPEC's sha256 and the image's PCR reference values.
#   make-statement.sh <spec.md> <pcr_measurements.json> > statement.json
set -euo pipefail

if [[ $# -ne 2 ]]; then echo "usage: $0 <spec.md> <pcr_measurements.json>" >&2; exit 2; fi
spec=$1
pcr=$2
zero96=$(printf '0%.0s' {1..96})   # PCR12 default when nothing overrides the kernel command line

jq -n --arg sha "$(sha256sum "$spec" | cut -d' ' -f1)" --arg zero "$zero96" --slurpfile m "$pcr" '
  ($m[0].Measurements) as $M |
  {
    spec: { sha256: $sha },
    measurements: {
      hashAlgorithm: (($M.HashAlgorithm // "SHA384") | split(" ")[0]),
      PCR4:  ($M.PCR4  | ascii_downcase),
      PCR7:  ($M.PCR7  | ascii_downcase),
      PCR12: (($M.PCR12 // $zero) | ascii_downcase)
    }
  }'
