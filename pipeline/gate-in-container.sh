#!/usr/bin/env bash
# Runs as root inside amazonlinux:2023, started by pipeline/gate.sh, with the app mounted at /work:
# install packages, run the app's build (must create ./dist), run the app's tests.
# Inputs: /app.json (validated app.yaml), env HOST_UID HOST_GID
# Reports: /report/{packages,build,test}.log, /report/failed (name of the failing step)
set -uo pipefail

fail() { echo "$1" > /report/failed; echo "gate: $1 failed" >&2; exit 1; }
finish() { chown -R "${HOST_UID:-0}:${HOST_GID:-0}" /report /work; }
trap finish EXIT

# APP_* variables from /app.json (python3 is always present: dnf depends on it)
eval "$(python3 - <<'PY'
import json, shlex
a = json.load(open('/app.json'))
v = {
    'APP_PKGS_RUNTIME': ' '.join(a['packages']['runtime']),
    'APP_PKGS_BUILD': ' '.join(a['packages']['build']),
    'APP_BUILD': a['build'],
    'APP_TEST': a['test'],
}
print('\n'.join(f'{k}={shlex.quote(s)}' for k, s in v.items()))
PY
)"

install_packages() { # <log> <packages...>
  local log=$1; shift
  if [[ $# -eq 0 ]]; then echo "no packages to install" > "$log"; return 0; fi
  echo "dnf install $*" > "$log"
  if ! dnf -y install "$@" >> "$log" 2>&1; then
    grep -i 'no match for argument' "$log" | sed 's/^/unknown package: /' >&2 || true
    return 1
  fi
}

cd /work
# shellcheck disable=SC2086
install_packages /report/packages.log $APP_PKGS_BUILD $APP_PKGS_RUNTIME || fail packages
# /work is a git repo owned by the host user; tools that call git (go build's VCS stamping,
# npm) would otherwise fail with "dubious ownership".
command -v git >/dev/null && git config --global --add safe.directory '*'
rm -rf dist
if ! bash -c "$APP_BUILD" > /report/build.log 2>&1; then fail build; fi
if [[ ! -d dist || -z $(ls -A dist) ]]; then
  echo "build finished but ./dist is missing or empty" >> /report/build.log; fail build
fi
if ! bash -c "$APP_TEST" > /report/test.log 2>&1; then fail test; fi
echo "build and test ok"
