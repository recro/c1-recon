#!/usr/bin/env bash
# 10-spectro-readiness.sh — SpectroCloud Palette/VerteX deployment readiness checks
# Validates prerequisites that a Spectro SE would check before deployment or troubleshooting.
# Reference: docs.spectrocloud.com/clusters/public-cloud/aws/
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }
ok()   { echo "  [OK]   $1"; }
warn() { echo "  [WARN] $1"; }
fail() { echo "  [FAIL] $1"; }
info() { echo "  [INFO] $1"; }

_IMDS_TOKEN=$(curl -sfm 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
PARTITION="aws"
[[ "$REGION" == *"gov"* ]] && PARTITION="aws-us-gov"

echo "Region:    ${REGION}"
echo "Account:   ${ACCOUNT}"
echo "Partition: ${PARTITION}"

# ============================================================
# 1. IAM POLICY ATTACHMENT LIMIT
# ============================================================
section "IAM Policy Attachment Limit (max 10 per role/user)"
echo "Palette requires 4-6 managed policies. AWS hard-limits roles/users to 10."
echo "Exceeding this causes silent deployment failures."
echo ""

# Determine caller identity type
ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null)
ROLE_NAME=""
if [[ "$ARN" == *":assumed-role/"* ]]; then
    ROLE_NAME=$(echo "$ARN" | sed 's|.*:assumed-role/||' | cut -d/ -f1)
elif [[ "$ARN" == *":role/"* ]]; then
    ROLE_NAME=$(basename "$(echo "$ARN" | sed 's|.*:role/||')")
fi

if [[ -n "$ROLE_NAME" ]]; then
    ATTACHED_COUNT=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
        --query 'AttachedPolicies | length(@)' --output text 2>/dev/null || echo "?")
    echo "Role: ${ROLE_NAME}"
    echo "Attached managed policies: ${ATTACHED_COUNT}/10"
    if [[ "$ATTACHED_COUNT" != "?" ]]; then
        REMAINING=$((10 - ATTACHED_COUNT))
        if (( REMAINING < 4 )); then
            fail "Only ${REMAINING} slots remaining — Palette needs 4-6 policies"
        elif (( REMAINING < 6 )); then
            warn "${REMAINING} slots remaining — tight for Palette + EKS controller policies"
        else
            ok "${REMAINING} slots available"
        fi

        echo ""
        echo "Currently attached policies:"
        aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json 2>/dev/null | \
            jq -r '.AttachedPolicies[] | "    \(.PolicyName)"' || true
    fi

    # Check for permissions boundary (common in C1/GovCloud)
    BOUNDARY_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
        --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text 2>/dev/null || echo "None")
    echo ""
    echo "Permissions Boundary: ${BOUNDARY_ARN}"
    if [[ "$BOUNDARY_ARN" != "None" && "$BOUNDARY_ARN" != "" ]]; then
        info "Boundary attached — Palette actions must be allowed by BOTH the identity policy AND the boundary"
    fi
else
    info "Not running as an IAM role — skipping policy count check"
fi

# Check roles in account for policy saturation (limit to first 50 to avoid IAM throttling)
section "Account-Wide Policy Attachment Audit"
echo "Roles approaching the 10-policy limit (sampling up to 50 roles):"
ROLES=$(aws iam list-roles --max-items 50 --query 'Roles[].RoleName' --output text 2>/dev/null || true)
SATURATED=0
if [[ -n "$ROLES" ]]; then
    for R in $ROLES; do
        COUNT=$(aws iam list-attached-role-policies --role-name "$R" \
            --query 'AttachedPolicies | length(@)' --output text 2>/dev/null || continue)
        if (( COUNT >= 8 )); then
            warn "${R}: ${COUNT}/10 policies attached"
            ((SATURATED++))
        fi
        sleep 0.1  # Rate-limit to avoid IAM API throttling
    done
    if (( SATURATED == 0 )); then
        ok "No roles at 8+ policies"
    fi
else
    info "Cannot list roles (iam:ListRoles denied)"
fi

# ============================================================
# 2. PALETTE-REQUIRED IAM ACTIONS PROBE
# ============================================================
section "Palette-Required IAM Actions (empirical)"
echo "Testing specific actions from PaletteControllerPolicy / PaletteDeploymentPolicy"
echo ""

