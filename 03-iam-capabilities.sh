#!/usr/bin/env bash
# 03-iam-capabilities.sh — Empirical IAM capability probing (read-only calls)
# Tests what the current identity can actually do by making safe, read-only API calls.
# Every call here is non-destructive — list/describe/get operations only.
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }
probe() {
    local label="$1"
    shift
    printf "  %-55s " "$label"
    if OUTPUT=$("$@" 2>&1); then
        echo "[ALLOWED]"
        return 0
    else
        if echo "$OUTPUT" | grep -qi "AccessDenied\|UnauthorizedAccess\|not authorized\|forbidden"; then
            echo "[DENIED]"
        elif echo "$OUTPUT" | grep -qi "NoSuchEntity\|NotFoundException\|ResourceNotFoundException"; then
            echo "[ALLOWED] (resource not found)"
        elif echo "$OUTPUT" | grep -qi "InvalidParameterValue\|ValidationError"; then
            echo "[ALLOWED] (param error — call was accepted)"
        else
            echo "[ERROR] $(echo "$OUTPUT" | head -1 | cut -c1-80)"
        fi
        return 1
    fi
}

section "IAM Capabilities Probe"
echo "Testing read-only API calls to determine effective permissions."
echo "DENIED results may indicate permissions boundary restrictions."
echo ""

# ---------- STS ----------
section "STS"
probe "sts:GetCallerIdentity"            aws sts get-caller-identity --output json
probe "sts:GetSessionToken"              aws sts get-session-token --output json
probe "sts:GetAccessKeyInfo"             aws sts get-access-key-info --access-key-id AKIAIOSFODNN7EXAMPLE --output json

# ---------- IAM ----------
section "IAM — Identity & Access"
probe "iam:ListRoles"                    aws iam list-roles --max-items 1 --output json
probe "iam:ListUsers"                    aws iam list-users --max-items 1 --output json
probe "iam:ListPolicies"                 aws iam list-policies --scope Local --max-items 1 --output json
probe "iam:ListPolicies (AWS)"           aws iam list-policies --scope AWS --max-items 1 --output json
probe "iam:ListOpenIDConnectProviders"   aws iam list-open-id-connect-providers --output json
probe "iam:ListSAMLProviders"            aws iam list-saml-providers --output json
probe "iam:GetAccountSummary"            aws iam get-account-summary --output json
probe "iam:GetAccountAuthorizationDetails" aws iam get-account-authorization-details --max-items 1 --output json
probe "iam:ListInstanceProfiles"         aws iam list-instance-profiles --max-items 1 --output json
probe "iam:ListServiceSpecificCredentials" aws iam list-service-specific-credentials --output json

# ---------- EKS ----------
section "EKS"
probe "eks:ListClusters"                 aws eks list-clusters --output json
probe "eks:ListAddons (if cluster)"      aws eks list-addons --cluster-name placeholder --output json
probe "eks:ListFargateProfiles"          aws eks list-fargate-profiles --cluster-name placeholder --output json
probe "eks:ListNodegroups"               aws eks list-nodegroups --cluster-name placeholder --output json
probe "eks:DescribeAddonVersions"        aws eks describe-addon-versions --max-results 1 --output json

# If we can list clusters, describe each
CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)
if [[ -n "$CLUSTERS" ]]; then
    for CLUSTER in $CLUSTERS; do
        section "EKS Cluster: ${CLUSTER}"
        probe "eks:DescribeCluster (${CLUSTER})"  aws eks describe-cluster --name "$CLUSTER" --output json
        probe "eks:ListNodegroups (${CLUSTER})"    aws eks list-nodegroups --cluster-name "$CLUSTER" --output json
        probe "eks:ListAddons (${CLUSTER})"        aws eks list-addons --cluster-name "$CLUSTER" --output json

        # Check OIDC issuer
        OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
        if [[ -n "$OIDC_ISSUER" && "$OIDC_ISSUER" != "None" ]]; then
            echo "  OIDC Issuer: ${OIDC_ISSUER}"
        fi
    done
fi

# ---------- EC2 ----------
section "EC2"
probe "ec2:DescribeInstances"            aws ec2 describe-instances --max-results 5 --output json
probe "ec2:DescribeVpcs"                 aws ec2 describe-vpcs --output json
probe "ec2:DescribeSubnets"              aws ec2 describe-subnets --max-results 5 --output json
probe "ec2:DescribeSecurityGroups"        aws ec2 describe-security-groups --max-results 5 --output json
probe "ec2:DescribeRouteTables"          aws ec2 describe-route-tables --max-results 5 --output json
probe "ec2:DescribeNatGateways"          aws ec2 describe-nat-gateways --max-results 5 --output json
probe "ec2:DescribeVpcEndpoints"         aws ec2 describe-vpc-endpoints --max-results 5 --output json
probe "ec2:DescribeNetworkInterfaces"    aws ec2 describe-network-interfaces --max-results 5 --output json
probe "ec2:DescribeImages (self)"        aws ec2 describe-images --owners self --max-results 5 --output json
probe "ec2:DescribeKeyPairs"             aws ec2 describe-key-pairs --output json
probe "ec2:DescribeAvailabilityZones"    aws ec2 describe-availability-zones --output json
probe "ec2:DescribeRegions"              aws ec2 describe-regions --output json

# ---------- ECR ----------
section "ECR"
probe "ecr:GetAuthorizationToken"        aws ecr get-authorization-token --output json
probe "ecr:DescribeRepositories"         aws ecr describe-repositories --max-results 5 --output json
probe "ecr:GetRegistryPolicy"            aws ecr get-registry-policy --output json
probe "ecr:DescribeRegistry"             aws ecr describe-registry --output json

# ---------- S3 ----------
section "S3"
probe "s3:ListBuckets"                   aws s3api list-buckets --output json
probe "s3:GetBucketLocation"             aws s3api get-bucket-location --bucket placeholder --output json

# ---------- CloudFormation ----------
section "CloudFormation"
probe "cloudformation:ListStacks"        aws cloudformation list-stacks --max-items 5 --output json
probe "cloudformation:DescribeStacks"    aws cloudformation describe-stacks --output json

# ---------- Organizations ----------
section "Organizations"
probe "organizations:DescribeOrganization"  aws organizations describe-organization --output json
probe "organizations:ListAccounts"          aws organizations list-accounts --max-results 5 --output json

# ---------- Security Hub ----------
section "Security Hub"
probe "securityhub:GetFindings"          aws securityhub get-findings --max-results 1 --output json
probe "securityhub:GetEnabledStandards"  aws securityhub get-enabled-standards --output json

# ---------- CloudWatch ----------
section "CloudWatch / Logs"
probe "logs:DescribeLogGroups"           aws logs describe-log-groups --limit 5 --output json
probe "cloudwatch:ListMetrics"           aws cloudwatch list-metrics --output json

# ---------- SSM ----------
section "Systems Manager"
probe "ssm:DescribeInstanceInformation"  aws ssm describe-instance-information --max-results 5 --output json
probe "ssm:GetParametersByPath (/)"      aws ssm get-parameters-by-path --path "/" --max-results 1 --output json

echo ""
echo "Probe complete. DENIED results indicate permissions boundary or policy restrictions."
