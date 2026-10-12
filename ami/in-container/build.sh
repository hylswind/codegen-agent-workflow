#!/usr/bin/env bash
# Runs as root inside a privileged amazonlinux:2023 container (started by ami/build-ami.sh).
#   build.sh <handoff-dir> <out-dir>
# 1. install the latest KIWI NG + NitroTPM tools + AWS's attestable image description
# 2. copy the description, add the app's runtime packages (keeping every <ignore> entry)
# 3. overlay dist/ as /opt/app plus the systemd units, enable them
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
# Renders the app unit and any privileged units from app.yaml "system.units";
# prints the installed system unit names, one per line.
mapfile -t system_units < <(python3 - "$handoff/app.yaml" "$desc" "$handoff/dist" <<'PY'
import pathlib, shlex, sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
desc = pathlib.Path(sys.argv[2])
dist = pathlib.Path(sys.argv[3])
units = (app.get('system') or {}).get('units') or []
names = [pathlib.Path(u).name for u in units]
deps = f"Requires={' '.join(names)}\nAfter={' '.join(names)}" if names else ''
unit = pathlib.Path('/work/ami/app.service.tmpl').read_text()
unit = (unit.replace('${APP_NAME}', app['name']).replace('${APP_EXEC}', app['exec'])
            .replace('${APP_SYSTEM_DEPS}', deps))
(desc / 'root/etc/systemd/system' / f"{app['name']}.service").write_text(unit)
for u, name in zip(units, names):
    dst = desc / 'root/etc/systemd/system' / name
    dst.write_bytes((dist / u).read_bytes())
    dst.chmod(0o644)
    print(name)
PY
)
chown -R root:root "$desc/root"
cat >> "$desc/config.sh" <<EOF

# --- added by codegen-agent-workflow: run the generated app as a service
useradd -r -s /sbin/nologin -d /opt/app app
systemctl enable ${app_name}.service
EOF
for u in "${system_units[@]}"; do
  echo "systemctl enable $u" >> "$desc/config.sh"
done
echo "system units: ${system_units[*]:-none}"

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
