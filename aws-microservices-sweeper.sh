#!/bin/bash
# =====================================================================
# aws-microservices-sweeper.sh — DANGER: DESTROYS BILLABLE RESOURCES
# - No CloudFormation logic 
# - Logs everything to ./logs/aws-microservices-sweeper
# - Verifies AWS identity
# - Optional all-regions sweep
# - Per-service safe prompts (aimed at billable resources)
# - Handles tricky bits (EKS nodegroups/Fargate, ECS services/tasks,
#   ALBs/NLBs/TargetGroups, NAT/EIPs, RDS & Aurora, S3 emptying/versioned,
#   KMS scheduled deletion, Route53 zones, SageMaker endpoints/notebooks, etc.)
#
# Prereqs: AWS CLI v2.
# =====================================================================

set -u
set -o pipefail

# === LOGGING ===
LOG_DIR="./logs/aws-microservices-sweeper"
TS=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$LOG_DIR/run-$TS.txt"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "📜 Logging to $LOG_FILE"

# === HELPERS ===
confirm() { read -rp "$1 (y/N): " _a; [[ "${_a:-N}" =~ ^[yY]$ ]]; }
nonempty() { [ -n "${1:-}" ] && [ "${1:-}" != "None" ]; }

# === SAFETY / IDENTITY ===
command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI not found in PATH"; exit 1; }

echo "🔒 Checking AWS identity..."
if ! ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null); then
  echo "❌ Could not get AWS identity. Are your credentials configured?"
  exit 1
fi
USER_ARN=$(aws sts get-caller-identity --query "Arn" --output text)
CALLER_USER=$(echo "$USER_ARN" | sed 's/^.*\///')

CFG_REGION=$(aws configure get region || true)
REGION=${CFG_REGION:-"us-east-1"}

echo "🚨 You are logged in as:"
echo "👤 User:       $CALLER_USER"
echo "🔗 ARN:        $USER_ARN"
echo "🏢 Account ID: $ACCOUNT_ID"
echo "🌍 Default region: ${REGION}"
echo ""

if ! confirm "❓ Is this the RIGHT ACCOUNT to sweep potentially billable resources?"; then
  echo "🛑 Aborting."
  exit 1
fi

# === REGION SELECTION ===
ALL_REGIONS="n"
if confirm "🌐 Sweep ALL regions? (Recommended if you’re unsure where things are)"; then
  ALL_REGIONS="y"
fi

if [[ "$ALL_REGIONS" == "y" ]]; then
  echo "📍 Gathering regions..."
  REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>/dev/null || true)
  if [ -z "$REGIONS" ]; then
    echo "⚠️ Could not list regions. Falling back to configured region: $REGION"
    REGIONS="$REGION"
  fi
else
  REGIONS="$REGION"
fi

echo "🗺️ Regions to sweep: $REGIONS"
echo ""

# === GLOBAL (non-regional) CLEANUPS — run once ===
# Route 53 Hosted Zones & Health Checks (GLOBAL)
if confirm "🧭 Route 53: Delete ALL hosted zones & health checks? (hosted zones cost monthly)"; then
  # Health checks
  HC_IDS=$(aws route53 list-health-checks --query "HealthChecks[].Id" --output text 2>/dev/null || true)
  if nonempty "$HC_IDS"; then
    echo "🔎 Health checks: $HC_IDS"
    for hc in $HC_IDS; do
      aws route53 delete-health-check --health-check-id "$hc" || echo "⚠️ Failed to delete health check $hc"
    done
  else
    echo "✅ No health checks."
  fi
  # Hosted zones
  ZONES=$(aws route53 list-hosted-zones --query "HostedZones[].Id" --output text 2>/dev/null | sed 's#/hostedzone/##g' || true)
  if nonempty "$ZONES"; then
    for zid in $ZONES; do
      echo "🗂️ Hosted zone: $zid — removing non-default records..."
      # Remove all records except SOA/NS at zone apex
      RRSETS=$(aws route53 list-resource-record-sets --hosted-zone-id "$zid" --output json 2>/dev/null)
      CHANGES=$(echo "$RRSETS" | awk '
        /"ResourceRecords"/{rr=1} /]/ && rr{rr=0}
        {print}
      ' >/dev/null; echo "$RRSETS" | \
        python - <<'PY'