probe_action() {
    local label="$1"
    shift
    printf "  %-60s " "$label"
    if OUTPUT=$("$@" 2>&1); then
        echo "[ALLOWED]"
    else
        if echo "$OUTPUT" | grep -qi "AccessDenied\|UnauthorizedAccess\|not authorized\|forbidden"; then
            echo "[DENIED]"
        elif echo "$OUTPUT" | grep -qi "NoSuchEntity\|NotFoundException\|ResourceNotFound\|does not exist"; then
            echo "[ALLOWED] (resource not found)"
        elif echo "$OUTPUT" | grep -qi "InvalidParameterValue\|ValidationError\|InvalidParameter"; then
            echo "[ALLOWED] (param error — call accepted)"
        else
            echo "[ERROR] $(echo "$OUTPUT" | head -1 | cut -c1-80)"
        fi
    fi
}

# OIDC Provider management (critical for IRSA/CAPA)
probe_action "iam:ListOpenIDConnectProviders"       aws iam list-open-id-connect-providers --output json
probe_action "iam:CreateOpenIDConnectProvider (dry)" aws iam simulate-principal-policy \
    --policy-source-arn "arn:${PARTITION}:iam::${ACCOUNT}:role/${ROLE_NAME:-unknown}" \
    --action-names iam:CreateOpenIDConnectProvider --output json

# EKS operations
probe_action "eks:ListClusters"                     aws eks list-clusters --output json
probe_action "eks:DescribeAddonVersions"            aws eks describe-addon-versions --max-results 1 --output json
probe_action "eks:ListPodIdentityAssociations"      aws eks list-pod-identity-associations --cluster-name placeholder --output json

# EC2 / VPC operations
probe_action "ec2:DescribeVpcs"                     aws ec2 describe-vpcs --output json
probe_action "ec2:DescribeSubnets"                  aws ec2 describe-subnets --max-results 1 --output json
probe_action "ec2:DescribeSecurityGroups"            aws ec2 describe-security-groups --max-results 1 --output json
probe_action "ec2:DescribeLaunchTemplates"          aws ec2 describe-launch-templates --max-results 1 --output json
probe_action "ec2:DescribeImages (self)"            aws ec2 describe-images --owners self --max-results 1 --output json

# ECR
probe_action "ecr:GetAuthorizationToken"            aws ecr get-authorization-token --output json
probe_action "ecr:DescribeRepositories"             aws ecr describe-repositories --max-results 1 --output json

# Secrets Manager (Palette stores cluster secrets here)
probe_action "secretsmanager:ListSecrets"           aws secretsmanager list-secrets --max-results 1 --output json

# CloudFormation (Option 1 deployment)
probe_action "cloudformation:ListStacks"            aws cloudformation list-stacks --output json

# ELB (Palette creates LBs for API server / ingress)
probe_action "elasticloadbalancing:DescribeLoadBalancers" aws elbv2 describe-load-balancers --output json

# Pricing (Palette cost estimation) — not available in GovCloud
if [[ "$PARTITION" != "aws-us-gov" ]]; then
    probe_action "pricing:GetProducts"              aws pricing get-products --service-code AmazonEC2 --max-results 1 --output json
else
    printf "  %-60s %s\n" "pricing:GetProducts" "[SKIP] Not available in GovCloud"
fi

# ============================================================
# 3. EKS CLUSTER READINESS FOR PALETTE
# ============================================================
section "EKS Cluster Readiness for Palette"

CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)
if [[ -z "$CLUSTERS" ]]; then
    info "No EKS clusters found"
