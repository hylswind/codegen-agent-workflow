# App contract

This file is fixed by the pipeline. The app you generate from `SPEC.md` must follow it so the
pipeline can build, test and ship it without knowing which language you chose.

## Where the app runs

The app is installed natively into an Amazon Linux 2023 **Attestable AMI**:

- The root filesystem is read-only (erofs + dm-verity). Your files live under `/opt/app`.
- The only writable places are `/var/lib/<name>` (exposed to the process as `$STATE_DIRECTORY`),
  `/run/<name>` (`$RUNTIME_DIRECTORY`) and `/tmp`. They are RAM-backed and lost on reboot.
- There is **no SSH, no SSM agent, no cloud-init, no user-data, no serial login**. Nobody can log in.
  The app must start by itself from a systemd unit and configure itself from `env` in `app.yaml`,
  from EC2 instance metadata (IMDS) if it needs instance details, or from what it fetches itself.
- The process runs as the unprivileged user `app`, with `/opt/app` as working directory, and logs
  go to stdout/stderr (journald).

## Required layout

```
app.yaml            # this contract, filled in (see below)
scripts/build.sh    # or any command named in app.yaml "build"
scripts/test.sh     # or any command named in app.yaml "test"
README.md           # what the app does, how to run it locally
<source and tests>
```

## `app.yaml`

```yaml
name: todo-api                # [a-z0-9-], max 32 chars
packages:
  runtime: []                 # AL2023 dnf packages installed into the AMI
  build: [golang]             # AL2023 dnf packages needed only to build/test
build: ./scripts/build.sh     # runs at the app root inside amazonlinux:2023; must create ./dist
test: ./scripts/test.sh       # exit 0 = pass
exec: /opt/app/todo-api       # absolute path + args; cwd is /opt/app (the contents of dist/)
port: 8080                    # the app must listen on 0.0.0.0:<port>
healthcheck:
  path: /healthz              # GET returns 200 when the app is ready
  timeout_s: 60
env:                          # optional, non-secret, written to /etc/app/env
  LOG_LEVEL: info
```

| Field | Meaning |
|---|---|
| `name` | Image name, systemd unit name and `/var/lib/<name>` |
| `packages.runtime` | Packages the app needs at run time. Empty for static binaries |
| `packages.build` | Packages needed only to build or test. Never enter the AMI |
| `build` | Must leave **everything** the app needs at run time inside `./dist` (binary, assets, `node_modules`, vendored Python packages…) |
| `test` | Runs after `build` in the same container. Must not need network |
| `exec` | Becomes `ExecStart=` of the systemd unit. Absolute path, plain arguments, no shell syntax |
| `port` | TCP port, bound on `0.0.0.0` |
| `healthcheck.path` | GET that returns 200 when the app is ready; for checking the instance after launch (the pipeline does not call it) |
| `env` | Plain `KEY: value` pairs. No secrets |

### Examples

Go (static binary, nothing to install at run time):

```yaml
name: todo-api
packages: { runtime: [], build: [golang] }
build: CGO_ENABLED=0 go build -o dist/todo-api ./cmd/todo-api
test: go test ./...
exec: /opt/app/todo-api
port: 8080
healthcheck: { path: /healthz, timeout_s: 60 }
```

Node.js:

```yaml
name: todo-api
packages: { runtime: [nodejs22], build: [nodejs22-npm] }
build: npm ci && npm run build && npm ci --omit=dev && rm -rf dist && mkdir dist && cp -r package.json build node_modules dist/
test: npm test
exec: /usr/bin/node build/server.js
port: 8080
healthcheck: { path: /healthz, timeout_s: 60 }
env: { NODE_ENV: production }
```

### Amazon Linux 2023 package names

| Language | `packages.build` | `packages.runtime` | notes |
|---|---|---|---|
| Go | `golang` | (none) | build with `CGO_ENABLED=0` |
| Node.js | `nodejs22-npm` | `nodejs22` | copy `node_modules` into `dist/` |
| Python | `python3.12-pip` | `python3.12` | `pip install --target dist/vendor -r requirements.txt`, set `PYTHONPATH=/opt/app/vendor` in `env` |
| Rust | `cargo`, `rust` | (none) | static binary |
| Java | `maven`, `java-21-amazon-corretto-devel` | `java-21-amazon-corretto-headless` | ship the jar in `dist/` |
| C/C++ | `gcc`, `gcc-c++`, `make` | (none unless dynamically linked) | |

Unknown package names fail the gate; the error names them.

## Rules

1. No secrets, tokens or credentials in files or `env`.
2. Do not depend on SSH, cloud-init, user-data, or anything a person would do on the instance.
3. Listen on `0.0.0.0:<port>`; respond 200 on the healthcheck path once ready.
4. Write only under `$STATE_DIRECTORY`, `$RUNTIME_DIRECTORY` or `/tmp`.
5. `dist/` must be self-contained together with `packages.runtime`; nothing else is installed in
   the AMI.
6. `build` may use the network (downloading dependencies); `test` must not.
7. Log to stdout/stderr.

## What the gate checks

1. `app.yaml` validates against `pipeline/schema/app.schema.json`.
2. In a clean `amazonlinux:2023` container: install `packages.build` + `packages.runtime`; run `build`;
   `dist/` must be non-empty; run `test`.

Results are written to `.pipeline/gate-report/summary.json` plus `validate.log`, `packages.log`,
`build.log`, `test.log`.
