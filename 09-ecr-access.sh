#!/usr/bin/env bash
# 09-ecr-access.sh — ECR authentication test, repository listing, image pull test
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }

_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "Region:   ${REGION}"
echo "Account:  ${ACCOUNT}"
echo "Registry: ${ECR_REGISTRY}"

# ---------- Authorization Token ----------
section "ECR Authorization Token"
TOKEN_RESULT=$(aws ecr get-authorization-token --region "$REGION" --output json 2>&1) || true

if echo "$TOKEN_RESULT" | jq -e '.authorizationData' &>/dev/null; then
    echo "[OK] Authorization token retrieved"
    echo "$TOKEN_RESULT" | jq '.authorizationData[] | {
        ProxyEndpoint: .proxyEndpoint,
        ExpiresAt: .expiresAt
    }'

    # Decode token to verify format
    B64_TOKEN=$(echo "$TOKEN_RESULT" | jq -r '.authorizationData[0].authorizationToken')
    DECODED=$(echo "$B64_TOKEN" | base64 -d 2>/dev/null || echo "")
    if [[ "$DECODED" == AWS:* ]]; then
        echo "Token format: [OK] AWS:<password> (standard ECR format)"
    else
        echo "Token format: [WARN] unexpected format"
    fi
else
    echo "[FAIL] Cannot get ECR authorization token"
    echo "$TOKEN_RESULT"
fi

# ---------- Registry Reachability ----------
section "ECR Registry Reachability"
echo "In this airgapped environment, ECR access requires THREE VPC endpoints:"
echo "  - com.amazonaws.${REGION}.ecr.api  (ECR API calls)"
echo "  - com.amazonaws.${REGION}.ecr.dkr  (Docker registry protocol)"
echo "  - com.amazonaws.${REGION}.s3       (image layer storage)"
echo "Missing any of these = ECR operations will fail."
echo ""
printf "  %-55s " "HTTPS /v2/ endpoint"
HTTP_CODE=$(curl -so /dev/null -w "%{http_code}" -m 10 "https://${ECR_REGISTRY}/v2/" 2>/dev/null) || HTTP_CODE="000"
case "$HTTP_CODE" in
    000) echo "[UNREACHABLE] — verify ecr.dkr VPC endpoint exists and SG allows 443" ;;
    401) echo "[OK] HTTP 401 — registry reachable (auth required)" ;;
    200) echo "[OK] HTTP 200" ;;
    *)   echo "[INFO] HTTP ${HTTP_CODE}" ;;
esac

# ---------- Registry Policy ----------
section "ECR Registry Policy"
aws ecr get-registry-policy --region "$REGION" --output json 2>/dev/null | \
    jq '.' || echo "[INFO] No registry-level policy set (or access denied)"

# ---------- Repository Listing ----------
section "ECR Repositories"
REPOS=$(aws ecr describe-repositories --region "$REGION" --output json 2>/dev/null) || true

if [[ -n "$REPOS" ]] && echo "$REPOS" | jq -e '.repositories | length > 0' &>/dev/null; then
    REPO_COUNT=$(echo "$REPOS" | jq '.repositories | length')
    echo "Total repositories: ${REPO_COUNT}"
    echo ""

    # Show all repos with key metadata
    echo "$REPOS" | jq -r '.repositories[] | "  \(.repositoryName)\t\(.imageTagMutability)\t\(.imageScanningConfiguration.scanOnPush)"' | \
        sort | column -t -s$'\t'

    # Highlight SpectroCloud-related repos
    echo ""
    echo "SpectroCloud-related repositories:"
    echo "$REPOS" | jq -r '.repositories[] | select(.repositoryName | test("spectro|vertex|palette"; "i")) | "  \(.repositoryName)"' || \
        echo "  [none found]"

    echo ""
    echo "HNCD-related repositories:"
    echo "$REPOS" | jq -r '.repositories[] | select(.repositoryName | test("hncd"; "i")) | "  \(.repositoryName)"' || \
        echo "  [none found]"

    # Image count for first few repos
    section "Image Counts (sample)"
    SAMPLE_REPOS=$(echo "$REPOS" | jq -r '.repositories[0:5][].repositoryName')
    for REPO in $SAMPLE_REPOS; do
        COUNT=$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
            --query 'imageDetails | length(@)' --output text 2>/dev/null || echo "?")
        printf "  %-50s %s images\n" "$REPO" "$COUNT"
    done
else
    echo "[INFO] No repositories found (or ecr:DescribeRepositories denied)"
fi

# ---------- Lifecycle Policies ----------
section "ECR Lifecycle Policies (sample)"
if [[ -n "$REPOS" ]]; then
    SAMPLE_REPOS=$(echo "$REPOS" | jq -r '.repositories[0:3][].repositoryName')
    for REPO in $SAMPLE_REPOS; do
        echo "  ${REPO}:"
        aws ecr get-lifecycle-policy --repository-name "$REPO" --region "$REGION" --output json 2>/dev/null | \
            jq '.lifecyclePolicyText | fromjson' 2>/dev/null | sed 's/^/    /' || echo "    [no lifecycle policy]"
    done
fi

# ---------- Docker / Container Runtime ----------
section "Container Runtime Status"
echo "Docker:"
if command -v docker &>/dev/null; then
    docker version --format '  Client: {{.Client.Version}}' 2>/dev/null || echo "  [client found but cannot query]"
    docker version --format '  Server: {{.Server.Version}}' 2>/dev/null || echo "  [daemon not running or no permission]"
    docker info --format '  Storage Driver: {{.Driver}}' 2>/dev/null || true
else
    echo "  [not installed]"
fi

echo ""
echo "Podman:"
if command -v podman &>/dev/null; then
    podman version 2>/dev/null | head -5 | sed 's/^/  /'
else
    echo "  [not installed]"
fi

echo ""
echo "skopeo:"
if command -v skopeo &>/dev/null; then
    skopeo --version 2>/dev/null | sed 's/^/  /'
else
    echo "  [not installed]"
fi

echo ""
echo "oras:"
if command -v oras &>/dev/null; then
    oras version 2>/dev/null | sed 's/^/  /'
else
    echo "  [not installed]"
fi

# ---------- Container Policy ----------
section "Container Signature Policy"
if [[ -f /etc/containers/policy.json ]]; then
    echo "[FOUND] /etc/containers/policy.json:"
    jq . /etc/containers/policy.json 2>/dev/null | sed 's/^/  /' || cat /etc/containers/policy.json | sed 's/^/  /'
else
    echo "[NOT FOUND] /etc/containers/policy.json"
    echo "  skopeo operations may fail without this file"
fi

if [[ -f /etc/containers/registries.conf ]]; then
    echo ""
    echo "[FOUND] /etc/containers/registries.conf:"
    cat /etc/containers/registries.conf 2>/dev/null | head -30 | sed 's/^/  /'
fi
