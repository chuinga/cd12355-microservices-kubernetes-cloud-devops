#!/usr/bin/env bash
# =====================================================================
# aws-microservices-sweeper.sh — DANGER: DESTROYS BILLABLE RESOURCES
# Batch mode by default after one preflight confirm (or use --yes).
# Prereqs: AWS CLI v2, Python (for tiny JSON processing).
# =====================================================================

set -u
set -o pipefail
trap 'echo "❌ Error on line $LINENO: $BASH_COMMAND"' ERR

# ---------------------- Config / Args ----------------------
ASSUME_YES=0
FORCE=0
KMS_WINDOW_DAYS=7
# Per-service toggles (1=do it, 0=skip)
DO_ROUTE53=1
DO_CLOUDFRONT=1
DO_EKS=1
DO_ECS=1
DO_ECR=1
DO_EC2=1
DO_SPOT=1
DO_ASG=1
DO_LT=1
DO_NAT=1
DO_EIP=1
DO_EBS_VOL=1
DO_EBS_SNAP=1
DO_AMI=1
DO_ELB_V2=1
DO_TG=1
DO_ELB_CLASSIC=1
DO_VPCE=1
DO_ENI=1
DO_RDS_INST=1
DO_RDS_CLUS=1
DO_S3=1
DO_KMS=1

ALL_REGIONS=0
CUSTOM_REGIONS=""

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --yes                 Run without any prompts (non-interactive).
  --all-regions         Sweep all regions (from EC2 describe-regions).
  --regions r1,r2,...   Sweep only the comma-separated regions.
  --force               Disable deletion protection on RDS/Clusters automatically.
  --kms-window N        Pending window (days) for KMS key deletion (default: 7).

  --no-route53 | --no-cloudfront | --no-eks | --no-ecs | --no-ecr | --no-ec2
  --no-spot | --no-asg | --no-lt | --no-nat | --no-eip | --no-ebs-vol
  --no-ebs-snap | --no-ami | --no-elb-v2 | --no-tg | --no-elb-classic
  --no-vpce | --no-eni | --no-rds-inst | --no-rds-clus | --no-s3 | --no-kms

Examples:
  $0 --yes --all-regions --force
  $0 --regions us-east-1,eu-west-1 --no-cloudfront --no-s3
USAGE
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --all-regions) ALL_REGIONS=1 ;;
    --regions) shift; CUSTOM_REGIONS="${1:-}";;
    --force) FORCE=1 ;;
    --kms-window) shift; KMS_WINDOW_DAYS="${1:-7}";;

    --no-route53) DO_ROUTE53=0 ;;
    --no-cloudfront) DO_CLOUDFRONT=0 ;;
    --no-eks) DO_EKS=0 ;;
    --no-ecs) DO_ECS=0 ;;
    --no-ecr) DO_ECR=0 ;;
    --no-ec2) DO_EC2=0 ;;
    --no-spot) DO_SPOT=0 ;;
    --no-asg) DO_ASG=0 ;;
    --no-lt) DO_LT=0 ;;
    --no-nat) DO_NAT=0 ;;
    --no-eip) DO_EIP=0 ;;
    --no-ebs-vol) DO_EBS_VOL=0 ;;
    --no-ebs-snap) DO_EBS_SNAP=0 ;;
    --no-ami) DO_AMI=0 ;;
    --no-elb-v2) DO_ELB_V2=0 ;;
    --no-tg) DO_TG=0 ;;
    --no-elb-classic) DO_ELB_CLASSIC=0 ;;
    --no-vpce) DO_VPCE=0 ;;
    --no-eni) DO_ENI=0 ;;
    --no-rds-inst) DO_RDS_INST=0 ;;
    --no-rds-clus) DO_RDS_CLUS=0 ;;
    --no-s3) DO_S3=0 ;;
    --no-kms) DO_KMS=0 ;;

    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
  shift
done

# ---------------------- Logging ----------------------
LOG_DIR="./logs/aws-microservices-sweeper"
TS=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/run-$TS.txt"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "📜 Logging to $LOG_FILE"

