#!/usr/bin/env bash
# 13-spectro-permissions.sh — Compare current IAM permissions against SpectroCloud
#                              documented policy requirements for Palette/VerteX.
#
# Uses iam:SimulatePrincipalPolicy to test whether the current identity is allowed
# to perform each action in the upstream SpectroCloud permission sets. Groups results
# by policy so operators can see exactly which policy is "out of step" and which
# specific actions need to be granted.
#
# Reference: docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/
#
# Usage:
#   ./13-spectro-permissions.sh
#
# Requires: iam:SimulatePrincipalPolicy permission on the caller's own role.
# If that action is denied, falls back to empirical safe-probe for read-only actions.
set -euo pipefail

# shellcheck source=lib.sh
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${_LIB_DIR}/lib.sh" ]] && source "${_LIB_DIR}/lib.sh" || { echo "[ERROR] lib.sh not found — run scripts from their directory"; exit 1; }

section() { echo ""; echo "--- $1 ---"; echo ""; }

_IMDS_TOKEN=$(curl -sfm 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"
sts_preflight || true

ACCOUNT=$(aws_safe sts get-caller-identity --query Account --output text) || ACCOUNT="unknown"
ARN=$(aws_safe sts get-caller-identity --query Arn --output text) || ARN="unknown"
PARTITION="aws"
[[ "$REGION" == *"gov"* ]] && PARTITION="aws-us-gov"

echo "Region:    ${REGION}"
echo "Account:   ${ACCOUNT}"
echo "Partition: ${PARTITION}"
echo "Caller:    ${ARN}"

# ── Resolve the IAM principal ARN for simulation ────────────────────────────
# SimulatePrincipalPolicy requires the role ARN, not the assumed-role ARN.
ROLE_NAME=""
if [[ "$ARN" == *":assumed-role/"* ]]; then
    ROLE_NAME=$(echo "$ARN" | sed 's|.*:assumed-role/||' | cut -d/ -f1)
elif [[ "$ARN" == *":role/"* ]]; then
    ROLE_NAME=$(basename "$(echo "$ARN" | sed 's|.*:role/||')")
fi

PRINCIPAL_ARN=""
if [[ -n "$ROLE_NAME" ]]; then
    # Reconstruct the role ARN (handles paths by querying IAM)
    ROLE_ARN_FULL=$(aws iam get-role --role-name "$ROLE_NAME" \
        --query 'Role.Arn' --output text 2>/dev/null) || true
    PRINCIPAL_ARN="${ROLE_ARN_FULL:-arn:${PARTITION}:iam::${ACCOUNT}:role/${ROLE_NAME}}"
else
    PRINCIPAL_ARN="$ARN"
fi

echo "Principal: ${PRINCIPAL_ARN}"

# ── Check if SimulatePrincipalPolicy is available ────────────────────────────
CAN_SIMULATE=false
_SIM_TEST=$(aws iam simulate-principal-policy \
    --policy-source-arn "$PRINCIPAL_ARN" \
    --action-names sts:GetCallerIdentity \
    --output json 2>&1) || true

if echo "$_SIM_TEST" | jq -e '.EvaluationResults' &>/dev/null; then
    CAN_SIMULATE=true
    echo ""
    echo "[OK] iam:SimulatePrincipalPolicy is available — running full policy comparison"
else
    echo ""
    echo "[WARN] iam:SimulatePrincipalPolicy denied — comparison will be limited"
    echo "       Only read-only actions can be tested empirically."
    echo "       Request iam:SimulatePrincipalPolicy for a complete gap analysis."
fi

# ============================================================================
# SpectroCloud Palette/VerteX IAM Policy Definitions
# Source: docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/
# Last synced: 2026-04-17
# ============================================================================

# Each policy is an array of IAM action strings. The variable name matches
# the upstream SpectroCloud policy name for traceability.

PALETTE_CONTROLLER_POLICY=(
    # autoscaling
    autoscaling:CreateAutoScalingGroup autoscaling:CreateOrUpdateTags
    autoscaling:DeleteAutoScalingGroup autoscaling:DeleteTags
    autoscaling:DescribeAutoScalingGroups autoscaling:DescribeInstanceRefreshes
    autoscaling:StartInstanceRefresh autoscaling:UpdateAutoScalingGroup
    # ec2
    ec2:AllocateAddress ec2:AssignIpv6Addresses ec2:AssignPrivateIpAddresses
    ec2:AssociateRouteTable ec2:AssociateVpcCidrBlock ec2:AttachInternetGateway
    ec2:AttachNetworkInterface ec2:AuthorizeSecurityGroupIngress
    ec2:CreateCarrierGateway ec2:CreateEgressOnlyInternetGateway
    ec2:CreateInternetGateway ec2:CreateLaunchTemplate
    ec2:CreateLaunchTemplateVersion ec2:CreateNatGateway
    ec2:CreateNetworkInterface ec2:CreateRoute ec2:CreateRouteTable
    ec2:CreateSecurityGroup ec2:CreateSubnet ec2:CreateTags ec2:CreateVpc
    ec2:CreateVpcEndpoint ec2:DeleteCarrierGateway
    ec2:DeleteEgressOnlyInternetGateway ec2:DeleteInternetGateway
    ec2:DeleteLaunchTemplate ec2:DeleteLaunchTemplateVersions
    ec2:DeleteNatGateway ec2:DeleteRouteTable ec2:DeleteSecurityGroup
    ec2:DeleteSubnet ec2:DeleteTags ec2:DeleteVpc ec2:DeleteVpcEndpoints
    ec2:DescribeAccountAttributes ec2:DescribeAddresses
    ec2:DescribeAvailabilityZones ec2:DescribeCarrierGateways
    ec2:DescribeDhcpOptions ec2:DescribeEgressOnlyInternetGateways
    ec2:DescribeImages ec2:DescribeInstances ec2:DescribeInstanceTypes
    ec2:DescribeInternetGateways ec2:DescribeKeyPairs
    ec2:DescribeLaunchTemplates ec2:DescribeLaunchTemplateVersions
    ec2:DescribeNatGateways ec2:DescribeNetworkInterfaceAttribute
    ec2:DescribeNetworkInterfaces ec2:DescribeRouteTables
    ec2:DescribeSecurityGroups ec2:DescribeSubnets ec2:DescribeTags
    ec2:DescribeVolumes ec2:DescribeVpcAttribute ec2:DescribeVpcEndpoints
    ec2:DescribeVpcs ec2:DetachInternetGateway ec2:DetachNetworkInterface
    ec2:DisassociateAddress ec2:DisassociateRouteTable
    ec2:DisassociateVpcCidrBlock ec2:GetInstanceMetadataDefaults
    ec2:ModifyInstanceAttribute ec2:ModifyInstanceMetadataOptions
    ec2:ModifyNetworkInterfaceAttribute ec2:ModifySubnetAttribute
    ec2:ModifyVpcAttribute ec2:ModifyVpcEndpoint ec2:ReleaseAddress
    ec2:ReplaceRoute ec2:RevokeSecurityGroupIngress ec2:RunInstances
    ec2:TerminateInstances ec2:UnassignPrivateIpAddresses
    # elb
    elasticloadbalancing:AddTags
    elasticloadbalancing:ApplySecurityGroupsToLoadBalancer
    elasticloadbalancing:ConfigureHealthCheck
    elasticloadbalancing:CreateListener elasticloadbalancing:CreateLoadBalancer
    elasticloadbalancing:CreateTargetGroup elasticloadbalancing:DeleteListener
    elasticloadbalancing:DeleteLoadBalancer
    elasticloadbalancing:DeleteTargetGroup
    elasticloadbalancing:DeregisterInstancesFromLoadBalancer
    elasticloadbalancing:DescribeListeners
    elasticloadbalancing:DescribeLoadBalancerAttributes
    elasticloadbalancing:DescribeLoadBalancers
    elasticloadbalancing:DescribeTargetGroups
    elasticloadbalancing:DescribeTargetHealth
    elasticloadbalancing:DescribeTags
    elasticloadbalancing:ModifyLoadBalancerAttributes
    elasticloadbalancing:ModifyTargetGroupAttributes
    elasticloadbalancing:RegisterInstancesWithLoadBalancer
    elasticloadbalancing:RegisterTargets elasticloadbalancing:RemoveTags
    elasticloadbalancing:SetSecurityGroups elasticloadbalancing:SetSubnets
    # iam
    iam:CreateOpenIDConnectProvider iam:CreateServiceLinkedRole
    iam:DeleteOpenIDConnectProvider iam:GetOpenIDConnectProvider
    iam:ListOpenIDConnectProviders iam:PassRole iam:TagOpenIDConnectProvider
    # s3
    s3:DeleteObject s3:PutBucketOwnershipControls s3:PutBucketPolicy
    s3:PutBucketPublicAccessBlock s3:PutObject s3:PutObjectAcl
    # secrets / sts / tags
    secretsmanager:CreateSecret secretsmanager:DeleteSecret
    secretsmanager:TagResource
    sts:AssumeRole
    tag:GetResources
)

PALETTE_CONTROL_PLANE_POLICY=(
    autoscaling:DescribeAutoScalingGroups autoscaling:DescribeLaunchConfigurations
    autoscaling:DescribeTags
    ec2:AssignIpv6Addresses ec2:AttachVolume ec2:AuthorizeSecurityGroupIngress
    ec2:CreateRoute ec2:CreateSecurityGroup ec2:CreateTags ec2:CreateVolume
    ec2:DeleteRoute ec2:DeleteSecurityGroup ec2:DeleteVolume
    ec2:DescribeImages ec2:DescribeInstances ec2:DescribeRegions
    ec2:DescribeRouteTables ec2:DescribeSecurityGroups ec2:DescribeSubnets
    ec2:DescribeVolumes ec2:DescribeVpcs ec2:DetachVolume
    ec2:ModifyInstanceAttribute ec2:ModifyVolume ec2:RevokeSecurityGroupIngress
    elasticloadbalancing:AddTags
    elasticloadbalancing:ApplySecurityGroupsToLoadBalancer
    elasticloadbalancing:AttachLoadBalancerToSubnets
    elasticloadbalancing:ConfigureHealthCheck
    elasticloadbalancing:CreateListener elasticloadbalancing:CreateLoadBalancer
    elasticloadbalancing:CreateLoadBalancerListeners
    elasticloadbalancing:CreateLoadBalancerPolicy
    elasticloadbalancing:CreateTargetGroup elasticloadbalancing:DeleteListener
    elasticloadbalancing:DeleteLoadBalancer
    elasticloadbalancing:DeleteLoadBalancerListeners
    elasticloadbalancing:DeleteTargetGroup
    elasticloadbalancing:DeregisterInstancesFromLoadBalancer
    elasticloadbalancing:DeregisterTargets elasticloadbalancing:DescribeListeners
    elasticloadbalancing:DescribeLoadBalancerAttributes
    elasticloadbalancing:DescribeLoadBalancerPolicies
    elasticloadbalancing:DescribeLoadBalancers
    elasticloadbalancing:DescribeTargetGroups
    elasticloadbalancing:DescribeTargetHealth
    elasticloadbalancing:DetachLoadBalancerFromSubnets
    elasticloadbalancing:ModifyListener
    elasticloadbalancing:ModifyLoadBalancerAttributes
    elasticloadbalancing:ModifyTargetGroup
    elasticloadbalancing:RegisterInstancesWithLoadBalancer
    elasticloadbalancing:RegisterTargets
    elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer
    elasticloadbalancing:SetLoadBalancerPoliciesOfListener
    elasticloadbalancing:SetSecurityGroups
    iam:CreateServiceLinkedRole
    kms:DescribeKey
    sts:AssumeRole
)

PALETTE_NODES_POLICY=(
    ec2:AssignIpv6Addresses ec2:CreateTags ec2:DescribeInstanceTypes
    ec2:DescribeInstances ec2:DescribeNetworkInterfaces ec2:DescribeRegions
    ec2:DescribeTags ec2:GetInstanceMetadataDefaults
    ecr:BatchCheckLayerAvailability ecr:BatchGetImage ecr:DescribeRepositories
    ecr:GetAuthorizationToken ecr:GetDownloadUrlForLayer
    ecr:GetRepositoryPolicy ecr:ListImages
    s3:GetEncryptionConfiguration
    secretsmanager:DeleteSecret secretsmanager:GetSecretValue
    ssm:UpdateInstanceInformation
    ssmmessages:CreateControlChannel ssmmessages:CreateDataChannel
    ssmmessages:OpenControlChannel ssmmessages:OpenDataChannel
)

PALETTE_DEPLOYMENT_POLICY=(
    cloudformation:CreateStack cloudformation:DescribeStacks
    cloudformation:UpdateStack
    ec2:AttachVolume ec2:CreateSnapshot ec2:CreateTags ec2:CreateVolume
    ec2:DeleteNetworkInterface ec2:DeleteSnapshot ec2:DeleteTags
    ec2:DeleteVolume ec2:DescribeAvailabilityZones ec2:DescribeInstances
    ec2:DescribeKeyPairs ec2:DescribeSnapshots ec2:DescribeTags
    ec2:DescribeVolumes ec2:DescribeVolumesModifications ec2:DetachVolume
    ec2:ModifyVolume
    iam:AddRoleToInstanceProfile iam:AddUserToGroup iam:AttachGroupPolicy
    iam:CreateGroup iam:CreateInstanceProfile iam:CreatePolicy
    iam:CreatePolicyVersion iam:CreateRole iam:CreateUser iam:DeleteGroup
    iam:DeleteInstanceProfile iam:DeletePolicy iam:DeletePolicyVersion
    iam:DetachGroupPolicy iam:GetGroup iam:GetInstanceProfile iam:GetPolicy
    iam:GetRole iam:GetUser iam:ListPolicies iam:ListPolicyVersions
    iam:RemoveRoleFromInstanceProfile iam:RemoveUserFromGroup
    sts:AssumeRole sts:GetServiceBearerToken
)

PALETTE_EKS_POLICY=(
    ec2:AssociateVpcCidrBlock ec2:DisassociateVpcCidrBlock
    eks:AssociateEncryptionConfig eks:AssociateIdentityProviderConfig
    eks:CreateAddon eks:CreateCluster eks:CreateFargateProfile
    eks:CreateNodegroup eks:DeleteAddon eks:DeleteCluster
    eks:DeleteFargateProfile eks:DeleteNodegroup eks:DescribeAddon
    eks:DescribeAddonVersions eks:DescribeCluster eks:DescribeFargateProfile
    eks:DescribeIdentityProviderConfig eks:DescribeNodegroup
    eks:DisassociateIdentityProviderConfig eks:ListAddons eks:ListClusters
    eks:ListIdentityProviderConfigs eks:TagResource eks:UntagResource
    eks:UpdateAddon eks:UpdateClusterConfig eks:UpdateClusterVersion
    eks:UpdateNodegroupConfig eks:UpdateNodegroupVersion
    iam:AddClientIDToOpenIDConnectProvider iam:AttachRolePolicy
    iam:CreateOpenIDConnectProvider iam:CreateRole iam:CreateServiceLinkedRole
    iam:DeleteOpenIDConnectProvider iam:DeleteRole iam:DetachRolePolicy
    iam:GetOpenIDConnectProvider iam:GetPolicy iam:GetRole
    iam:ListAttachedRolePolicies iam:ListOpenIDConnectProviders iam:PassRole
    iam:TagRole iam:UntagRole iam:UpdateOpenIDConnectProviderThumbprint
    kms:CreateGrant kms:DescribeKey
    ssm:GetParameter
)

# ============================================================================
# Simulation engine
# ============================================================================

# Batch simulate: takes a policy name and an array of actions.
# Prints per-action results and returns summary counts.
_TOTAL_ALLOWED=0
_TOTAL_DENIED=0
_TOTAL_ERROR=0

simulate_policy() {
    local policy_name="$1"
    shift
    local actions=("$@")
    local action_count=${#actions[@]}

    section "Policy: ${policy_name} (${action_count} actions)"
    echo "Source: docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/"
    echo ""

    local allowed=0 denied=0 errors=0

    if $CAN_SIMULATE; then
        # Batch in groups of 25 (SimulatePrincipalPolicy limit per call)
        local batch_size=25
        local i=0
        while (( i < action_count )); do
            local batch=("${actions[@]:$i:$batch_size}")
            local result
            result=$(aws iam simulate-principal-policy \
                --policy-source-arn "$PRINCIPAL_ARN" \
                --action-names "${batch[@]}" \
                --output json 2>&1) || true

            if ! echo "$result" | jq -e '.EvaluationResults' &>/dev/null; then
                # Batch failed — try individually
                for action in "${batch[@]}"; do
                    printf "  %-58s " "$action"
                    echo "[ERROR] simulation batch failed"
                    errors=$((errors + 1))
                done
                i=$((i + batch_size))
                continue
            fi

            # Parse each result
            for action in "${batch[@]}"; do
                local decision
                decision=$(echo "$result" | jq -r \
                    --arg a "$action" \
                    '.EvaluationResults[] | select(.EvalActionName == $a) | .EvalDecision' \
                    2>/dev/null) || true

                printf "  %-58s " "$action"
                case "$decision" in
                    allowed)
                        echo "[ALLOWED]"
                        allowed=$((allowed + 1))
                        ;;
                    implicitDeny|explicitDeny)
                        echo "[DENIED]"
                        denied=$((denied + 1))
                        ;;
                    *)
                        echo "[${decision:-UNKNOWN}]"
                        errors=$((errors + 1))
                        ;;
                esac
            done

            i=$((i + batch_size))
            # Light rate-limit between batches
            sleep 0.1
        done
    else
        # Fallback: no simulation available — mark all as untested
        for action in "${actions[@]}"; do
            printf "  %-58s %s\n" "$action" "[UNTESTED — simulation denied]"
            errors=$((errors + 1))
        done
    fi

    echo ""
    echo "  ──────────────────────────────────────────────────────────────"
    printf "  %-20s ALLOWED: %d   DENIED: %d   ERRORS: %d   TOTAL: %d\n" \
        "${policy_name}:" "$allowed" "$denied" "$errors" "$action_count"

    if (( denied == 0 && errors == 0 )); then
        echo "  [OK] All ${action_count} actions allowed — policy fully satisfied"
    elif (( denied > 0 )); then
        echo "  [GAP] ${denied} actions denied — role is out of step with upstream docs"
    fi

    _TOTAL_ALLOWED=$((_TOTAL_ALLOWED + allowed))
    _TOTAL_DENIED=$((_TOTAL_DENIED + denied))
    _TOTAL_ERROR=$((_TOTAL_ERROR + errors))
}

