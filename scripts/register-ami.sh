#!/usr/bin/env bash
# Turn an uploaded raw image into an attestable AMI (UEFI boot, NitroTPM 2.0):
#   S3 object → EBS snapshot (import-snapshot, RAW) → register-image
#
#   register-ami.sh s3://<bucket>/<key>/image.raw <ami-name>
#
# Needs: aws CLI with credentials in the bucket's region, the one-time "vmimport" service role
# (see README), and permissions ec2:ImportSnapshot, ec2:DescribeImportSnapshotTasks, ec2:RegisterImage.
set -euo pipefail

if [[ $# -ne 2 ]]; then echo "usage: $0 s3://<bucket>/<key>/image.raw <ami-name>" >&2; exit 2; fi
uri=$1
name=$2
path=${uri#s3://}
bucket=${path%%/*}
key=${path#*/}

task=$(aws ec2 import-snapshot --description "$name" \
  --disk-container "Format=RAW,UserBucket={S3Bucket=$bucket,S3Key=$key}" \
  --query ImportTaskId --output text)
echo "import task: $task"

while :; do
  detail=$(aws ec2 describe-import-snapshot-tasks --import-task-ids "$task" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)
  status=$(jq -r .Status <<< "$detail")
  echo "  $status $(jq -r '.Progress // ""' <<< "$detail") $(jq -r '.StatusMessage // ""' <<< "$detail")"
  case "$status" in
    completed) break ;;
    deleted|deleting) echo "import failed: $(jq -r '.StatusMessage // ""' <<< "$detail")" >&2; exit 1 ;;
  esac
  sleep 15
done
snapshot=$(jq -r .SnapshotId <<< "$detail")
echo "snapshot: $snapshot"

ami=$(aws ec2 register-image --name "$name" \
  --virtualization-type hvm --boot-mode uefi --architecture x86_64 \
  --root-device-name /dev/xvda \
  --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=$snapshot}" \
  --tpm-support v2.0 --ena-support \
  --query ImageId --output text)
echo "AMI: $ami"