# ---------------------- Helpers ----------------------
confirm() {
  if (( ASSUME_YES )); then return 0; fi
  read -rp "$1 (y/N): " _a
  [[ "${_a:-N}" =~ ^[yY]$ ]]
}

nonempty() { [ -n "${1:-}" ] && [ "${1:-}" != "None" ]; }

# Sanitize lines read from AWS CLI output
_readarray_san() {
  local __name="$1"
  mapfile -t "$__name"
  # shellcheck disable=SC2086
  eval "$__name"='($(printf "%s\n" "${'"$__name"'[@]}" | tr -d "\r" | sed "/^$/d"))'
}

# Decode encoded authorization failure messages if present
try_decode_authz_msg() {
  local err_file="$1"
  if grep -q "Encoded authorization failure message:" "$err_file"; then
    local token
    token=$(sed -n 's/^.*Encoded authorization failure message: *//p' "$err_file" | tr -d '\r' | tr -d '\n')
    if nonempty "$token"; then
      echo "🔎 Decoding authorization failure details..."
      aws sts decode-authorization-message --encoded-message "$token" --query 'DecodedMessage' --output text 2>/dev/null || true
    fi
  fi
}

# --- EKS helpers ---
eks_wait_empty() {
  local cluster="$1"
  local start timeout=1800
  start=$(date +%s)
  while true; do
    local ngs fps ads
    ngs=$(aws eks list-nodegroups --cluster-name "$cluster" --query "length(nodegroups)" --output text 2>/dev/null || echo 0)
    fps=$(aws eks list-fargate-profiles --cluster-name "$cluster" --query "length(fargateProfileNames)" --output text 2>/dev/null || echo 0)
    ads=$(aws eks list-addons --cluster-name "$cluster" --query "length(addons)" --output text 2>/dev/null || echo 0)
    echo "   ⏳ Waiting EKS deps: NGs=$ngs, Fargate=$fps, AddOns=$ads"
    if [[ "$ngs" == "0" && "$fps" == "0" && "$ads" == "0" ]]; then break; fi
    sleep 10
    if (( $(date +%s) - start > timeout )); then
      echo "   ⚠️ Timeout waiting dependencies for $cluster"; break
    fi
  done
}

eks_teardown_cluster() {
  local c="$1"
  c=$(printf "%s" "$c" | tr -d '\r')
  echo "EKS cluster: $c"

  _readarray_san FPS < <(aws eks list-fargate-profiles --cluster-name "$c" --query "fargateProfileNames[]" --output text 2>/dev/null | tr '\t' '\n')
  for fp in "${FPS[@]:-}"; do
    if [[ -n "$fp" ]]; then
      aws eks delete-fargate-profile --cluster-name "$c" --fargate-profile-name "$fp" || true
    fi
  done

  _readarray_san NGS < <(aws eks list-nodegroups --cluster-name "$c" --query "nodegroups[]" --output text 2>/dev/null | tr '\t' '\n')
  for ng in "${NGS[@]:-}"; do
    if [[ -n "$ng" ]]; then
      aws eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" || true
    fi
  done

  _readarray_san ADS < <(aws eks list-addons --cluster-name "$c" --query "addons[]" --output text 2>/dev/null | tr '\t' '\n')
  for a in "${ADS[@]:-}"; do
    if [[ -n "$a" ]]; then
      aws eks delete-addon --cluster-name "$c" --addon-name "$a" || true
    fi
  done

  eks_wait_empty "$c"

  if ! aws eks delete-cluster --name "$c" 2>"/tmp/eks_del_err_$c.log"; then
    echo "⚠️ Failed to delete cluster $c"
    try_decode_authz_msg "/tmp/eks_del_err_$c.log"
  else
    aws eks wait cluster-deleted --name "$c" 2>/dev/null || echo "ℹ️ waiter finished/failed (may already be gone)."
  fi
}