import sys,json
doc=json.load(sys.stdin)
changes=[]
for rr in doc.get("ResourceRecordSets",[]):
    if rr["Type"] in ("SOA","NS") and rr.get("Name","").endswith(doc.get("HostedZoneId","")):
        continue
    changes.append({"Action":"DELETE","ResourceRecordSet":rr})
print(json.dumps({"Changes":changes}))
PY
      )
      if [ -n "$CHANGES" ] && [ "$CHANGES" != '{"Changes":[]}' ]; then
        aws route53 change-resource-record-sets --hosted-zone-id "$zid" --change-batch "$CHANGES" || echo "⚠️ Failed to purge records in zone $zid"
      fi
      aws route53 delete-hosted-zone --id "$zid" || echo "⚠️ Failed to delete zone $zid"
    done
  else
    echo "✅ No hosted zones."
  fi
else
  echo "⏭️ Skipping Route 53."
fi

# CloudFront (GLOBAL) — disabling + delete (can take a while)
if confirm "🌍 CloudFront: Disable & DELETE ALL distributions?"; then
  DISTS=$(aws cloudfront list-distributions --query "DistributionList.Items[].Id" --output text 2>/dev/null || true)
  if nonempty "$DISTS"; then
    for d in $DISTS; do
      ETag=$(aws cloudfront get-distribution-config --id "$d" --query "ETag" --output text 2>/dev/null || echo "")
      if nonempty "$ETag"; then
        CFG=$(aws cloudfront get-distribution-config --id "$d" --output json 2>/dev/null | sed 's/"Enabled": true/"Enabled": false/g')
        aws cloudfront update-distribution --id "$d" --if-match "$ETag" --distribution-config "$CFG" || echo "⚠️ Disable failed for $d"
        echo "⏳ Waiting a bit before delete..."
        sleep 5
        ETag2=$(aws cloudfront get-distribution --id "$d" --query "ETag" --output text 2>/dev/null || echo "")
        aws cloudfront delete-distribution --id "$d" --if-match "$ETag2" || echo "⚠️ Delete failed for $d"
      fi
    done
  else
    echo "✅ No CloudFront distributions."
  fi
else
  echo "⏭️ Skipping CloudFront."
fi

