# codegen-agent-workflow

A GitHub Actions workflow that turns an **APP SPEC** into an **AWS Attestable AMI** and signs a
statement binding the two together:

1. **Check out the app repository** at the given commit. `SPEC.md` at its root is the spec; the
   app's code and `app.yaml` sit beside it.
2. **Agent pipeline**: a coding agent updates the app to the spec and to the current toolchain
   (language version, dependencies, AL2023 packages, fixes), a deterministic gate builds and tests
   it in a clean Amazon Linux 2023 container, an independent review session checks the changes
   since the base commit against the spec, and the agent fixes what is found. Repeats until the
   gate passes and the reviewer approves.
3. **Attestable AMI**: KIWI NG builds Amazon Linux 2023 with a unified kernel image, a read-only
   dm-verity root, and no SSH / SSM / cloud-init / Instance Connect, with the app installed natively
   under `/opt/app` and started by systemd. The build yields the NitroTPM reference measurements
   (PCR4, PCR7, PCR12).
4. **Upload** the raw image to S3.
5. **Sign the build-result statement** with GitHub Artifact Attestations: `statement.json` holds
   `sha256(spec)` + the image's PCR values; GitHub signs its hash and records the provenance
   (repository, workflow, commit, run) that produced it. The image needs no signature of its own:
   the PCRs are its identity.