# --- S3 (no jq) ---
s3_nuke_bucket() {
  local b="$1"
  echo "🪣 Emptying bucket: $b"

  aws s3 rm "s3://$b" --recursive || true

  if aws s3api get-bucket-versioning --bucket "$b" --query 'Status' --output text 2>/dev/null | grep -qE 'Enabled|Suspended'; then
    while true; do
      VERS=$(aws s3api list-object-versions --bucket "$b" --query 'Versions[].["Key","VersionId"]' --output text 2>/dev/null || true)
      if [[ -n "${VERS:-}" ]]; then
        while IFS=$'\t' read -r key ver; do
          [[ -z "$key" || -z "$ver" ]] && continue
          aws s3api delete-object --bucket "$b" --key "$key" --version-id "$ver" || true
        done <<< "$VERS"
      fi
      MARKS=$(aws s3api list-object-versions --bucket "$b" --query 'DeleteMarkers[].["Key","VersionId"]' --output text 2>/dev/null || true)
      if [[ -n "${MARKS:-}" ]]; then
        while IFS=$'\t' read -r key ver; do
          [[ -z "$key" || -z "$ver" ]] && continue
          aws s3api delete-object --bucket "$b" --key "$key" --version-id "$ver" || true
        done <<< "$MARKS"
      fi
      [[ -z "${VERS:-}" && -z "${MARKS:-}" ]] && break
    done
  fi

  aws s3api delete-bucket --bucket "$b" || echo "⚠️ Could not delete bucket $b (check access points/locks/cross-region)."
}

# ---------------------- Identity / Regions ----------------------
command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI not found in PATH"; exit 1; }

echo "🔒 Checking AWS identity..."
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
  echo "❌ Could not get AWS identity. Are your credentials configured?"; exit 1
fi
USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text)
CALLER_USER=$(echo "$USER_ARN" | sed 's/^.*\///')

CFG_REGION=$(aws configure get region || true)
DEFAULT_REGION=${CFG_REGION:-"us-east-1"}

# Regions
if (( ALL_REGIONS )); then
  echo "📍 Gathering regions..."
  REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>/dev/null || echo "$DEFAULT_REGION")
elif [[ -n "$CUSTOM_REGIONS" ]]; then
  REGIONS=$(echo "$CUSTOM_REGIONS" | tr ',' ' ')
else
  REGIONS="$DEFAULT_REGION"
fi

# ---------------------- Preflight Summary ----------------------
echo "🚨 You are logged in as:"
echo "👤 User:       $CALLER_USER"
echo "🔗 ARN:        $USER_ARN"
echo "🏢 Account ID: $ACCOUNT_ID"
echo "🌍 Default region: ${DEFAULT_REGION}"
echo
echo "🗺️ Regions to sweep:"
echo "$REGIONS" | tr ' \t' '\n' | sed '/^$/d' | while IFS= read -r reg; do printf '   - %s\n' "$reg"; done

services_list=()
((DO_ROUTE53)) && services_list+=("Route53")
((DO_CLOUDFRONT)) && services_list+=("CloudFront")
((DO_EKS)) && services_list+=("EKS")
((DO_ECS)) && services_list+=("ECS")
((DO_ECR)) && services_list+=("ECR")
((DO_EC2)) && services_list+=("EC2 instances")
((DO_SPOT)) && services_list+=("EC2 Spot Fleets")
((DO_ASG)) && services_list+=("AutoScaling")
((DO_LT)) && services_list+=("Launch Templates")
((DO_NAT)) && services_list+=("NAT Gateways")
((DO_EIP)) && services_list+=("Elastic IPs")
((DO_EBS_VOL)) && services_list+=("EBS Volumes")
((DO_EBS_SNAP)) && services_list+=("EBS Snapshots")
((DO_AMI)) && services_list+=("AMIs")
((DO_ELB_V2)) && services_list+=("ALB/NLB")
((DO_TG)) && services_list+=("Target Groups")
((DO_ELB_CLASSIC)) && services_list+=("Classic ELB")
((DO_VPCE)) && services_list+=("VPC Endpoints")
((DO_ENI)) && services_list+=("Unattached ENIs")
((DO_RDS_INST)) && services_list+=("RDS Instances")
((DO_RDS_CLUS)) && services_list+=("RDS Clusters")
((DO_S3)) && services_list+=("S3 Buckets")
((DO_KMS)) && services_list+=("KMS (schedule delete ${KMS_WINDOW_DAYS}d)")
echo "🧹 Services to sweep:"
for s in "${services_list[@]}"; do echo "   - $s"; done
echo

