#!/usr/bin/env bash
# Runs as root inside amazonlinux:2023, started by pipeline/gate.sh.
#   build : install packages, run $APP_BUILD (must create ./dist), run $APP_TEST   (cwd /work = app dir)
#   smoke : install runtime packages only, start $APP_EXEC from /opt/app as user "app", poll healthcheck
# Inputs: /app.json (validated app.yaml), env HOST_UID HOST_GID
# Reports: /report/{packages,build,test,smoke}.log, /report/failed (name of the failing step)
set -uo pipefail
mode=$1

fail() { echo "$1" > /report/failed; echo "gate: $1 failed" >&2; exit 1; }
finish() { chown -R "${HOST_UID:-0}:${HOST_GID:-0}" /report; [[ -d /work ]] && chown -R "${HOST_UID:-0}:${HOST_GID:-0}" /work; }
trap finish EXIT

# APP_* variables from /app.json (python3 is always present: dnf depends on it)
eval "$(python3 - <<'PY'
import json, shlex
a = json.load(open('/app.json'))
v = {
    'APP_NAME': a['name'],
    'APP_PKGS_RUNTIME': ' '.join(a['packages']['runtime']),
    'APP_PKGS_BUILD': ' '.join(a['packages']['build']),
    'APP_BUILD': a['build'],
    'APP_TEST': a['test'],
    'APP_EXEC': a['exec'],
    'APP_PORT': str(a['port']),
    'APP_HC_PATH': a['healthcheck']['path'],
    'APP_HC_TIMEOUT': str(a['healthcheck'].get('timeout_s', 60)),
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

case "$mode" in
  build)
    cd /work
    # shellcheck disable=SC2086
    install_packages /report/packages.log $APP_PKGS_BUILD $APP_PKGS_RUNTIME || fail packages
    rm -rf dist
    if ! bash -c "$APP_BUILD" > /report/build.log 2>&1; then fail build; fi
    if [[ ! -d dist || -z $(ls -A dist) ]]; then
      echo "build finished but ./dist is missing or empty" >> /report/build.log; fail build
    fi
    if ! bash -c "$APP_TEST" > /report/test.log 2>&1; then fail test; fi
    echo "build and test ok"
    ;;

  smoke)
    log=/report/smoke.log
    : > "$log"
    # shellcheck disable=SC2086
    install_packages "$log" $APP_PKGS_RUNTIME || fail smoke
    dnf -y install util-linux shadow-utils curl-minimal >> "$log" 2>&1 || true
    useradd -r -s /sbin/nologin -d /opt/app app 2>>"$log" || true
    mkdir -p "/var/lib/$APP_NAME" "/run/$APP_NAME"
    chown app:app "/var/lib/$APP_NAME" "/run/$APP_NAME"
    export STATE_DIRECTORY="/var/lib/$APP_NAME" RUNTIME_DIRECTORY="/run/$APP_NAME"
    set -a; [[ -f /app.env ]] && . /app.env; set +a
    cd /opt/app
    echo "starting: $APP_EXEC" >> "$log"
    setpriv --reuid=app --regid=app --init-groups bash -c "exec $APP_EXEC" >> "$log" 2>&1 &
    pid=$!
    url="http://127.0.0.1:${APP_PORT}${APP_HC_PATH}"
    deadline=$(( SECONDS + APP_HC_TIMEOUT ))
    until curl -fsS -o /dev/null "$url" 2>>"$log"; do
      if ! kill -0 "$pid" 2>/dev/null; then echo "app exited before the healthcheck succeeded" >> "$log"; fail smoke; fi
      if (( SECONDS >= deadline )); then echo "healthcheck $url not ready within ${APP_HC_TIMEOUT}s" >> "$log"; kill "$pid" 2>/dev/null; fail smoke; fi
      sleep 1
    done
    echo "healthcheck $url returned 200" | tee -a "$log"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    ;;

  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac
