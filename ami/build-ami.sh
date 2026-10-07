#!/usr/bin/env bash
# Build the attestable AMI image on the host by running KIWI NG inside a privileged
# amazonlinux:2023 container (always the latest AL2023 and latest KIWI/NitroTPM tools).
#
#   build-ami.sh <app-dir> <out-dir>
#     <app-dir>   the generated app: app.yaml and dist/ (built by the pipeline gate) are used
#     <out-dir>   receives image.raw, pcr_measurements.json, image.packages, kiwi.log
set -euo pipefail

if [[ $# -ne 2 ]]; then echo "usage: $0 <app-dir> <out-dir>" >&2; exit 2; fi
handoff=$(realpath "$1")
out=$(realpath -m "$2")
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${AMI_BUILDER_IMAGE:-amazonlinux:2023}
mkdir -p "$out"

[[ -f "$handoff/app.yaml" && -d "$handoff/dist" ]] || { echo "$handoff must contain app.yaml and dist/" >&2; exit 2; }

sudo modprobe loop 2>/dev/null || true
docker pull "$image"

run_build() {
  docker run --privileged --rm \
    -v /dev:/dev \
    -v "$root:/work:ro" -v "$handoff:/handoff:ro" -v "$out:/out" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$image" bash /work/ami/in-container/build.sh /handoff /out
}

if ! run_build; then
  # KIWI's documented container quirk: loop nodes created on the host are not visible on the
  # first attempt ("Early loop device test failed"). One retry is enough.
  if grep -qi "loop device" "$out/kiwi.log" 2>/dev/null; then
    echo "loop device problem on first attempt, retrying once" >&2
    run_build
  else
    exit 1
  fi
fi

echo "== output"
ls -l "$out"
cat "$out/pcr_measurements.json"