if ! confirm "❓ FINAL CHECK: Proceed with sweeping the above in account $ACCOUNT_ID?"; then
  echo "🛑 Aborting."; exit 1
fi

# ---------------------- Global (non-regional) ----------------------
if (( DO_ROUTE53 )); then
  echo "🧭 Route53: purge health checks & hosted zones"
  _readarray_san HC_IDS < <(aws route53 list-health-checks --query "HealthChecks[].Id" --output text 2>/dev/null | tr '\t' '\n')
  for hc in "${HC_IDS[@]:-}"; do
    if [[ -n "$hc" ]]; then
      aws route53 delete-health-check --health-check-id "$hc" || echo "⚠️ Failed to delete health check $hc"
    fi
  done

  _readarray_san ZONES < <(aws route53 list-hosted-zones --query "HostedZones[].Id" --output text 2>/dev/null | sed 's#/hostedzone/##g' | tr '\t' '\n')
  for zid in "${ZONES[@]:-}"; do
    [[ -z "$zid" ]] && continue
    echo "   🗂️ Zone: $zid — removing non-default records..."
    RRSETS_JSON=$(aws route53 list-resource-record-sets --hosted-zone-id "$zid" --output json 2>/dev/null || echo '{"ResourceRecordSets":[]}')
    CHANGES=$(
      RRSETS_JSON="$RRSETS_JSON" python - "$zid" <<'PY'
import os, sys, json
doc = json.loads(os.environ.get("RRSETS_JSON","{}"))
changes=[{"Action":"DELETE","ResourceRecordSet": rr}
         for rr in doc.get("ResourceRecordSets", []) if rr.get("Type") not in ("SOA","NS")]
print(json.dumps({"Changes":changes}))
PY
    )
    if [[ "$CHANGES" != '{"Changes":[]}' ]]; then
      aws route53 change-resource-record-sets --hosted-zone-id "$zid" --change-batch "$CHANGES" || echo "⚠️ Failed to purge records in zone $zid"
    fi
    aws route53 delete-hosted-zone --id "$zid" || echo "⚠️ Failed to delete zone $zid"
  done
else
  echo "⏭️ Skipping Route53."
fi

if (( DO_CLOUDFRONT )); then
  echo "🌍 CloudFront: disable & delete distributions"
  _readarray_san DISTS < <(aws cloudfront list-distributions --query "DistributionList.Items[].Id" --output text 2>/dev/null | tr '\t' '\n')
  for d in "${DISTS[@]:-}"; do
    [[ -z "$d" ]] && continue
    ETag=$(aws cloudfront get-distribution-config --id "$d" --query "ETag" --output text 2>/dev/null || echo "")
    if nonempty "$ETag"; then
      CFG=$(aws cloudfront get-distribution-config --id "$d" --output json 2>/dev/null | sed 's/"Enabled": true/"Enabled": false/g')
      aws cloudfront update-distribution --id "$d" --if-match "$ETag" --distribution-config "$CFG" || echo "⚠️ Disable failed for $d"
      sleep 5
      ETag2=$(aws cloudfront get-distribution --id "$d" --query "ETag" --output text 2>/dev/null || echo "")
      aws cloudfront delete-distribution --id "$d" --if-match "$ETag2" || echo "⚠️ Delete failed for $d"
    fi
  done
else
  echo "⏭️ Skipping CloudFront."
fi

