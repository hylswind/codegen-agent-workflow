# codegen-agent-workflow

A GitHub Actions workflow that turns an **APP SPEC** into an **AWS Attestable AMI** and signs a
statement binding the two together:

1. **Fetch the spec** from a public URL (for example a GitHub raw file URL).
2. **Agent pipeline**: a coding agent generates the app, a deterministic gate builds and tests it in
   a clean Amazon Linux 2023 container, an independent review session checks it against the spec,
   and the agent fixes what is found. Repeats until the gate passes and the reviewer approves.
3. **Attestable AMI**: KIWI NG builds Amazon Linux 2023 with a unified kernel image, a read-only
   dm-verity root, and no SSH / SSM / cloud-init / Instance Connect, with the app installed natively
   under `/opt/app` and started by systemd. The build yields the NitroTPM reference measurements
   (PCR4, PCR7, PCR12).
4. **Upload** the raw image to S3.
5. **Sign a statement** with GitHub Artifact Attestations: subject = the raw image, predicate =
   `sha256(spec)` + the PCR values.

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
| `AGENT_MODEL` | Optional model override passed to the agent. |

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
  -f spec_url=https://raw.githubusercontent.com/<owner>/<repo>/main/spec.md \
  -f max_iterations=3
```

Outputs:

| Where | What |
|---|---|
| S3 `s3://<bucket>/<prefix>/<app>/<run id>/image.raw` | the raw disk image (uncompressed) |
| artifact `generated-source` | the generated app with its local git history (one commit per stage), `.pipeline/` transcripts and gate reports, `spec.md`, `pipeline-report.json` |
| artifact `attestation` | `statement.json` (the signed in-toto statement, decoded), `attestation.sigstore.json` (Sigstore bundle), `predicate.json`, `pcr_measurements.json`, `image.packages`, `kiwi.log`, `spec.md` |
| job summary | spec sha256, image sha256, PCR4/7/12, attestation URL, S3 URI |

The predicate is intentionally minimal:

```json
{ "spec": { "sha256": "…" },
  "measurements": { "hashAlgorithm": "SHA384", "PCR4": "…", "PCR7": "…", "PCR12": "…" } }
```

## Verify a statement

```
aws s3 cp s3://<bucket>/<key>/image.raw .
gh attestation verify image.raw --repo <owner>/<repo> --format json \
  | jq '.[0].verificationResult.statement.predicate'
```

`gh` verifies the Sigstore signature and that the statement was produced by this repository's
workflow. Compare `spec.sha256` with `sha256sum` of the spec you expect, and `PCR4`/`PCR12` with
the values an instance reports through NitroTPM attestation (or put them in a KMS key policy with
`kms:RecipientAttestation:NitroTPMPCR4` and `kms:RecipientAttestation:NitroTPMPCR12`). PCR7 only
becomes meaningful once UEFI Secure Boot is enabled for the AMI.

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
boot and service start, then hit `http://<ip>:<port><healthcheck>`.

## Swap the agent

Agents live in `agents/<name>/` and expose two scripts, `install.sh` and `run.sh`
(interface in `agents/README.md`). Add a directory and pass `agent=<name>` to the workflow; the
workflow file does not change. The pipeline never depends on agent-specific features: every stage
is a fresh, unattended session whose state is the files in the app directory.

## Layout

```
.github/workflows/build-attestable-ami.yml   the workflow (one job: fetch spec → pipeline → AMI → S3 → attest)
agents/                                      agent interface + claude-code implementation
pipeline/run-pipeline.sh                     generate → gate → review → [fix → gate → review]×N
pipeline/gate.sh, gate-in-container.sh       validate / build / test / smoke in amazonlinux:2023
pipeline/CONTRACT.md, schema/app.schema.json app.yaml contract the agent must follow
pipeline/prompts/                            system, generate, review, fix prompts
ami/build-ami.sh, ami/in-container/          KIWI NG build in a privileged amazonlinux:2023 container
ami/app.service.tmpl                         systemd unit for the generated app
attest/make-predicate.sh                     predicate = spec sha256 + PCRs
scripts/register-ami.sh                      S3 image → snapshot → AMI
```

## Running pieces locally

- `pipeline/gate.sh <app-dir> <report-dir>` and `ami/build-ami.sh <app-dir> <out>` need Docker;
  the AMI build additionally needs loop devices on the host (Linux or WSL2 with Docker).
- `AGENT_AUTH_TOKEN=… agents/claude-code/run.sh prompt.txt <workdir> <out> edit` runs one agent task.
- `pipeline/run-pipeline.sh --spec spec.md --out app` runs the whole agent loop.
