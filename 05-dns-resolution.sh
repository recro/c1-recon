#!/usr/bin/env bash
# 05-dns-resolution.sh — DNS resolution tests for critical AWS service endpoints
# Key diagnostic for the OIDC provider issue (oidc.eks not resolving from cluster)
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }

# Detect region
_IMDS_TOKEN=$(curl -sfm 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

echo "Region: ${REGION}"

# Determine DNS resolver
section "DNS Configuration"
echo "/etc/resolv.conf:"
cat /etc/resolv.conf 2>/dev/null | grep -v '^#' | grep -v '^$' | sed 's/^/  /'

echo ""
echo "systemd-resolved status:"
systemctl is-active systemd-resolved 2>/dev/null || echo "  [not running or not present]"
resolvectl status 2>/dev/null | head -20 | sed 's/^/  /' || true

# Pick resolver tool
if command -v dig &>/dev/null; then
    RESOLVER="dig"
elif command -v nslookup &>/dev/null; then
    RESOLVER="nslookup"
else
    echo ""
    echo "[FAIL] Neither dig nor nslookup found. Install bind-utils: dnf install -y bind-utils"
    exit 1
fi
echo ""
echo "Using resolver: ${RESOLVER}"

# ---------- DNS Probe Function ----------
dns_check() {
    local label="$1"
    local hostname="$2"
    printf "\n  %-55s " "$hostname"

    if [[ "$RESOLVER" == "dig" ]]; then
        RESULT=$(dig +short +timeout=5 "$hostname" 2>/dev/null)
    else
        RESULT=$(nslookup "$hostname" 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}')
    fi

    if [[ -n "$RESULT" && "$RESULT" != *"NXDOMAIN"* && "$RESULT" != *"SERVFAIL"* ]]; then
        echo "[OK] $(echo "$RESULT" | head -1)"
    else
        echo "[FAIL] No resolution"
    fi
}

# ---------- CRITICAL: EKS OIDC Endpoint ----------
section "CRITICAL — EKS OIDC Endpoint"
echo "This is the primary diagnostic for the CAPA controller OIDC resolution failure."
dns_check "EKS OIDC (GovCloud)"  "oidc.eks.${REGION}.amazonaws.com"
dns_check "EKS OIDC (us-east-1)" "oidc.eks.us-east-1.amazonaws.com"

# Also check if there's a cluster-specific OIDC endpoint
CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)
if [[ -n "$CLUSTERS" ]]; then
    for CLUSTER in $CLUSTERS; do
        OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
        if [[ -n "$OIDC_ISSUER" && "$OIDC_ISSUER" != "None" ]]; then
            # Extract hostname from issuer URL
            OIDC_HOST=$(echo "$OIDC_ISSUER" | sed 's|https://||' | cut -d/ -f1)
            dns_check "OIDC issuer (${CLUSTER})" "$OIDC_HOST"
        fi
    done
fi

# ---------- Core AWS Service Endpoints ----------
section "Core AWS Service Endpoints"
dns_check "STS"                    "sts.${REGION}.amazonaws.com"
dns_check "STS (global)"          "sts.amazonaws.com"
dns_check "IAM (global)"          "iam.amazonaws.com"
dns_check "IAM (GovCloud)"       "iam.${REGION}.amazonaws.com"

section "EKS Endpoints"
dns_check "EKS API"               "eks.${REGION}.amazonaws.com"
dns_check "EKS Auth"              "eks-auth.${REGION}.amazonaws.com"

section "ECR Endpoints"
dns_check "ECR API"               "api.ecr.${REGION}.amazonaws.com"
dns_check "ECR DKR"               "dkr.ecr.${REGION}.amazonaws.com"
# Account-specific ECR
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -n "$ACCOUNT" ]]; then
    dns_check "ECR (account)" "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
fi

section "S3 Endpoints"
dns_check "S3 (regional)"        "s3.${REGION}.amazonaws.com"
dns_check "S3 (path-style)"      "s3-${REGION}.amazonaws.com"

section "EC2 & Networking"
dns_check "EC2"                   "ec2.${REGION}.amazonaws.com"
dns_check "ELB"                   "elasticloadbalancing.${REGION}.amazonaws.com"
dns_check "Autoscaling"           "autoscaling.${REGION}.amazonaws.com"

section "Monitoring & Logging"
dns_check "CloudWatch"            "monitoring.${REGION}.amazonaws.com"
dns_check "CloudWatch Logs"       "logs.${REGION}.amazonaws.com"
dns_check "CloudWatch Events"     "events.${REGION}.amazonaws.com"

section "Security & Secrets"
dns_check "KMS"                   "kms.${REGION}.amazonaws.com"
dns_check "Secrets Manager"       "secretsmanager.${REGION}.amazonaws.com"
dns_check "SSM"                   "ssm.${REGION}.amazonaws.com"

section "Other Services"
dns_check "CloudFormation"        "cloudformation.${REGION}.amazonaws.com"
dns_check "Security Hub"          "securityhub.${REGION}.amazonaws.com"

section "External / DoD"
echo "NOTE: code.levelup.cce.af.mil is CRITICAL — it is the ONLY external connectivity"
echo "path in this airgapped environment. If this fails to resolve, CI/CD is dead."
echo ""
dns_check "LevelUp GitLab (CRITICAL)"  "code.levelup.cce.af.mil"

echo ""
echo "NOTE: registry.cdso.army.mil will only resolve if a cDSO VPC endpoint or DNS"
echo "forwarding rule is configured in this environment. Failure is expected otherwise."
dns_check "cDSO Registry"              "registry.cdso.army.mil"

# ---------- CoreDNS Check (if kubectl available) ----------
section "CoreDNS Status (if kubectl available)"
if command -v kubectl &>/dev/null; then
    echo "kubectl found — checking CoreDNS from cluster perspective:"
    echo ""
    kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide 2>/dev/null || \
        echo "  [Could not query CoreDNS pods]"
    echo ""
    echo "CoreDNS ConfigMap:"
    kubectl get configmap coredns -n kube-system -o yaml 2>/dev/null | head -40 || \
        echo "  [Could not fetch CoreDNS configmap]"
else
    echo "kubectl not found — skip cluster DNS checks"
fi