# === REGIONAL SWEEP LOOP ===
for R in $REGIONS; do
  export AWS_DEFAULT_REGION="$R"
  echo ""
  echo "================================================================="
  echo "🌎 REGION: $R"
  echo "================================================================="

  echo "🧹 Starting regional sweeps in $R ..."

  # ----- CONTAINERS & KUBERNETES -----

  # EKS: delete nodegroups/fargate/addons then clusters
  CLUSTERS=$(aws eks list-clusters --query "clusters[]" --output text 2>/dev/null || true)
  if nonempty "$CLUSTERS" && confirm "☸️ EKS: Delete ALL clusters in $R (includes nodegroups/Fargate/addons)?"; then
    for c in $CLUSTERS; do
      echo "EKS cluster: $c"
      # Fargate profiles
      FPS=$(aws eks list-fargate-profiles --cluster-name "$c" --query "fargateProfileNames[]" --output text 2>/dev/null || true)
      for fp in $FPS; do aws eks delete-fargate-profile --cluster-name "$c" --fargate-profile-name "$fp" || true; done
      # Nodegroups
      NGS=$(aws eks list-nodegroups --cluster-name "$c" --query "nodegroups[]" --output text 2>/dev/null || true)
      for ng in $NGS; do
        aws eks delete-nodegroup --cluster-name "$c" --nodegroup-name "$ng" || true
      done
      # Addons
      ADS=$(aws eks list-addons --cluster-name "$c" --query "addons[]" --output text 2>/dev/null || true)
      for a in $ADS; do aws eks delete-addon --cluster-name "$c" --addon-name "$a" || true; done
      # Wait a bit for dependencies to drain
      sleep 5
      aws eks delete-cluster --name "$c" || echo "⚠️ Failed to delete EKS cluster $c"
    done
  else
    echo "✅ No EKS clusters (or skipped)."
  fi

  # ECS: delete services/tasks/container instances, then clusters
  ECS_CLUS=$(aws ecs list-clusters --query "clusterArns[]" --output text 2>/dev/null || true)
  if nonempty "$ECS_CLUS" && confirm "🐳 ECS: Delete ALL clusters in $R (services/tasks first)?"; then
    for ca in $ECS_CLUS; do
      echo "ECS cluster: $ca"
      # Services
      SVCS=$(aws ecs list-services --cluster "$ca" --query "serviceArns[]" --output text 2>/dev/null || true)
      for s in $SVCS; do
        aws ecs update-service --cluster "$ca" --service "$s" --desired-count 0 >/dev/null 2>&1 || true
        aws ecs delete-service --cluster "$ca" --service "$s" --force || true
      done
      # Tasks
      TASKS=$(aws ecs list-tasks --cluster "$ca" --query "taskArns[]" --output text 2>/dev/null || true)
      for t in $TASKS; do aws ecs stop-task --cluster "$ca" --task "$t" || true; done
      # Container instances
      CIS=$(aws ecs list-container-instances --cluster "$ca" --query "containerInstanceArns[]" --output text 2>/dev/null || true)
      for ci in $CIS; do
        aws ecs deregister-container-instance --cluster "$ca" --container-instance "$ci" --force || true
      done
      aws ecs delete-cluster --cluster "$ca" || echo "⚠️ Failed to delete ECS cluster $ca"
    done
  else
    echo "✅ No ECS clusters (or skipped)."
  fi

  # ECR: delete repos (force deletes images)
  REPOS=$(aws ecr describe-repositories --query "repositories[].repositoryName" --output text 2>/dev/null || true)
  if nonempty "$REPOS" && confirm "🗄️ ECR: Delete ALL repositories (images will be removed)?"; then
    for rname in $REPOS; do aws ecr delete-repository --repository-name "$rname" --force || true; done
  else
    echo "✅ No ECR repositories (or skipped)."
  fi

  # ----- CORE INFRA / NETWORK / COMPUTE -----

  # EC2 instances
  INST=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
         --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
  if nonempty "$INST" && confirm "🖥️ EC2: Terminate ALL instances in $R?"; then
    aws ec2 terminate-instances --instance-ids $INST || echo "⚠️ Terminate call failed."
  else
    echo "✅ No EC2 instances (or skipped)."
  fi

  # Spot Fleets
  SFR=$(aws ec2 describe-spot-fleet-requests --query "SpotFleetRequestConfigs[].SpotFleetRequestId" --output text 2>/dev/null || true)
  if nonempty "$SFR" && confirm "🎯 EC2: Cancel & terminate ALL Spot Fleets in $R?"; then
    for id in $SFR; do
      aws ec2 cancel-spot-fleet-requests --spot-fleet-request-ids "$id" --terminate-instances || true
    done
  fi

  # Auto Scaling groups
  ASGS=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[].AutoScalingGroupName" --output text 2>/dev/null || true)
  if nonempty "$ASGS" && confirm "📈 AutoScaling: Delete ALL ASGs in $R? (will try to set desired=0)"; then
    for a in $ASGS; do
      aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$a" --min-size 0 --max-size 0 --desired-capacity 0 || true
      aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$a" --force-delete || true
    done
  fi

  # Launch templates
  LTS=$(aws ec2 describe-launch-templates --query "LaunchTemplates[].LaunchTemplateName" --output text 2>/dev/null || true)
  if nonempty "$LTS" && confirm "🧾 EC2: Delete ALL Launch Templates in $R?"; then
    for lt in $LTS; do aws ec2 delete-launch-template --launch-template-name "$lt" || true; done
  fi

  # NAT Gateways
  NATS=$(aws ec2 describe-nat-gateways --query "NatGateways[?State!='deleted'].NatGatewayId" --output text 2>/dev/null || true)
  if nonempty "$NATS" && confirm "🚪 Delete ALL NAT Gateways in $R? (costly)"; then
    for n in $NATS; do aws ec2 delete-nat-gateway --nat-gateway-id "$n" || true; done
  else
    echo "✅ No NAT Gateways (or skipped)."
  fi

  # Elastic IPs (release)
  EIPS=$(aws ec2 describe-addresses --query "Addresses[].AllocationId" --output text 2>/dev/null || true)
  if nonempty "$EIPS" && confirm "📡 Release ALL Elastic IPs in $R?"; then
    for e in $EIPS; do aws ec2 release-address --allocation-id "$e" || true; done
  else
    echo "✅ No EIPs (or skipped)."
  fi

  # Unattached EBS Volumes
  VOLS=$(aws ec2 describe-volumes --filters Name=status,Values=available --query "Volumes[].VolumeId" --output text 2>/dev/null || true)
  if nonempty "$VOLS" && confirm "💽 Delete ALL unattached EBS volumes in $R?"; then
    for v in $VOLS; do aws ec2 delete-volume --volume-id "$v" || true; done
  else
    echo "✅ No unattached EBS volumes (or skipped)."
  fi

  # EBS Snapshots (owned)
  SNAPS=$(aws ec2 describe-snapshots --owner-ids self --query "Snapshots[].SnapshotId" --output text 2>/dev/null || true)
  if nonempty "$SNAPS" && confirm "🖼️ Delete ALL EBS snapshots you own in $R?"; then
    for s in $SNAPS; do aws ec2 delete-snapshot --snapshot-id "$s" || true; done
  fi

  # Custom AMIs + associated snapshots (best effort)
  AMIS=$(aws ec2 describe-images --owners self --query "Images[].ImageId" --output text 2>/dev/null || true)
  if nonempty "$AMIS" && confirm "🧩 Deregister ALL your AMIs in $R (then try to delete their snapshots)?"; then
    for ami in $AMIS; do
      SNAP_IDS=$(aws ec2 describe-images --image-ids "$ami" --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" --output text 2>/dev/null || true)
      aws ec2 deregister-image --image-id "$ami" || true
      for sid in $SNAP_IDS; do aws ec2 delete-snapshot --snapshot-id "$sid" || true; done
    done
  fi

  # Load Balancers (ALB/NLB + Classic) & Target Groups
  LBSv2=$(aws elbv2 describe-load-balancers --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null || true)
  if nonempty "$LBSv2" && confirm "⚖️ Delete ALL ALB/NLBs in $R?"; then
    for lb in $LBSv2; do aws elbv2 delete-load-balancer --load-balancer-arn "$lb" || true; done
  else
    echo "✅ No ALB/NLB (or skipped)."
  fi
  TGS=$(aws elbv2 describe-target-groups --query "TargetGroups[].TargetGroupArn" --output text 2>/dev/null || true)
  if nonempty "$TGS" && confirm "🎯 Delete ALL Target Groups in $R?"; then
    for tg in $TGS; do aws elbv2 delete-target-group --target-group-arn "$tg" || true; done
  fi
  LBSv1=$(aws elb describe-load-balancers --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null || true)
  if nonempty "$LBSv1" && confirm "🧮 Delete ALL Classic ELBs in $R?"; then
    for lb in $LBSv1; do aws elb delete-load-balancer --load-balancer-name "$lb" || true; done
  fi

  # VPC Endpoints & Unattached ENIs
  VPCE=$(aws ec2 describe-vpc-endpoints --query "VpcEndpoints[].VpcEndpointId" --output text 2>/dev/null || true)
  if nonempty "$VPCE" && confirm "🧩 Delete ALL VPC Endpoints in $R?"; then
    aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $VPCE || echo "⚠️ Some endpoints failed."
  fi
  ENIS=$(aws ec2 describe-network-interfaces --filters Name=status,Values=available --query "NetworkInterfaces[].NetworkInterfaceId" --output text 2>/dev/null || true)
  if nonempty "$ENIS" && confirm "🔌 Delete ALL unattached ENIs in $R?"; then
    for eni in $ENIS; do aws ec2 delete-network-interface --network-interface-id "$eni" || true; done
  fi

  # ----- DATA & DB -----

  # RDS instances
  RDS=$(aws rds describe-db-instances --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null || true)
  if nonempty "$RDS" && confirm "🗄️ RDS: DELETE ALL DB instances in $R (skip final snapshot)?"; then
    for r in $RDS; do
      DP=$(aws rds describe-db-instances --db-instance-identifier "$r" --query "DBInstances[0].DeletionProtection" --output text 2>/dev/null || echo "False")
      if [[ "$DP" == "True" ]]; then
        if confirm "   🔐 $r has deletion protection. Disable and continue?"; then
          aws rds modify-db-instance --db-instance-identifier "$r" --no-deletion-protection --apply-immediately || continue
        else
          continue
        fi
      fi
      aws rds delete-db-instance --db-instance-identifier "$r" --skip-final-snapshot || true
    done
