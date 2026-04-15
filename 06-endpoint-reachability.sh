#!/usr/bin/env bash
# 06-endpoint-reachability.sh — HTTPS connectivity to AWS service endpoints
# Goes beyond DNS: tests actual TLS handshake and HTTP response
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }

_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

echo "Region: ${REGION}"
echo ""

# ---------- Connectivity Check Function ----------
check_endpoint() {
    local label="$1"
    local url="$2"
    local timeout="${3:-10}"

    printf "  %-55s " "$label"

    # Single curl: get HTTP code and timing in one request
    local result
    result=$(curl -so /dev/null -w "%{http_code} %{time_total}" -m "$timeout" "$url" 2>/dev/null) || result="000 timeout"
    HTTP_CODE=$(echo "$result" | awk '{print $1}')
    TOTAL_TIME=$(echo "$result" | awk '{print $2}')

    case "$HTTP_CODE" in
        000)
            echo "[UNREACHABLE] timeout or connection refused"
            ;;
        200|301|302|307|308)
            echo "[OK] HTTP ${HTTP_CODE} (${TOTAL_TIME}s)"
            ;;
        400|401|403)
            # 401/403 means we reached the service but aren't authenticated — that's fine
            echo "[OK] HTTP ${HTTP_CODE} — reachable (auth required) (${TOTAL_TIME}s)"
            ;;
        404)
            echo "[OK] HTTP ${HTTP_CODE} — service reachable (${TOTAL_TIME}s)"
            ;;
        *)
            echo "[WARN] HTTP ${HTTP_CODE} (${TOTAL_TIME}s)"
            ;;
    esac
}

# TLS check
check_tls() {
    local label="$1"
    local host="$2"
    local port="${3:-443}"

    printf "  %-55s " "$label"

    if echo | timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" \
        -brief 2>/dev/null | grep -q "CONNECTED"; then
        CERT_SUBJECT=$(echo | timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" \
            2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
        echo "[OK] TLS handshake succeeded — ${CERT_SUBJECT}"
    else
        echo "[FAIL] TLS handshake failed"
    fi
}

# ---------- CRITICAL: OIDC Endpoint ----------
section "CRITICAL — EKS OIDC Endpoint (port 443)"
check_endpoint "OIDC (HTTPS)" "https://oidc.eks.${REGION}.amazonaws.com"
check_tls      "OIDC (TLS)"   "oidc.eks.${REGION}.amazonaws.com"

# Check cluster-specific OIDC
CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)
if [[ -n "$CLUSTERS" ]]; then
    for CLUSTER in $CLUSTERS; do
        OIDC_ISSUER=$(aws eks describe-cluster --name "$CLUSTER" \
            --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)
        if [[ -n "$OIDC_ISSUER" && "$OIDC_ISSUER" != "None" ]]; then
            check_endpoint "OIDC issuer (${CLUSTER})" "${OIDC_ISSUER}/.well-known/openid-configuration"
        fi
    done
fi

# ---------- STS ----------
section "STS"
check_endpoint "STS (regional)" "https://sts.${REGION}.amazonaws.com/"
check_endpoint "STS (global)"   "https://sts.amazonaws.com/"

# ---------- EKS ----------
section "EKS"
check_endpoint "EKS API" "https://eks.${REGION}.amazonaws.com/"

if [[ -n "$CLUSTERS" ]]; then
    for CLUSTER in $CLUSTERS; do
        ENDPOINT=$(aws eks describe-cluster --name "$CLUSTER" \
            --query 'cluster.endpoint' --output text 2>/dev/null || true)
        if [[ -n "$ENDPOINT" && "$ENDPOINT" != "None" ]]; then
            check_endpoint "EKS API Server (${CLUSTER})" "$ENDPOINT"
            # Extract host for TLS check
            EKS_HOST=$(echo "$ENDPOINT" | sed 's|https://||')
            check_tls "EKS API TLS (${CLUSTER})" "$EKS_HOST"
        fi
    done
fi

# ---------- ECR ----------
section "ECR"
check_endpoint "ECR API" "https://api.ecr.${REGION}.amazonaws.com/"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [[ -n "$ACCOUNT" ]]; then
    check_endpoint "ECR DKR (account)" "https://${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/v2/"
