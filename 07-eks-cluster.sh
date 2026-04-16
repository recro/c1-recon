#!/usr/bin/env bash
# 07-eks-cluster.sh — EKS cluster details, OIDC provider config, node groups
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }

_IMDS_TOKEN=$(curl -sfm 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
echo "Region:  ${REGION}"
echo "Account: ${ACCOUNT}"

# ---------- List Clusters ----------
section "EKS Clusters"
CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text 2>/dev/null) || true

if [[ -z "$CLUSTERS" ]]; then
    echo "[INFO] No EKS clusters found (or eks:ListClusters denied)"
    echo "If clusters exist but you can't see them, this is a permissions issue."
    exit 0
fi

echo "Clusters found: ${CLUSTERS}"

for CLUSTER in $CLUSTERS; do
    section "Cluster: ${CLUSTER}"

    # ---------- Cluster Details ----------
    CLUSTER_INFO=$(aws eks describe-cluster --name "$CLUSTER" --output json 2>/dev/null) || true
    if [[ -z "$CLUSTER_INFO" ]]; then
        echo "[DENIED] Cannot describe cluster ${CLUSTER}"
        continue
    fi

    echo "$CLUSTER_INFO" | jq '{
        Name: .cluster.name,
        Arn: .cluster.arn,
        Version: .cluster.version,
        PlatformVersion: .cluster.platformVersion,
        Status: .cluster.status,
        Endpoint: .cluster.endpoint,
        EndpointPublicAccess: .cluster.resourcesVpcConfig.endpointPublicAccess,
        EndpointPrivateAccess: .cluster.resourcesVpcConfig.endpointPrivateAccess,
        PublicAccessCidrs: .cluster.resourcesVpcConfig.publicAccessCidrs,
        VpcId: .cluster.resourcesVpcConfig.vpcId,
        SubnetIds: .cluster.resourcesVpcConfig.subnetIds,
        SecurityGroupIds: .cluster.resourcesVpcConfig.securityGroupIds,
        ClusterSecurityGroupId: .cluster.resourcesVpcConfig.clusterSecurityGroupId,
        ServiceIpv4Cidr: .cluster.kubernetesNetworkConfig.serviceIpv4Cidr,
        IpFamily: .cluster.kubernetesNetworkConfig.ipFamily,
        RoleArn: .cluster.roleArn,
        CreatedAt: .cluster.createdAt
    }'

    # ---------- OIDC Provider ----------
    section "OIDC Identity Provider (${CLUSTER})"
    OIDC_ISSUER=$(echo "$CLUSTER_INFO" | jq -r '.cluster.identity.oidc.issuer // empty')

    if [[ -n "$OIDC_ISSUER" ]]; then
        echo "OIDC Issuer URL: ${OIDC_ISSUER}"
        OIDC_ID=$(echo "$OIDC_ISSUER" | sed 's|https://||' | cut -d/ -f2)
        echo "OIDC Provider ID: ${OIDC_ID}"

        # Check if the OIDC provider is registered in IAM
        echo ""
        echo "Checking IAM OIDC providers..."
        OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --output json 2>/dev/null) || true

        if [[ -n "$OIDC_PROVIDERS" ]]; then
            echo "$OIDC_PROVIDERS" | jq '.'

            # Check if this cluster's OIDC is registered
            OIDC_HOST=$(echo "$OIDC_ISSUER" | sed 's|https://||')
            PARTITION="aws"
            [[ "$REGION" == *"gov"* ]] && PARTITION="aws-us-gov"
            EXPECTED_ARN="arn:${PARTITION}:iam::${ACCOUNT}:oidc-provider/${OIDC_HOST}"

            echo ""
            echo "Expected OIDC Provider ARN: ${EXPECTED_ARN}"

            MATCH=$(echo "$OIDC_PROVIDERS" | jq -r ".OpenIDConnectProviderList[]?.Arn" | grep -F "$OIDC_HOST" || true)
            if [[ -n "$MATCH" ]]; then
                echo "[OK] OIDC provider IS registered in IAM: ${MATCH}"

                # Get provider details
                echo ""
                aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$MATCH" --output json 2>/dev/null | \
                    jq '{Url, ClientIDList, ThumbprintList, CreateDate}' || echo "[Could not get provider details]"
            else
                echo "[MISSING] OIDC provider is NOT registered in IAM"
                echo "  This means IRSA will not work. Need: iam:CreateOpenIDConnectProvider"
            fi
        else
            echo "[DENIED] Cannot list OIDC providers"
        fi

        # Test the OIDC discovery endpoint
        echo ""
        echo "OIDC Discovery Endpoint:"
        DISCOVERY_URL="${OIDC_ISSUER}/.well-known/openid-configuration"
        echo "  URL: ${DISCOVERY_URL}"
        DISCOVERY=$(curl -sfm 10 "$DISCOVERY_URL" 2>/dev/null) || DISCOVERY=""
        if [[ -n "$DISCOVERY" ]]; then
            echo "  [OK] Discovery document retrieved:"
            echo "$DISCOVERY" | jq . 2>/dev/null || echo "$DISCOVERY"
        else
            echo "  [FAIL] Cannot reach OIDC discovery endpoint"
            echo "  This is the root cause of the CAPA controller failure."
        fi
    else
        echo "No OIDC issuer configured for this cluster"
    fi

    # ---------- Node Groups ----------
    section "Managed Node Groups (${CLUSTER})"
    NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --output json 2>/dev/null) || true
    if [[ -n "$NODEGROUPS" ]] && echo "$NODEGROUPS" | jq -e '.nodegroups | length > 0' &>/dev/null; then
        for NG in $(echo "$NODEGROUPS" | jq -r '.nodegroups[]'); do
            echo "  Node Group: ${NG}"
            aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --output json 2>/dev/null | \
                jq '{
                    NodegroupName: .nodegroup.nodegroupName,
                    Status: .nodegroup.status,
                    InstanceTypes: .nodegroup.instanceTypes,
                    AmiType: .nodegroup.amiType,
                    ReleaseVersion: .nodegroup.releaseVersion,
                    DesiredSize: .nodegroup.scalingConfig.desiredSize,
                    MinSize: .nodegroup.scalingConfig.minSize,
                    MaxSize: .nodegroup.scalingConfig.maxSize,
                    NodeRole: .nodegroup.nodeRole,
                    LaunchTemplate: .nodegroup.launchTemplate,
                    Subnets: .nodegroup.subnets
                }' 2>/dev/null | sed 's/^/    /'
            echo ""
        done
    else
        echo "[INFO] No managed node groups (or access denied)"
    fi

    # ---------- Fargate Profiles ----------
    section "Fargate Profiles (${CLUSTER})"
    aws eks list-fargate-profiles --cluster-name "$CLUSTER" --output json 2>/dev/null | \
        jq '.fargateProfileNames[]?' 2>/dev/null || echo "[INFO] No fargate profiles or access denied"

    # ---------- Addons ----------
    section "Installed Addons (${CLUSTER})"
    ADDONS=$(aws eks list-addons --cluster-name "$CLUSTER" --output json 2>/dev/null) || true
    if [[ -n "$ADDONS" ]]; then
        for ADDON in $(echo "$ADDONS" | jq -r '.addons[]? // empty'); do
            aws eks describe-addon --cluster-name "$CLUSTER" --addon-name "$ADDON" --output json 2>/dev/null | \
                jq '{AddonName: .addon.addonName, AddonVersion: .addon.addonVersion, Status: .addon.status, ServiceAccountRoleArn: .addon.serviceAccountRoleArn}' 2>/dev/null
        done
    else
        echo "[INFO] Could not list addons"
    fi

    # ---------- Pod Identity Associations ----------
    section "EKS Pod Identity Associations (${CLUSTER})"
    aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --output json 2>/dev/null | \
        jq '.associations[]?' 2>/dev/null || echo "[INFO] No Pod Identity associations or access denied (requires EKS Pod Identity agent addon)"

    # ---------- Access Entries (EKS Access API) ----------
    section "EKS Access Entries (${CLUSTER})"
    aws eks list-access-entries --cluster-name "$CLUSTER" --output json 2>/dev/null | \
        jq '.accessEntries[]?' 2>/dev/null || echo "[INFO] Access entries unavailable or denied"

done

# ---------- OIDC Providers (all) ----------
section "All IAM OIDC Providers in Account"
aws iam list-open-id-connect-providers --output json 2>/dev/null | \
    jq '.' 2>/dev/null || echo "[DENIED] Cannot list OIDC providers"