# ============================================================================
# Run comparisons
# ============================================================================

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  SpectroCloud Palette/VerteX IAM Permission Gap Analysis"
echo "  Reference: docs.spectrocloud.com/clusters/public-cloud/aws/"
echo "             required-iam-policies/"
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Comparing current role permissions against six upstream SpectroCloud"
echo "policy definitions. DENIED results indicate actions that must be added"
echo "to the role's IAM policy (or its permissions boundary) before Palette"
echo "can provision and manage clusters."
echo ""
echo "GovCloud note: pricing:GetProducts is NOT available in GovCloud and is"
echo "excluded from this comparison. This is expected and not a gap."

simulate_policy "PaletteControllerPolicy"   "${PALETTE_CONTROLLER_POLICY[@]}"
simulate_policy "PaletteControlPlanePolicy" "${PALETTE_CONTROL_PLANE_POLICY[@]}"
simulate_policy "PaletteNodesPolicy"        "${PALETTE_NODES_POLICY[@]}"
simulate_policy "PaletteDeploymentPolicy"   "${PALETTE_DEPLOYMENT_POLICY[@]}"
simulate_policy "PaletteControllersEKSPolicy" "${PALETTE_EKS_POLICY[@]}"

# ============================================================================
# Overall summary
# ============================================================================