fi

# ---------- S3 ----------
section "S3"
check_endpoint "S3 (regional)" "https://s3.${REGION}.amazonaws.com/"

# ---------- Core Services ----------
section "Core Services"
check_endpoint "EC2"              "https://ec2.${REGION}.amazonaws.com/"
check_endpoint "IAM"              "https://iam.amazonaws.com/"
check_endpoint "IAM (GovCloud)"   "https://iam.${REGION}.amazonaws.com/"
check_endpoint "CloudFormation"   "https://cloudformation.${REGION}.amazonaws.com/"
check_endpoint "ELB"              "https://elasticloadbalancing.${REGION}.amazonaws.com/"
check_endpoint "Autoscaling"      "https://autoscaling.${REGION}.amazonaws.com/"

# ---------- Security & Secrets ----------
section "Security & Secrets"
check_endpoint "KMS"              "https://kms.${REGION}.amazonaws.com/"
check_endpoint "Secrets Manager"  "https://secretsmanager.${REGION}.amazonaws.com/"
check_endpoint "SSM"              "https://ssm.${REGION}.amazonaws.com/"
check_endpoint "Security Hub"     "https://securityhub.${REGION}.amazonaws.com/"

# ---------- Monitoring ----------
section "Monitoring"
check_endpoint "CloudWatch"       "https://monitoring.${REGION}.amazonaws.com/"
check_endpoint "CloudWatch Logs"  "https://logs.${REGION}.amazonaws.com/"

# ---------- External (DoD) ----------
section "External / DoD"
check_endpoint "cDSO Registry"    "https://registry.cdso.army.mil/v2/"

# ---------- GitLab Punch-Through (CI/CD lifeline) ----------
section "GitLab Punch-Through (dedicated link — CI/CD lifeline)"
echo "This is the ONLY external connectivity path. GitLab runners deploy through this link."
echo ""
check_endpoint "LevelUp GitLab (HTTPS)"  "https://code.levelup.cce.af.mil/"
check_tls      "LevelUp GitLab (TLS)"    "code.levelup.cce.af.mil" 443

# Git+SSH on port 22
printf "  %-55s " "LevelUp GitLab (git+ssh :22)"
if echo | timeout 10 bash -c 'cat < /dev/tcp/code.levelup.cce.af.mil/22' &>/dev/null; then
    echo "[OK] Port 22 reachable"
else
    if command -v nc &>/dev/null; then
        if nc -z -w 10 code.levelup.cce.af.mil 22 2>/dev/null; then
            echo "[OK] Port 22 reachable"
        else
            echo "[FAIL] Port 22 unreachable — git+ssh will not work"
        fi
    else
        echo "[FAIL] Port 22 unreachable — git+ssh will not work"
    fi
fi

# GitLab Container Registry (port 5050)
printf "  %-55s " "LevelUp GitLab Registry (:5050)"
if echo | timeout 10 openssl s_client -connect "code.levelup.cce.af.mil:5050" \
    -servername "code.levelup.cce.af.mil" -brief 2>/dev/null | grep -q "CONNECTED"; then
    echo "[OK] Port 5050 reachable (container registry)"
else
    echo "[FAIL] Port 5050 unreachable — GitLab container registry unavailable"
fi

# ---------- Internet-Dependent (expected to fail in airgap) ----------
section "Internet-Dependent (expected to fail in airgap)"
echo "NOTE: This environment has NO internet egress. The following checks target"
echo "internet-hosted SpectroCloud services and WILL fail. This is expected and"
echo "confirms the airgap is working correctly. Palette VerteX airgap deployment"
echo "does not require these endpoints."
echo ""
check_endpoint "SpectroCloud API"    "https://api.spectrocloud.com/"
check_endpoint "SpectroCloud Docs"   "https://docs.spectrocloud.com/"
check_endpoint "GCR (Spectro imgs)"  "https://gcr.io/v2/"

echo ""
echo "Endpoint reachability check complete."
echo "UNREACHABLE results require firewall/VPC endpoint investigation."
