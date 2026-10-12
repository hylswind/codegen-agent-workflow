# App contract

This file is fixed by the pipeline. The app you generate from `SPEC.md` must follow it so the
pipeline can build, test and ship it without knowing which language you chose.

## Where the app runs

The app is installed natively into an Amazon Linux 2023 **Attestable AMI**:

- The root filesystem is a read-only erofs image protected by dm-verity, with a RAM-backed overlay
  on top. Writes anywhere in the tree succeed but go to memory and vanish on reboot; nothing
  written to the root tree ever persists. Your files live under `/opt/app`, owned by root.
- The main service runs as a non-root user that the app's own units define (see "systemd units");
  logs go to stdout/stderr (journald). Its writable scratch space is what systemd gives it
  (`StateDirectory=` → `$STATE_DIRECTORY`, `RuntimeDirectory=` → `$RUNTIME_DIRECTORY`) plus `/tmp`,
  all inside that RAM overlay and empty on every boot. Persistent data needs a volume the app mounts
  itself through one of its units.
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
system/*.service    # the app's systemd units; build copies them into dist/system/
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
units:                        # systemd units, relative to dist/; installed and enabled in the AMI
  - system/todo-api.service
```

| Field | Meaning |
|---|---|
| `name` | Image name and S3 path |
| `packages.runtime` | Packages the app needs at run time. Empty for static binaries |
| `packages.build` | Packages needed only to build or test. Never enter the AMI |
| `build` | Must leave **everything** the app needs at run time inside `./dist` (binary, assets, `node_modules`, vendored Python packages, the unit files under `dist/system/`) |
| `test` | Runs after `build` in the same container. Must not need network |
| `units` | Every systemd unit the app needs, at least its main service. See "systemd units" |

### Examples

Go (static binary, nothing to install at run time):

```yaml
name: todo-api
packages: { runtime: [], build: [golang] }
build: ./scripts/build.sh     # CGO_ENABLED=0 go build -o dist/todo-api ./cmd/todo-api && cp -r system dist/
test: go test ./...
units: [system/todo-api.service]
```

with `system/todo-api.service`:

```ini
[Unit]
Description=todo-api
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
WorkingDirectory=/opt/app
ExecStart=/opt/app/todo-api
Restart=always
RestartSec=2
StateDirectory=todo-api

[Install]
WantedBy=multi-user.target
```

Node.js: `packages: { runtime: [nodejs22], build: [nodejs22-npm] }`, `build` runs `npm ci && npm run build`
and copies `package.json`, `build/`, `node_modules/` and `system/` into `dist/`,
`ExecStart=/usr/bin/node /opt/app/build/server.js`.

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
   app mounts itself through one of its units.
4. `dist/` must be self-contained together with `packages.runtime`; nothing else is installed in
   the AMI.
5. `build` may use the network (downloading dependencies); `test` must not.
6. Log to stdout/stderr.

## systemd units

`units` lists every unit the app needs and `build` copies them into `dist/system/`. The AMI build
installs each `dist/<path>` as `/etc/systemd/system/<file name>` and enables it. Nothing else is
generated: the app's units decide who runs what, in which order and with which capabilities. The
pipeline creates no users.

The main service:

1. Must not run as root. Use `DynamicUser=yes` when the app keeps no persistent data. When it
   does, use a fixed-uid user created by one of the app's own root units (an idempotent
   `useradd -r -u <uid> …`), so file ownership on the persistent volume stays the same across
   boots and across images.
2. `WorkingDirectory=/opt/app`, `ExecStart=` with an absolute path, `Restart=always`,
   `StateDirectory=` and `RuntimeDirectory=` for RAM-backed scratch space,
   `AmbientCapabilities=CAP_NET_BIND_SERVICE` only when it binds a port below 1024,
   `Requires=`/`After=` on the units it depends on, `WantedBy=multi-user.target`.

Units that need root (preparing a data volume, creating users):

1. No `User=`. Everything they execute lives under `/opt/app/…` (absolute paths) or comes from
   `packages.runtime`.
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