_TOTAL=$((_TOTAL_ALLOWED + _TOTAL_DENIED + _TOTAL_ERROR))

section "Overall Permission Gap Summary"
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
printf "  Total actions checked:  %d\n" "$_TOTAL"
printf "  Allowed:                %d\n" "$_TOTAL_ALLOWED"
printf "  Denied:                 %d\n" "$_TOTAL_DENIED"
printf "  Errors/Untested:        %d\n" "$_TOTAL_ERROR"
echo ""

if (( _TOTAL_DENIED == 0 && _TOTAL_ERROR == 0 )); then
    echo "  [OK] Role is fully aligned with upstream SpectroCloud IAM requirements."
    echo "        No permission gaps detected."
elif (( _TOTAL_DENIED > 0 )); then
    COVERAGE=$(( (_TOTAL_ALLOWED * 100) / (_TOTAL_ALLOWED + _TOTAL_DENIED) ))
    echo "  [GAP] Role covers ${COVERAGE}% of required actions (${_TOTAL_DENIED} denied)."
    echo ""
    echo "  To remediate: compare the DENIED actions above against the policies"
    echo "  attached to role '${ROLE_NAME:-unknown}' and its permissions boundary."
    echo "  Actions may be denied by:"
    echo "    1. Missing from the role's attached/inline policies"
    echo "    2. Blocked by a permissions boundary (even if the policy allows it)"
    echo "    3. Blocked by an SCP at the organization/OU level"
    echo ""
    echo "  SpectroCloud docs:"
    echo "    https://docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/"
fi

if (( _TOTAL_ERROR > 0 && !CAN_SIMULATE )); then
    echo ""
    echo "  [INFO] ${_TOTAL_ERROR} actions could not be tested because"
    echo "         iam:SimulatePrincipalPolicy is denied on this role."
    echo "         Grant that action for a complete gap analysis."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