else
    for CLUSTER in $CLUSTERS; do
        echo ""
        echo "=== Cluster: ${CLUSTER} ==="

        CLUSTER_INFO=$(aws eks describe-cluster --name "$CLUSTER" --output json 2>/dev/null || true)
        if [[ -z "$CLUSTER_INFO" ]]; then
            fail "Cannot describe cluster"
            continue
        fi

        # --- Version check ---
        K8S_VERSION=$(echo "$CLUSTER_INFO" | jq -r '.cluster.version')
        echo "  Kubernetes Version: ${K8S_VERSION}"
        # Palette 4.8.x supports up to k8s 1.32
        MAJOR=$(echo "$K8S_VERSION" | cut -d. -f1)
        MINOR=$(echo "$K8S_VERSION" | cut -d. -f2)
        if (( MINOR > 32 )); then
            warn "k8s ${K8S_VERSION} may exceed Palette's supported range — verify compatibility"
        else
            ok "k8s ${K8S_VERSION} within supported range"
        fi

        # --- OIDC issuer ---
        OIDC_ISSUER=$(echo "$CLUSTER_INFO" | jq -r '.cluster.identity.oidc.issuer // empty')
        if [[ -n "$OIDC_ISSUER" ]]; then
            ok "OIDC issuer present: ${OIDC_ISSUER}"

            # Check IAM OIDC provider registration
            OIDC_HOST=$(echo "$OIDC_ISSUER" | sed 's|https://||')
            PROVIDERS=$(aws iam list-open-id-connect-providers --output json 2>/dev/null || true)
            if [[ -n "$PROVIDERS" ]]; then
                if echo "$PROVIDERS" | jq -r '.OpenIDConnectProviderList[].Arn' | grep -qF "$OIDC_HOST"; then
                    ok "OIDC provider registered in IAM"
                else
                    fail "OIDC provider NOT registered in IAM — IRSA will not work"
                    echo "       Create with: aws iam create-open-id-connect-provider \\"
                    echo "         --url ${OIDC_ISSUER} --client-id-list sts.amazonaws.com"
                fi
            fi
        else
            fail "No OIDC issuer — IRSA cannot function"
        fi

        # --- Endpoint access ---
        PUB_ACCESS=$(echo "$CLUSTER_INFO" | jq -r '.cluster.resourcesVpcConfig.endpointPublicAccess')
        PRIV_ACCESS=$(echo "$CLUSTER_INFO" | jq -r '.cluster.resourcesVpcConfig.endpointPrivateAccess')
        echo "  Endpoint: public=${PUB_ACCESS}, private=${PRIV_ACCESS}"
        if [[ "$PRIV_ACCESS" == "true" ]]; then
            ok "Private endpoint enabled — Palette management plane can reach API server within VPC"
        fi
        if [[ "$PUB_ACCESS" == "true" ]]; then
            PUB_CIDRS=$(echo "$CLUSTER_INFO" | jq -r '.cluster.resourcesVpcConfig.publicAccessCidrs[]')
            echo "  Public Access CIDRs: ${PUB_CIDRS}"
            if echo "$PUB_CIDRS" | grep -q "0.0.0.0/0"; then
                warn "API server open to 0.0.0.0/0 — restrict in production"
            fi
        fi

        # --- Addons check (EBS CSI, Pod Identity Agent) ---
        echo ""
        echo "  Required Addons:"
        ADDONS=$(aws eks list-addons --cluster-name "$CLUSTER" --query 'addons[]' --output text 2>/dev/null || true)

        # EBS CSI Driver
        if echo "$ADDONS" | grep -q "aws-ebs-csi-driver"; then
            ADDON_INFO=$(aws eks describe-addon --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver --output json 2>/dev/null || true)
            ADDON_STATUS=$(echo "$ADDON_INFO" | jq -r '.addon.status // "unknown"')
            ADDON_SA_ROLE=$(echo "$ADDON_INFO" | jq -r '.addon.serviceAccountRoleArn // "none"')
            ok "aws-ebs-csi-driver installed (status: ${ADDON_STATUS})"
            echo "       Service Account Role: ${ADDON_SA_ROLE}"
            if [[ "$ADDON_SA_ROLE" == "none" ]]; then
                warn "EBS CSI driver has no service account role — needs AmazonEBSCSIDriverPolicy"
            fi
        else
            fail "aws-ebs-csi-driver NOT installed — required for persistent volumes"
        fi

        # EKS Pod Identity Agent
        if echo "$ADDONS" | grep -q "eks-pod-identity-agent"; then
            ok "eks-pod-identity-agent installed"
        else
            warn "eks-pod-identity-agent NOT installed — required for Pod Identity auth"
        fi

        # CoreDNS
        if echo "$ADDONS" | grep -q "coredns"; then
            ok "coredns addon present"
        else
            info "coredns not listed as managed addon (may be self-managed)"
        fi

        # kube-proxy
        if echo "$ADDONS" | grep -q "kube-proxy"; then
            ok "kube-proxy addon present"
        else
            info "kube-proxy not listed as managed addon"
        fi

        # VPC CNI
        if echo "$ADDONS" | grep -q "vpc-cni"; then
            ok "vpc-cni addon present"
        else
            info "vpc-cni not listed as managed addon"
        fi

        echo ""
        echo "  All addons: ${ADDONS:-[none or access denied]}"

        # --- Node group sizing ---
        echo ""
        echo "  Node Group Sizing (minimum: t3.xlarge / 20GB for Palette):"
        NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' --output text 2>/dev/null || true)
        for NG in $NODEGROUPS; do
            NG_INFO=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" --output json 2>/dev/null || true)
            INSTANCE_TYPES=$(echo "$NG_INFO" | jq -r '.nodegroup.instanceTypes[]? // empty')
            DISK_SIZE=$(echo "$NG_INFO" | jq -r '.nodegroup.diskSize // "default"')
            DESIRED=$(echo "$NG_INFO" | jq -r '.nodegroup.scalingConfig.desiredSize // "?"')
            AMI_TYPE=$(echo "$NG_INFO" | jq -r '.nodegroup.amiType // "?"')
            echo "    ${NG}: types=[${INSTANCE_TYPES}] disk=${DISK_SIZE}GB desired=${DESIRED} ami=${AMI_TYPE}"

            # Check minimum sizing
            for IT in $INSTANCE_TYPES; do
                case "$IT" in
                    t3.nano|t3.micro|t3.small|t3.medium|t3.large|t2.*|t3a.nano|t3a.micro|t3a.small|t3a.medium|t3a.large)
                        fail "Instance type ${IT} is below Palette minimum (t3.xlarge)"
                        ;;
                    t3.xlarge|t3.2xlarge|m5.*|m6i.*|c5.*|c6i.*|r5.*|r6i.*)
                        ok "Instance type ${IT} meets minimum"
                        ;;
                    *)
                        info "Instance type ${IT} — verify it meets 4 vCPU / 16 GiB minimum"
                        ;;
                esac
            done

            if [[ "$DISK_SIZE" != "default" && "$DISK_SIZE" -lt 20 ]] 2>/dev/null; then
                fail "Disk size ${DISK_SIZE}GB below 20GB minimum"
            fi
        done

        # --- Pod Identity Associations ---
        echo ""
        echo "  Pod Identity Associations:"
        POD_ID_ASSOC=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --output json 2>/dev/null || true)
        if [[ -n "$POD_ID_ASSOC" ]] && echo "$POD_ID_ASSOC" | jq -e '.associations | length > 0' &>/dev/null; then
            echo "$POD_ID_ASSOC" | jq -r '.associations[] | "    ns=\(.namespace) sa=\(.serviceAccount) role=\(.associationArn)"'
        else
            info "No Pod Identity associations configured"
        fi

    done
