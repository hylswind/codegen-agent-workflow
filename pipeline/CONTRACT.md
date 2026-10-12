# App contract

This file is fixed by the pipeline. The app you generate from `SPEC.md` must follow it so the
pipeline can build, test and ship it without knowing which language you chose.

## Where the app runs

The app is installed natively into an Amazon Linux 2023 **Attestable AMI**:

- The root filesystem is a read-only erofs image protected by dm-verity, with a RAM-backed overlay
  on top. Writes anywhere in the tree succeed but go to memory and vanish on reboot; nothing
  written to the root tree ever persists. Your files live under `/opt/app`, owned by root.
- The process runs as the unprivileged user `app` with `/opt/app` as working directory; logs go
  to stdout/stderr (journald). The directories it may write are `/var/lib/<name>` (exposed as
  `$STATE_DIRECTORY`), `/run/<name>` (`$RUNTIME_DIRECTORY`) and `/tmp`, all inside that RAM
  overlay. Expect an empty state directory on every boot. Persistent data needs a volume the app
  mounts itself (see "Privileged system units").
- There is no package manager at run time: the image has no repository configuration and nobody
  can log in. Changing the system means building a new image.
- There is **no SSH, no SSM agent, no cloud-init, no user-data, no serial login**. Nobody can log in.
  The app must start by itself from a systemd unit and configure itself from built-in defaults,
  EC2 instance metadata (IMDS), or what it fetches itself (for example AWS Secrets Manager through
  the instance role). Everything baked into the image is fixed until a new image is built.

## Required layout

```
SPEC.md             # the specification; owned by the repository, never edited by the agent
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
```

| Field | Meaning |
|---|---|
| `name` | Image name, systemd unit name and `/var/lib/<name>` |
| `packages.runtime` | Packages the app needs at run time. Empty for static binaries |
| `packages.build` | Packages needed only to build or test. Never enter the AMI |
| `build` | Must leave **everything** the app needs at run time inside `./dist` (binary, assets, `node_modules`, vendored Python packages…) |
| `test` | Runs after `build` in the same container. Must not need network |
| `exec` | Becomes `ExecStart=` of the systemd unit. Absolute path, plain arguments, no shell syntax |
| `system.units` | Optional. Root-run systemd units shipped in `dist/system/`, see "Privileged system units" |

### Examples

Go (static binary, nothing to install at run time):

```yaml
name: todo-api
packages: { runtime: [], build: [golang] }
build: CGO_ENABLED=0 go build -o dist/todo-api ./cmd/todo-api
test: go test ./...
exec: /opt/app/todo-api
```

Node.js:

```yaml
name: todo-api
packages: { runtime: [nodejs22], build: [nodejs22-npm] }
build: npm ci && npm run build && npm ci --omit=dev && rm -rf dist && mkdir dist && cp -r package.json build node_modules dist/
test: npm test
exec: /usr/bin/node build/server.js
```

### Amazon Linux 2023 package names

| Language | `packages.build` | `packages.runtime` | notes |
|---|---|---|---|
| Go | `golang` | (none) | build with `CGO_ENABLED=0` |
| Node.js | `nodejs22-npm` | `nodejs22` | copy `node_modules` into `dist/` |
| Python | `python3.12-pip` | `python3.12` | `pip install --target dist/vendor -r requirements.txt`; the app adds `/opt/app/vendor` to `sys.path` |
| Rust | `cargo`, `rust` | (none) | static binary |
| Java | `maven`, `java-21-amazon-corretto-devel` | `java-21-amazon-corretto-headless` | ship the jar in `dist/` |
| C/C++ | `gcc`, `gcc-c++`, `make` | (none unless dynamically linked) | |

Unknown package names fail the gate; the error names them.

## Rules

1. No secrets, tokens or credentials in files.
2. Do not depend on SSH, cloud-init, user-data, or anything a person would do on the instance.
3. Everything written to the root filesystem, including `$STATE_DIRECTORY`, `$RUNTIME_DIRECTORY`
   and `/tmp`, lives in RAM and is lost on reboot. Data that must persist belongs on a volume the
   app mounts itself through one of its system units.
4. `dist/` must be self-contained together with `packages.runtime`; nothing else is installed in
   the AMI.
5. `build` may use the network (downloading dependencies); `test` must not.
6. Log to stdout/stderr.

## Privileged system units (optional)

Some apps need root work before they start, for example preparing a data volume. List systemd unit
files under `system.units`; paths are relative to `dist/` and `build` must produce them:

```yaml
system:
  units: [system/my-app-data.service]
```

For each unit the AMI build installs `dist/<path>` as `/etc/systemd/system/<name>.service`, enables
it, and adds `Requires=` and `After=` for it to the app's own unit, so the app starts only after
the unit succeeded. Rules for these units:

1. They run as root (no `User=`). Everything they execute lives under `/opt/app/…` (absolute
   paths) or comes from `packages.runtime`.
2. Idempotent: `Type=oneshot` with `RemainAfterExit=yes`; re-running after success is a no-op.
3. Fail closed: on any doubt exit non-zero with one log line starting with `REFUSED:`. Never
   destroy or reformat existing data.
4. No secrets in files. Key material they generate stays in memory or on the volume they protect.
5. Their logic is unit-testable offline with injected command paths (fake `cryptsetup`, `mount`
   and similar on `PATH`).

## What the gate checks

1. `app.yaml` validates against `pipeline/schema/app.schema.json`.
2. In a clean `amazonlinux:2023` container: install `packages.build` + `packages.runtime`; run `build`;
   `dist/` must be non-empty; run `test`.

Results are written to `.pipeline/gate-report/summary.json` plus `validate.log`, `packages.log`,
`build.log`, `test.log`.