Everything installs the latest version at run time (actions by major tag, `amazonlinux:2023`
floating tag, unpinned `dnf`/`apt` installs, the agent's own installer), so the workflow does not
need edits to pick up newer tools.

## One-time setup

Repository **secrets**:

| Secret | Value |
|---|---|
| `AGENT_AUTH_TOKEN` | For Claude Code: run `claude setup-token` locally (Pro/Max/Team/Enterprise, valid one year) and paste the `sk-ant-oat01-…` token. An Anthropic API key also works. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | An IAM user allowed to upload to the bucket (policy below). |

Repository **variables**:

| Variable | Value |
|---|---|
| `AWS_REGION` | Region of the bucket (and of the AMIs you will register from it). |
| `S3_BUCKET` | Bucket that receives `image.raw`. |
| `S3_PREFIX` | Optional key prefix. |

IAM policy for the upload user:

```json
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::<bucket>/*" },
    { "Effect": "Allow", "Action": "s3:ListBucket", "Resource": "arn:aws:s3:::<bucket>" } ] }
```

## Run it

Actions → **Build attestable AMI from spec** → *Run workflow*, or:

```
gh workflow run build-attestable-ami.yml \
  -f repo=https://github.com/<owner>/<app-repo> \
  -f commit=<40-hex commit sha> \
  -f model=claude-opus-5-5 \      # optional; empty = Claude Code's default model
  -f max_iterations=3
```

`model` exists so a newer model can be used without editing the workflow; the model actually
used is recorded per stage in `pipeline-report.json`.

The app repository must be public and, at that commit, contain `SPEC.md` at the root plus the
application itself laid out as `pipeline/CONTRACT.md` requires (`app.yaml`, build and test
scripts, source, tests). The agent never edits `SPEC.md`.

Outputs:

| Where | What |
|---|---|
| S3 `s3://<bucket>/<prefix>/<app>/<run id>/image.raw` | the raw disk image (uncompressed) |
| artifact `generated-source` | the updated app with its git history (the base commit followed by one commit per stage), `.pipeline/` transcripts and gate reports, `pipeline-report.json` |
| artifact `statement` | `statement.json`, the build result (below). Its signature and provenance stay on GitHub (attestation URL in the summary; `gh attestation download statement.json --repo <owner>/<repo>` fetches the bundle) |
| job summary | base repo and commit, spec sha256, PCR4/7/12, statement sha256, attestation URL, S3 URI |

`statement.json` (the spec hash is computed from `SPEC.md` exactly as committed at the base commit):

```json
{ "spec": { "sha256": "…" },
  "base": { "repo": "https://github.com/<owner>/<app-repo>", "commit": "…" },
  "measurements": { "hashAlgorithm": "SHA384", "PCR4": "…", "PCR7": "…", "PCR12": "…" } }
```

## Verify a statement

Download `statement.json` from the run's `statement` artifact, then:

```
gh attestation verify statement.json --repo <owner>/<repo>
```

`gh` verifies the Sigstore signature over the file's sha256 and the provenance: the file was
produced by this repository's workflow, at a given commit and run. Then compare `spec.sha256` with
`sha256sum` of the spec you expect, and `PCR4`/`PCR12` with the values an instance reports through
NitroTPM attestation (or put them in a KMS key policy with `kms:RecipientAttestation:NitroTPMPCR4`
and `kms:RecipientAttestation:NitroTPMPCR12`). PCR7 only becomes meaningful once UEFI Secure Boot
is enabled for the AMI.

Why the binding holds: the dm-verity root hash of the image lives in `/etc/veritytab` inside the
initrd, the initrd is inside the unified kernel image, and PCR4 is the measurement of that image.
Changing any file under `/opt/app` changes the root hash and therefore PCR4.

## Turn the image into an AMI

```
cargo install --locked coldsnap        # once; no prebuilt binaries are published
scripts/register-ami.sh s3://<bucket>/<key>/image.raw <ami-name>   # or a local image.raw
```

This downloads the image if given an S3 URI, writes it to an EBS snapshot with
[coldsnap](https://github.com/awslabs/coldsnap) (EBS direct API, no VM Import role), and runs
`register-image` with UEFI boot and `--tpm-support v2.0`. The credentials need `ebs:StartSnapshot`,
`ebs:PutSnapshotBlock`, `ebs:CompleteSnapshot` on `arn:aws:ec2:*::snapshot/*`, plus
`ec2:DescribeSnapshots`, `ec2:RegisterImage` and `s3:GetObject` on the bucket. Launch on a
NitroTPM-capable instance type (M5/M6/M7, C5/C6/C7, R5/R6/R7, T3/T4g and newer) with a security
group that allows the app's port. There is no SSH by design; watch `aws ec2 get-console-output` for
boot and service start, then hit the app on the port and path its SPEC.md defines.

## The agent

The workflow uses Claude Code. The agent sits behind a two-script interface in
`agents/claude-code/` (`install.sh`, `run.sh`; interface in `agents/README.md`) so it can be
replaced in code with little churn; it is not a run-time choice. The pipeline never depends on
agent-specific features: every stage is a fresh, unattended session whose state is the files in
the app directory.

## Layout

```
.github/workflows/build-attestable-ami.yml   the workflow (one job: fetch spec → pipeline → AMI → S3 → attest)
agents/                                      agent interface + claude-code implementation
pipeline/run-pipeline.sh                     checkout base → update → gate → review → [fix → gate → review]×N
pipeline/gate.sh, gate-in-container.sh       validate / build / test in amazonlinux:2023
pipeline/CONTRACT.md, schema/app.schema.json app.yaml contract the agent must follow (incl. optional root-run system units)
pipeline/prompts/                            system, update, review, fix prompts
ami/build-ami.sh, ami/in-container/          KIWI NG build in a privileged amazonlinux:2023 container
ami/app.service.tmpl                         systemd unit for the generated app
attest/make-statement.sh                     statement.json = spec sha256 + base commit + PCRs
scripts/register-ami.sh                      S3 image → snapshot → AMI
```

## Running pieces locally

- `pipeline/gate.sh <app-dir> <report-dir>` and `ami/build-ami.sh <app-dir> <out>` need Docker;
  the AMI build additionally needs loop devices on the host (Linux or WSL2 with Docker).
- `AGENT_AUTH_TOKEN=… agents/claude-code/run.sh prompt.txt <workdir> <out> edit` runs one agent task.
- `pipeline/run-pipeline.sh --base-repo <url> --base-commit <sha> --out app` runs the whole agent loop.
