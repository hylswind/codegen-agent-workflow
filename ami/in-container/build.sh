#!/usr/bin/env bash
# Runs as root inside a privileged amazonlinux:2023 container (started by ami/build-ami.sh).
#   build.sh <handoff-dir> <out-dir>
# 1. install the latest KIWI NG + NitroTPM tools + AWS's attestable image description
# 2. copy the description, add the app's runtime packages (keeping every <ignore> entry)
# 3. overlay dist/ as /opt/app, install and enable the app's systemd units
# 4. kiwi-ng system build  →  image.raw + pcr_measurements.json
set -euo pipefail

handoff=$1
out=$2
mkdir -p "$out"
cleanup() { chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$out" 2>/dev/null || true; }
trap cleanup EXIT
exec > >(tee -a "$out/kiwi.log") 2>&1

echo "== installing latest AL2023 toolchain"
dnf -y --releasever=latest upgrade
dnf -y install kiwi-cli python3-kiwi kiwi-systemdeps-core python3-poetry-core qemu-img veritysetup \
  erofs-utils aws-nitro-tpm-tools kiwi-image-descriptions-examples \
  util-linux findutils python3 python3-pyyaml rsync git
# AWS's edit_boot_install.sh runs nitro-tpm-pcr-compute through sudo. We already are root and the
# container has no PAM setup for sudo, so provide a pass-through sudo ahead of /usr/bin.
printf '#!/bin/sh\nexec "$@"\n' > /usr/local/bin/sudo
chmod +x /usr/local/bin/sudo
kiwi-ng --version
rpm -q aws-nitro-tpm-tools kiwi-image-descriptions-examples

echo "== preparing image description"
desc_src=/usr/share/kiwi-image-descriptions-examples/al2023/attestable-image-example
if [[ ! -d $desc_src ]]; then
  echo "description not found in the package, cloning upstream"
  git clone --depth 1 https://github.com/amazonlinux/kiwi-image-descriptions-examples /tmp/upstream
  desc_src=/tmp/upstream/kiwi-image-descriptions-examples/al2023/attestable-image-example
fi
desc=/tmp/desc
rm -rf "$desc"
cp -r "$desc_src" "$desc"

app_name=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["name"])' "$handoff/app.yaml")
mapfile -t runtime_pkgs < <(python3 -c 'import sys, yaml; print("\n".join(yaml.safe_load(open(sys.argv[1]))["packages"]["runtime"]))' "$handoff/app.yaml" | sed '/^$/d')
python3 /work/ami/in-container/customize-description.py "$desc/appliance.kiwi" \
  --name "attestable-$app_name" --add-packages "${runtime_pkgs[@]}"

echo "== adding the app to the root overlay"
mkdir -p "$desc/root/opt/app" "$desc/root/etc/systemd/system"
cp -a "$handoff/dist/." "$desc/root/opt/app/"
# Installs the units listed in app.yaml "units" from dist/; prints their file names, one per line.
mapfile -t units < <(python3 - "$handoff/app.yaml" "$desc" "$handoff/dist" <<'PY'
import pathlib, sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
desc = pathlib.Path(sys.argv[2])
dist = pathlib.Path(sys.argv[3])
for u in app['units']:
    name = pathlib.Path(u).name
    dst = desc / 'root/etc/systemd/system' / name
    dst.write_bytes((dist / u).read_bytes())
    dst.chmod(0o644)
    print(name)
PY
)
chown -R root:root "$desc/root"
{
  echo
  echo "# --- added by codegen-agent-workflow: enable the app's units"
  for u in "${units[@]}"; do echo "systemctl enable $u"; done
} >> "$desc/config.sh"
echo "units: ${units[*]}"

echo "== kiwi-ng system build"
target="$out/build"
rm -rf "$target"
kiwi-ng --loglevel 0 system build --description "$desc" --target-dir "$target"

echo "== collecting output"
raw=$(ls "$target"/*.raw | head -n 1)
mv "$raw" "$out/image.raw"
cp "$target/pcr_measurements.json" "$out/pcr_measurements.json"
cp "$target"/*.packages "$out/image.packages"
rm -rf "$target"
sha256sum "$out/image.raw"
cat "$out/pcr_measurements.json"
