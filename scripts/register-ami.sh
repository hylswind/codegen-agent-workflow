#!/usr/bin/env bash
# Turn a built raw image into an attestable AMI (UEFI boot, NitroTPM 2.0) with coldsnap:
#   image.raw → EBS snapshot (EBS direct API, no vmimport role) → register-image
#
#   register-ami.sh <image.raw | s3://bucket/key/image.raw> <ami-name>
#
# Needs: aws CLI, coldsnap (cargo install --locked coldsnap), and credentials allowed to
#   ebs:StartSnapshot, ebs:PutSnapshotBlock, ebs:CompleteSnapshot, ec2:DescribeSnapshots,
#   ec2:RegisterImage (plus s3:GetObject when an s3:// URI is given).
set -euo pipefail

if [[ $# -ne 2 ]]; then echo "usage: $0 <image.raw | s3://bucket/key/image.raw> <ami-name>" >&2; exit 2; fi
image=$1
name=$2
command -v coldsnap >/dev/null || { echo "coldsnap not found; install with: cargo install --locked coldsnap" >&2; exit 2; }

if [[ $image == s3://* ]]; then
  local_file=$(basename "$image")
  if [[ ! -f $local_file ]]; then
    echo "downloading $image"
    aws s3 cp "$image" "$local_file"
  fi
  image=$local_file
fi
[[ -f $image ]] || { echo "not found: $image" >&2; exit 2; }

echo "uploading $image as an EBS snapshot"
snapshot=$(coldsnap upload --wait --omit-zero-blocks --tag "Key=Name,Value=$name" "$image")
echo "snapshot: $snapshot"

ami=$(aws ec2 register-image --name "$name" \
  --virtualization-type hvm --boot-mode uefi --architecture x86_64 \
  --root-device-name /dev/xvda \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$snapshot}" \
  --tpm-support v2.0 --ena-support \
  --query ImageId --output text)
echo "AMI: $ami"