fi

# ============================================================
# 4. SUBNET TAGGING (CAPA requirement)
# ============================================================
section "Subnet Tagging for CAPA/Palette Network Discovery"
echo "CAPA requires specific tags on subnets to discover them."
echo "Missing tags = Palette cannot provision nodes in the correct subnets."
echo ""

VPC_IDS=$(aws ec2 describe-vpcs --query 'Vpcs[].VpcId' --output text 2>/dev/null || true)
for VPC in $VPC_IDS; do
    VPC_NAME=$(aws ec2 describe-vpcs --vpc-ids "$VPC" \
        --query 'Vpcs[0].Tags[?Key==`Name`].Value | [0]' --output text 2>/dev/null || echo "untagged")
    echo "VPC: ${VPC} (${VPC_NAME})"

    SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC}" --output json 2>/dev/null || true)
    if [[ -z "$SUBNETS" ]]; then
        info "  Cannot describe subnets"
        continue
    fi

    echo "$SUBNETS" | jq -r '.Subnets[] | .SubnetId as $sid |
        (.Tags // []) as $tags |
        ($tags | map(select(.Key == "Name")) | first // {Value: "untagged"}) as $name |
        {
            SubnetId: $sid,
            Name: $name.Value,
            AZ: .AvailabilityZone,
            Public: .MapPublicIpOnLaunch,
            has_elb_tag: ($tags | any(.Key == "kubernetes.io/role/elb")),
            has_internal_elb_tag: ($tags | any(.Key == "kubernetes.io/role/internal-elb")),
            has_capa_role_tag: ($tags | any(.Key | startswith("sigs.k8s.io/cluster-api-provider-aws/role"))),
            has_cluster_tag: ($tags | any(.Key | startswith("kubernetes.io/cluster/")))
        } |
        "  \(.SubnetId) (\(.Name)) az=\(.AZ) public=\(.Public)\n" +
        "    kubernetes.io/role/elb:           \(if .has_elb_tag then "PRESENT" else "MISSING" end)\n" +
        "    kubernetes.io/role/internal-elb:   \(if .has_internal_elb_tag then "PRESENT" else "MISSING" end)\n" +
        "    sigs.k8s.io/cluster-api-*:        \(if .has_capa_role_tag then "PRESENT" else "MISSING" end)\n" +
        "    kubernetes.io/cluster/*:           \(if .has_cluster_tag then "PRESENT" else "MISSING" end)"
    ' 2>/dev/null || info "  Could not parse subnet tags"
    echo ""
done

# ============================================================
# 5. PORT 6443 REACHABILITY (K8s API)
# ============================================================
section "Port 6443 Reachability (Kubernetes API Server)"
echo "Palette management plane must reach child cluster API servers on port 6443."
echo ""

if [[ -n "$CLUSTERS" ]]; then
    for CLUSTER in $CLUSTERS; do
        ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER" \
            --query 'cluster.endpoint' --output text 2>/dev/null || true)
        if [[ -n "$ENDPOINT" && "$ENDPOINT" != "None" ]]; then
            HOST=$(echo "$ENDPOINT" | sed 's|https://||')
            printf "  %-50s " "${CLUSTER} (${HOST}:443)"
            if echo | timeout 10 openssl s_client -connect "${HOST}:443" -servername "$HOST" \
                -brief 2>/dev/null | grep -q "CONNECTED"; then
                echo "[OK] TLS on 443"
            else
                echo "[FAIL] Cannot reach API server"
            fi
        fi
    done
fi

# Also check raw 6443 if there are known endpoints
echo ""
echo "  Note: EKS uses port 443, not 6443. Self-managed/IaaS clusters use 6443."
echo "  If deploying IaaS child clusters, verify port 6443 is open in security groups."

# ============================================================
# 6. PALETTE POD HEALTH (if kubectl available)
# ============================================================
section "Palette/VerteX Pod Health"

if command -v kubectl &>/dev/null; then
    echo "Checking hubble-system namespace (Palette management plane):"
    echo ""
    kubectl get pods -n hubble-system -o wide 2>/dev/null || info "hubble-system namespace not found"

    echo ""
    echo "Checking palette-system namespace:"
    kubectl get pods -n palette-system -o wide 2>/dev/null || info "palette-system namespace not found"

    echo ""
    echo "Checking palette-identity namespace (Pod Identity):"
    kubectl get pods -n palette-identity -o wide 2>/dev/null || info "palette-identity namespace not found"

    echo ""
    echo "Checking ingress-nginx namespace:"
    kubectl get pods -n ingress-nginx -o wide 2>/dev/null || info "ingress-nginx namespace not found"
    echo ""
    kubectl get svc -n ingress-nginx 2>/dev/null || true

    # Pod Identity ConfigMap check
    section "Pod Identity ConfigMap (palette-global-config)"
    echo "Required for EKS Pod Identity: palette-global-config in kube-system with managementClusterName key"
    kubectl get configmap palette-global-config -n kube-system -o yaml 2>/dev/null || \
        info "palette-global-config not found — required before Pod Identity can be configured"

    # Check Pod Identity env vars on Palette pods (non-intrusive — reads pod spec, no exec)
    section "Pod Identity Environment Verification"
    echo "Checking if Palette pods have Pod Identity credentials injected:"
    for NS in hubble-system palette-identity; do
        PODS=$(kubectl get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        for POD in $PODS; do
            # Pod Identity webhook injects env vars into the pod spec — check without exec
            CREDS_URI=$(kubectl get pod -n "$NS" "$POD" \
                -o jsonpath='{.spec.containers[0].env[?(@.name=="AWS_CONTAINER_CREDENTIALS_FULL_URI")].value}' 2>/dev/null || true)
            if [[ -n "$CREDS_URI" ]]; then
                ok "${NS}/${POD}: AWS_CONTAINER_CREDENTIALS_FULL_URI set"
            else
                info "${NS}/${POD}: No Pod Identity credentials (using static creds or IRSA)"
            fi
            break  # Sample one pod per namespace
        done
    done
else
    info "kubectl not available — skip pod health and Pod Identity checks"
    echo "  Install kubectl or run from a machine with cluster access"
fi

# ============================================================
# 7. REGISTRY TLS/CA CHAIN VALIDATION
# ============================================================
section "Registry TLS Certificate Chain"
echo "Palette requires valid TLS to OCI registries. Missing CA certs = auth failures."
echo ""

ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
for REGISTRY_HOST in "$ECR_REGISTRY" "registry.cdso.army.mil"; do
    printf "  %-50s " "$REGISTRY_HOST"
    CERT_OUTPUT=$(echo | timeout 10 openssl s_client -connect "${REGISTRY_HOST}:443" \
        -servername "$REGISTRY_HOST" -showcerts 2>/dev/null)
    if echo "$CERT_OUTPUT" | grep -q "CONNECTED"; then
        VERIFY=$(echo "$CERT_OUTPUT" | grep "Verify return code" | head -1)
        CHAIN_DEPTH=$(echo "$CERT_OUTPUT" | grep -c "BEGIN CERTIFICATE")
        ISSUER=$(echo "$CERT_OUTPUT" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
        EXPIRY=$(echo "$CERT_OUTPUT" | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
        echo "[OK] chain_depth=${CHAIN_DEPTH} expires=${EXPIRY}"
        echo "       Issuer: ${ISSUER}"
        echo "       ${VERIFY}"
    else
        echo "[FAIL] Cannot establish TLS"
    fi
done

# ============================================================
# 8. TOOLING VERSION CHECK
# ============================================================
section "Required Tooling Versions"
echo "Palette airgap and pack operations require specific tool versions."
echo ""

# oras — MUST be v1.0.0 for Palette pack push
printf "  %-30s " "oras"
if command -v oras &>/dev/null; then
    ORAS_VER=$(oras version 2>/dev/null | head -1)
    echo "${ORAS_VER}"
    if echo "$ORAS_VER" | grep -qE '\b1\.0\.0\b'; then
        ok "oras v1.0.0 — matches Palette requirement"
    else
        warn "oras ${ORAS_VER} — Palette requires exactly v1.0.0 for pack push"
    fi
else
    fail "oras not installed"
fi

# AWS CLI
printf "  %-30s " "aws"
if command -v aws &>/dev/null; then
    AWS_VER=$(aws --version 2>/dev/null | head -1)
    echo "${AWS_VER}"
    if echo "$AWS_VER" | grep -q "aws-cli/2"; then
        ok "AWS CLI v2"
    else
        warn "Palette docs reference AWS CLI v2"
    fi
else
    fail "AWS CLI not installed"
fi

# kubectl
printf "  %-30s " "kubectl"
if command -v kubectl &>/dev/null; then
    KUBECTL_VER=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)
    echo "${KUBECTL_VER}"
else
    warn "kubectl not installed (needed for cluster operations)"
fi

# helm
printf "  %-30s " "helm"
if command -v helm &>/dev/null; then
    helm version --short 2>/dev/null
else
    info "helm not installed (needed for Palette Helm deployment)"
fi

# docker
printf "  %-30s " "docker"
if command -v docker &>/dev/null; then
    docker --version 2>/dev/null
else
    info "docker not installed"
fi

# skopeo
printf "  %-30s " "skopeo"
if command -v skopeo &>/dev/null; then
    skopeo --version 2>/dev/null
else
    info "skopeo not installed"
fi

# jq
printf "  %-30s " "jq"
if command -v jq &>/dev/null; then
    jq --version 2>/dev/null
else
    fail "jq not installed (required by multiple scripts)"
fi

# openssl
printf "  %-30s " "openssl"
if command -v openssl &>/dev/null; then
    openssl version 2>/dev/null
else
    warn "openssl not installed"
fi

# ============================================================
# 9. DISK SPACE (airgap binary = 120GB uncompressed)
# ============================================================
section "Disk Space"
echo "Palette airgap binaries require ~120GB free. Pack operations need additional headroom."
echo ""
df -h / /tmp /var 2>/dev/null | head -10

AVAIL_ROOT=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
if (( AVAIL_ROOT < 120 )); then
    warn "Root filesystem has ${AVAIL_ROOT}GB free — may be insufficient for airgap binary"
else
    ok "Root filesystem has ${AVAIL_ROOT}GB free"
fi

# ============================================================
# 10. SPECTROCLOUD-SPECIFIC ENDPOINT REACHABILITY
# ============================================================
section "SpectroCloud CAPA Required Endpoints"
echo "These endpoints must be reachable for CAPA controller to provision clusters."
echo "Reference: docs.spectrocloud.com/clusters/public-cloud/aws/architecture/"
echo ""
echo "IMPORTANT: This is an airgapped environment with NO internet egress."
echo "ALL of these must be served by VPC interface endpoints (PrivateLink)."
echo "Any UNREACHABLE result means the corresponding VPC endpoint is missing or misconfigured."
echo ""

CAPA_ENDPOINTS=(
    "ec2.${REGION}.amazonaws.com"
    "elasticloadbalancing.${REGION}.amazonaws.com"
    "autoscaling.${REGION}.amazonaws.com"
    "secretsmanager.${REGION}.amazonaws.com"
    "sts.${REGION}.amazonaws.com"
    "iam.${REGION}.amazonaws.com"
    "eks.${REGION}.amazonaws.com"
    "oidc.eks.${REGION}.amazonaws.com"
    "s3.${REGION}.amazonaws.com"
    "api.ecr.${REGION}.amazonaws.com"
    "kms.${REGION}.amazonaws.com"
    "ssm.${REGION}.amazonaws.com"
    "logs.${REGION}.amazonaws.com"
)

for EP in "${CAPA_ENDPOINTS[@]}"; do
    printf "  %-55s " "$EP"
    HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" -m 5 "https://${EP}/" 2>/dev/null) || HTTP_CODE="000"
    case "$HTTP_CODE" in
        000) echo "[UNREACHABLE]" ;;
        *)   echo "[OK] HTTP ${HTTP_CODE}" ;;
    esac
done

# ============================================================
# 11. GITLAB CI/CD PATH (sole external connectivity)
# ============================================================
section "GitLab CI/CD Path (LevelUp punch-through)"
echo "code.levelup.cce.af.mil is the ONLY external connectivity in this airgapped"
echo "environment. GitLab runners deploy through this link for CI/CD operations."
echo ""

# DNS
printf "  %-55s " "DNS: code.levelup.cce.af.mil"
if command -v dig &>/dev/null; then
    GL_IP=$(dig +short +timeout=5 code.levelup.cce.af.mil 2>/dev/null | head -1)
elif command -v nslookup &>/dev/null; then
    GL_IP=$(nslookup code.levelup.cce.af.mil 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
else
    GL_IP=""
fi
if [[ -n "$GL_IP" ]]; then
    ok "Resolves to ${GL_IP}"
else
    fail "Cannot resolve — CI/CD pipeline is broken"
fi

# HTTPS
printf "  %-55s " "HTTPS: code.levelup.cce.af.mil"
GL_HTTP=$(curl -so /dev/null -w "%{http_code}" -m 10 "https://code.levelup.cce.af.mil/" 2>/dev/null) || GL_HTTP="000"
if [[ "$GL_HTTP" != "000" ]]; then
    ok "HTTP ${GL_HTTP}"
else
    fail "Unreachable — CI/CD pipeline is broken"
fi

# GitLab Runner config
echo ""
echo "  GitLab Runner Configuration:"
RUNNER_CONFIGS=(
    "/etc/gitlab-runner/config.toml"
    "$HOME/.gitlab-runner/config.toml"
    "/home/gitlab-runner/.gitlab-runner/config.toml"
)
FOUND_RUNNER=false
for RC in "${RUNNER_CONFIGS[@]}"; do
    if [[ -f "$RC" ]]; then
        ok "Runner config found: ${RC}"
        # Show runner URL and executor (not tokens)
        grep -E '^\s*(url|executor|name)\s*=' "$RC" 2>/dev/null | sed 's/^/       /'
        FOUND_RUNNER=true
    fi
done
if [[ "$FOUND_RUNNER" == "false" ]]; then
    info "No GitLab runner config found on this instance"
    echo "       Checked: ${RUNNER_CONFIGS[*]}"
fi

echo ""
echo "SpectroCloud-specific readiness check complete."