# ---------------------- Regional loop ----------------------
for R in $REGIONS; do
  export AWS_DEFAULT_REGION="$R"
  echo ""
  echo "================================================================="
  echo "🌎 REGION: $R"
  echo "================================================================="
  echo "🧹 Starting regional sweeps in $R ..."

  # ----- EKS -----
  if (( DO_EKS )); then
    _readarray_san CLUSTERS < <(aws eks list-clusters --query "clusters[]" --output text 2>/dev/null | tr '\t' '\n')
    if ((${#CLUSTERS[@]})); then
      for c in "${CLUSTERS[@]}"; do
        if [[ -n "$c" ]]; then
          eks_teardown_cluster "$c"
        fi
      done
    else
      echo "✅ No EKS clusters."
    fi
  else
    echo "⏭️ Skipping EKS."
  fi

  # ----- ECS -----
  if (( DO_ECS )); then
    _readarray_san ECS_CLUS < <(aws ecs list-clusters --query "clusterArns[]" --output text 2>/dev/null | tr '\t' '\n')
    for ca in "${ECS_CLUS[@]:-}"; do
      [[ -z "$ca" ]] && continue
      echo "ECS cluster: $ca"
      _readarray_san SVCS < <(aws ecs list-services --cluster "$ca" --query "serviceArns[]" --output text 2>/dev/null | tr '\t' '\n')
      for s in "${SVCS[@]:-}"; do
        if [[ -n "$s" ]]; then
          aws ecs update-service --cluster "$ca" --service "$s" --desired-count 0 >/dev/null 2>&1 || true
          aws ecs delete-service --cluster "$ca" --service "$s" --force || true
        fi
      done
      _readarray_san TASKS < <(aws ecs list-tasks --cluster "$ca" --query "taskArns[]" --output text 2>/dev/null | tr '\t' '\n')
      for t in "${TASKS[@]:-}"; do
        if [[ -n "$t" ]]; then
          aws ecs stop-task --cluster "$ca" --task "$t" || true
        fi
      done
      _readarray_san CIS < <(aws ecs list-container-instances --cluster "$ca" --query "containerInstanceArns[]" --output text 2>/dev/null | tr '\t' '\n')
      for ci in "${CIS[@]:-}"; do
        if [[ -n "$ci" ]]; then
          aws ecs deregister-container-instance --cluster "$ca" --container-instance "$ci" --force || true
        fi
      done
      aws ecs delete-cluster --cluster "$ca" || echo "⚠️ Failed to delete ECS cluster $ca"
    done
  else
    echo "⏭️ Skipping ECS."
  fi

  # ----- ECR -----
  if (( DO_ECR )); then
    _readarray_san REPOS < <(aws ecr describe-repositories --query "repositories[].repositoryName" --output text 2>/dev/null | tr '\t' '\n')
    for rname in "${REPOS[@]:-}"; do
      if [[ -n "$rname" ]]; then
        aws ecr delete-repository --repository-name "$rname" --force || true
      fi
    done
    if ! ((${#REPOS[@]})); then echo "✅ No ECR repositories."; fi
  else
    echo "⏭️ Skipping ECR."
  fi

  # ----- EC2 / Network -----
  if (( DO_EC2 )); then
    _readarray_san INST < <(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null | tr '\t' '\n')
    if ((${#INST[@]})); then
      if ! aws ec2 terminate-instances --instance-ids "${INST[@]}" 2>"/tmp/term_err_$R.log"; then
        echo "⚠️ Terminate call failed."
        try_decode_authz_msg "/tmp/term_err_$R.log"
      fi
    else
      echo "✅ No EC2 instances."
    fi
  else
    echo "⏭️ Skipping EC2 instances."
  fi

  if (( DO_SPOT )); then
    _readarray_san SFR < <(aws ec2 describe-spot-fleet-requests --query "SpotFleetRequestConfigs[].SpotFleetRequestId" --output text 2>/dev/null | tr '\t' '\n')
    for id in "${SFR[@]:-}"; do
      if [[ -n "$id" ]]; then
        aws ec2 cancel-spot-fleet-requests --spot-fleet-request-ids "$id" --terminate-instances || true
      fi
    done
  fi

  if (( DO_ASG )); then
    _readarray_san ASGS < <(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text 2>/dev/null | tr '\t' '\n')
    for a in "${ASGS[@]:-}"; do
      if [[ -n "$a" ]]; then
        aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$a" --min-size 0 --max-size 0 --desired-capacity 0 || true
        aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$a" --force-delete || true
      fi
    done
  fi

  if (( DO_LT )); then
    _readarray_san LTS < <(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output text 2>/dev/null | tr '\t' '\n')
    for lt in "${LTS[@]:-}"; do
      if [[ -n "$lt" ]]; then
        aws ec2 delete-launch-template --launch-template-name "$lt" || true
      fi
    done
  fi

  if (( DO_NAT )); then
    _readarray_san NATS < <(aws ec2 describe-nat-gateways --query "NatGateways[?State!='deleted'].NatGatewayId" --output text 2>/dev/null | tr '\t' '\n')
    for n in "${NATS[@]:-}"; do
      if [[ -n "$n" ]]; then
        aws ec2 delete-nat-gateway --nat-gateway-id "$n" || true
      fi
    done
    if ! ((${#NATS[@]})); then echo "✅ No NAT Gateways."; fi
  fi

  if (( DO_EIP )); then
    _readarray_san EIPS < <(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text 2>/dev/null | tr '\t' '\n')
    for e in "${EIPS[@]:-}"; do
      if [[ -n "$e" ]]; then
        aws ec2 release-address --allocation-id "$e" || true
      fi
    done
    if ! ((${#EIPS[@]})); then echo "✅ No EIPs."; fi
  fi

  if (( DO_EBS_VOL )); then
    _readarray_san VOLS < <(aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId" --output text 2>/dev/null | tr '\t' '\n')
    for v in "${VOLS[@]:-}"; do
      if [[ -n "$v" ]]; then
        aws ec2 delete-volume --volume-id "$v" || true
      fi
    done
    if ! ((${#VOLS[@]})); then echo "✅ No unattached EBS volumes."; fi
  fi

  if (( DO_EBS_SNAP )); then
    _readarray_san SNAPS < <(aws ec2 describe-snapshots --owner-ids self --query "Snapshots[].SnapshotId" --output text 2>/dev/null | tr '\t' '\n')
    for s in "${SNAPS[@]:-}"; do
      if [[ -n "$s" ]]; then
        aws ec2 delete-snapshot --snapshot-id "$s" || true
      fi
    done
  fi

  if (( DO_AMI )); then
    _readarray_san AMIS < <(aws ec2 describe-images --owners self --query "Images[].ImageId" --output text 2>/dev/null | tr '\t' '\n')
    for ami in "${AMIS[@]:-}"; do
      [[ -z "$ami" ]] && continue
      _readarray_san SNAP_IDS < <(aws ec2 describe-images --image-ids "$ami" --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" --output text 2>/dev/null | tr '\t' '\n')
      aws ec2 deregister-image --image-id "$ami" || true
      for sid in "${SNAP_IDS[@]:-}"; do
        if [[ -n "$sid" ]]; then
          aws ec2 delete-snapshot --snapshot-id "$sid" || true
        fi
      done
    done
  fi

  if (( DO_ELB_V2 )); then
    _readarray_san LBSv2 < <(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null | tr '\t' '\n')
    for lb in "${LBSv2[@]:-}"; do
      if [[ -n "$lb" ]]; then
        aws elbv2 delete-load-balancer --load-balancer-arn "$lb" || true
      fi
    done
    if ! ((${#LBSv2[@]})); then echo "✅ No ALB/NLB."; fi
  fi

  if (( DO_TG )); then
    _readarray_san TGS < <(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text 2>/dev/null | tr '\t' '\n')
    for tg in "${TGS[@]:-}"; do
      if [[ -n "$tg" ]]; then
        aws elbv2 delete-target-group --target-group-arn "$tg" || true
      fi
    done
  fi

  if (( DO_ELB_CLASSIC )); then
    _readarray_san LBSv1 < <(aws elb describe-load-balancers --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null | tr '\t' '\n')
    for lb in "${LBSv1[@]:-}"; do
      if [[ -n "$lb" ]]; then
        aws elb delete-load-balancer --load-balancer-name "$lb" || true
      fi
    done
  fi

  if (( DO_VPCE )); then
    _readarray_san VPCE < <(aws ec2 describe-vpc-endpoints --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null | tr '\t' '\n')
    if ((${#VPCE[@]})); then
      if ! aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "${VPCE[@]}" 2>"/tmp/vpce_err_$R.log"; then
        echo "⚠️ Some endpoints failed."; try_decode_authz_msg "/tmp/vpce_err_$R.log"
      fi
    fi
  fi

  if (( DO_ENI )); then
    _readarray_san ENIS < <(aws ec2 describe-network-interfaces --filters Name=status,Values=available --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null | tr '\t' '\n')
    for eni in "${ENIS[@]:-}"; do
      if [[ -n "$eni" ]]; then
        aws ec2 delete-network-interface --network-interface-id "$eni" || true
      fi
    done
  fi

  # ----- Data / DB -----
  if (( DO_RDS_INST )); then
    _readarray_san RDSI < <(aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null | tr '\t' '\n')
    for r in "${RDSI[@]:-}"; do
      [[ -z "$r" ]] && continue
      DP=$(aws rds describe-db-instances --db-instance-identifier "$r" --query "DBInstances[0].DeletionProtection" --output text 2>/dev/null || echo "False")
      if [[ "$DP" == "True" ]]; then
        if (( FORCE )); then
          aws rds modify-db-instance --db-instance-identifier "$r" --no-deletion-protection --apply-immediately || true
        else
          echo "🔐 Skipping RDS instance $r (deletion protection ON; rerun with --force to disable)."; continue
        fi
      fi
      aws rds delete-db-instance --db-instance-identifier "$r" --skip-final-snapshot || true
    done
  fi

  if (( DO_RDS_CLUS )); then
    _readarray_san RDSC < <(aws rds describe-db-clusters --query "DBClusters[].DBClusterIdentifier" --output text 2>/dev/null | tr '\t' '\n')
    for rc in "${RDSC[@]:-}"; do
      [[ -z "$rc" ]] && continue
      DPc=$(aws rds describe-db-clusters --db-cluster-identifier "$rc" --query "DBClusters[0].DeletionProtection" --output text 2>/dev/null || echo "False")
      if [[ "$DPc" == "True" ]]; then
        if (( FORCE )); then
          aws rds modify-db-cluster --db-cluster-identifier "$rc" --no-deletion-protection --apply-immediately || true
        else
          echo "🔐 Skipping RDS cluster $rc (deletion protection ON; rerun with --force to disable)."; continue
        fi
      fi
      aws rds delete-db-cluster --db-cluster-identifier "$rc" --skip-final-snapshot || true
    done
  fi

  if (( DO_S3 )); then
    _readarray_san ALL_BUCKETS < <(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null | tr '\t' '\n')
    for b in "${ALL_BUCKETS[@]:-}"; do
      [[ -z "$b" ]] && continue
      BR=$(aws s3api get-bucket-location --bucket "$b" --query "LocationConstraint" --output text 2>/dev/null || echo "us-east-1")
      [[ "$BR" == "None" ]] && BR="us-east-1"
      if [[ "$BR" == "$R" ]]; then
        s3_nuke_bucket "$b"
      fi
    done
  else
    echo "⏭️ Skipping S3 in $R."
  fi

  if (( DO_KMS )); then
    _readarray_san KMS_KEYS < <(aws kms list-keys --query "Keys[].KeyId" --output text 2>/dev/null | tr '\t' '\n')
    for k in "${KMS_KEYS[@]:-}"; do
      [[ -z "$k" ]] && continue
      MANAGED=$(aws kms describe-key --key-id "$k" --query "KeyMetadata.KeyManager" --output text 2>/dev/null || echo "AWS")
      if [[ "$MANAGED" == "CUSTOMER" ]]; then
        aws kms schedule-key-deletion --key-id "$k" --pending-window-in-days "$KMS_WINDOW_DAYS" || true
      fi
    done
  else
    echo "⏭️ Skipping KMS in $R."
  fi

  echo "✅ Finished regional sweep for $R"
done

echo ""
echo "🎉 All requested sweeps completed."
