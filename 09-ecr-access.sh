#!/usr/bin/env bash
# 09-ecr-access.sh — ECR authentication test, repository listing, image pull test
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
# ── Credential check — diagnoses STS/credential failures before AWS calls ──
sts_preflight || true  # non-fatal: outputs diagnosis, scripts continue for non-AWS checks


ACCOUNT=$(aws_safe sts get-caller-identity --query Account --output text) || ACCOUNT="unknown"
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

    # ---------- ImageSwap-Aware Repo Classification ----------
    # Palette's ImageSwap webhook dynamically creates ECR repos by embedding the full
    # original image path under a configurable base prefix. Repos are NOT static names.
    #
    # The base path comes from Palette Helm values: ociImageRegistry.baseContentPath
    # Examples: "palette/spectro-images", "vertex-bootstrap/spectro-images", just "spectro-images"
    #
    # Auto-detect the base path by finding the common prefix before "spectro-images" or "spectro-packs"
    section "ECR Repository Classification (ImageSwap-aware)"
    echo "Palette VerteX mirrors images into ECR preserving the full upstream path."
    echo "The ImageSwap webhook rewrites pod image refs at admission time to point here."
    echo ""

    # Detect the base content path by looking at actual repo names
    DETECTED_BASE=$(echo "$REPOS" | jq -r '[.repositories[].repositoryName | capture("^(?<base>.*?)spectro-(images|packs)") | .base] | unique | first // ""' 2>/dev/null)
    if [[ -n "$DETECTED_BASE" && "$DETECTED_BASE" != "null" ]]; then
        echo "  Detected base content path: '${DETECTED_BASE}'"
        echo "    (from Palette Helm: ociImageRegistry.baseContentPath)"
    else
        DETECTED_BASE=""
        echo "  No base content path detected (repos use 'spectro-images/...' directly)"
    fi
    echo ""

    # Classify using detected base (or just spectro-images/spectro-packs if no base)
    SI_REPOS=$(echo "$REPOS" | jq '[.repositories[] | select(.repositoryName | test("spectro-images"))]')
    SP_REPOS=$(echo "$REPOS" | jq '[.repositories[] | select(.repositoryName | test("spectro-packs"))]')
    OTHER=$(echo "$REPOS" | jq '[.repositories[] | select(.repositoryName | test("spectro-images|spectro-packs") | not)]')

    SI_COUNT=$(echo "$SI_REPOS" | jq 'length')
    SP_COUNT=$(echo "$SP_REPOS" | jq 'length')
    OTHER_COUNT=$(echo "$OTHER" | jq 'length')

    echo "  spectro-images/* (container images, ImageSwap targets): ${SI_COUNT}"
    echo "  spectro-packs/*  (OCI pack artifacts):                  ${SP_COUNT}"
    echo "  other:                                                  ${OTHER_COUNT}"

    # Break down image repos by embedded source registry
    if (( SI_COUNT > 0 )); then
        echo ""
        echo "  Image repos by upstream source registry (embedded in ECR path):"
        echo "  These show which registries the airgap mirror has replicated from."
        for SRC in "us-docker.pkg.dev" "gcr.io" "registry.k8s.io" "docker.io" "quay.io" "ghcr.io"; do
            SRC_N=$(echo "$SI_REPOS" | jq --arg s "$SRC" '[.[] | select(.repositoryName | contains($s))] | length')
            printf "    %-30s %d repos\n" "$SRC" "$SRC_N"
        done

        UNMAPPED=$(echo "$SI_REPOS" | jq '[.[] | select(.repositoryName | test("us-docker\\.pkg\\.dev|gcr\\.io|registry\\.k8s\\.io|docker\\.io|quay\\.io|ghcr\\.io") | not)] | length')
        if (( UNMAPPED > 0 )); then
            echo "    (other/unclassified)          ${UNMAPPED} repos"
        fi
    fi

    # HNCD-specific
    echo ""
    echo "  HNCD-specific repositories:"
    echo "$REPOS" | jq -r '.repositories[] | select(.repositoryName | test("hncd"; "i")) | "    \(.repositoryName)"' 2>/dev/null || \
        echo "    [none found]"

    # Pack repos
    if (( SP_COUNT > 0 )); then
        echo ""
        echo "  Pack repositories:"
        echo "$SP_REPOS" | jq -r '.[].repositoryName' 2>/dev/null | sed 's/^/    /'
    fi

    # Sample of image repos
    if (( SI_COUNT > 0 )); then
        echo ""
        echo "  Sample image repos (first 15 of ${SI_COUNT}):"
        echo "$SI_REPOS" | jq -r '.[0:15][].repositoryName' 2>/dev/null | sed 's/^/    /'
        if (( SI_COUNT > 15 )); then
            echo "    ... and $((SI_COUNT - 15)) more"
        fi
    fi

    # ---------- Empty spectro-images repos (ImageSwap will point pods here) ----------
    section "Empty spectro-images Repos (ImageSwap targets)"
    echo "These repos are what ImageSwap rewrites pod images to pull from."
    echo "Empty = mirror created the repo but image push failed → pods get ImagePullBackOff."
    echo ""
    EMPTY_SI=0
    SI_CHECKED=0
    MAX_CHECK=30
    SI_REPO_NAMES=$(echo "$SI_REPOS" | jq -r '.[].repositoryName' 2>/dev/null || true)
    for REPO in $SI_REPO_NAMES; do
        if (( SI_CHECKED >= MAX_CHECK )); then
            echo "  (checked ${MAX_CHECK} of ${SI_COUNT} — increase sample for full audit)"
            break
        fi
        IMG_COUNT=$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
            --query 'imageDetails | length(@)' --output text 2>/dev/null || echo "?")
        if [[ "$IMG_COUNT" == "0" ]]; then
            echo "  [EMPTY] ${REPO}"
            EMPTY_SI=$((EMPTY_SI + 1))
        fi
        SI_CHECKED=$((SI_CHECKED + 1))
        sleep 0.05
    done
    if (( EMPTY_SI == 0 && SI_CHECKED > 0 )); then
        echo "  [OK] No empty spectro-images repos in sample"
    elif (( EMPTY_SI > 0 )); then
        echo ""
        echo "  ${EMPTY_SI} empty repos — pods targeting these will fail to pull."
        echo "  Re-run the airgap mirror script (crane copy) for the missing images."
    fi

    # Also check pack repos
    echo ""
    echo "  Pack repo image counts:"
    for REPO in $(echo "$SP_REPOS" | jq -r '.[].repositoryName' 2>/dev/null); do
        COUNT=$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
            --query 'imageDetails | length(@)' --output text 2>/dev/null || echo "?")
        printf "    %-50s %s artifacts\n" "$REPO" "$COUNT"
    done

    # ---------- Airgap Manifest Cross-Reference ----------
    section "Airgap Manifest Cross-Reference"
    echo "The airgap bundle contains images.txt and packs.txt listing what should be in ECR."
    echo "Comparing against actual repos detects missing mirrors."
    echo ""
    # Look for manifest files from the airgap bundle
    MANIFEST_FOUND=false
    for DIR in /tmp /opt /home/*/airgap* /home/*/vertex* /root /var/tmp; do
        for F in "${DIR}"/images.txt "${DIR}"/packs.txt; do
            if [[ -f "$F" ]]; then
                MANIFEST_FOUND=true
                LINE_COUNT=$(wc -l < "$F")
                echo "  [FOUND] ${F} (${LINE_COUNT} entries)"
            fi
        done
    done
    if ! $MANIFEST_FOUND; then
        echo "  No images.txt / packs.txt found on this instance."
        echo "  These ship inside the airgap bundle — unpack it to enable cross-reference."
        echo "  Without them, we can only check what EXISTS in ECR, not what SHOULD exist."
    fi

    # ---------- ECR Repo Limit ----------
    section "ECR Repository Limit"
    echo "Default limit: 10,000 repos/region. ImageSwap mirroring can create hundreds."
    echo "Current: ${REPO_COUNT} / 10,000"
    if (( REPO_COUNT > 8000 )); then
        echo "  [WARN] Approaching limit — request quota increase via AWS support"
    else
        echo "  [OK] Well within limits"
    fi
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

# ---------- ECR Token Expiry & Refresh ----------
section "ECR Token Lifecycle"
echo "ECR auth tokens expire every 12 hours. In an airgapped cluster, kubelet must"
echo "refresh tokens automatically or pods will fail to pull after expiry."
echo ""
if [[ -n "$TOKEN_RESULT" ]] && echo "$TOKEN_RESULT" | jq -e '.authorizationData' &>/dev/null; then
    EXPIRY=$(echo "$TOKEN_RESULT" | jq -r '.authorizationData[0].expiresAt // empty')
    if [[ -n "$EXPIRY" ]]; then
        echo "  Current token expires: ${EXPIRY}"
        # Check if ecr-credential-provider is configured for kubelet
        echo ""
        echo "  Credential refresh mechanisms:"
        if [[ -f /etc/kubernetes/credential-provider-config.yaml ]]; then
            echo "    [OK] /etc/kubernetes/credential-provider-config.yaml found (kubelet ECR credential provider)"
        elif [[ -f /var/lib/kubelet/credential-provider-config.yaml ]]; then
            echo "    [OK] /var/lib/kubelet/credential-provider-config.yaml found"
        else
            echo "    [INFO] No kubelet credential-provider-config found"
            echo "          Nodes may rely on instance profile + SDK auto-refresh"
        fi
        # Check for cron-based refresh
        if crontab -l 2>/dev/null | grep -qi "ecr.*login\|get-login-password"; then
            echo "    [FOUND] Cron job refreshing ECR tokens"
        fi
    fi
fi

# ---------- Node ECR Pull Access ----------
section "Node Role ECR Pull Access"
echo "EKS node roles need ecr:BatchGetImage + ecr:GetDownloadUrlForLayer to pull."
echo "Without these, pods will get 'unauthorized' even if the repo has images."
echo ""
if command -v kubectl &>/dev/null; then
    # Get node role from EKS node groups
    CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text --region "$REGION" 2>/dev/null || true)
    for CLUSTER in $CLUSTERS; do
        NG_NAMES=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' \
            --output text --region "$REGION" 2>/dev/null || true)
        for NG in $NG_NAMES; do
            NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
                --query 'nodegroup.nodeRole' --output text --region "$REGION" 2>/dev/null || true)
            if [[ -n "$NODE_ROLE" && "$NODE_ROLE" != "None" ]]; then
                ROLE_NAME=$(basename "$NODE_ROLE")
                printf "  %-40s " "${CLUSTER}/${NG}"
                # Check if role has ECR pull permissions
                ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" \
                    --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null || true)
                if echo "$ATTACHED" | grep -qi "ContainerRegistryReadOnly\|ECR"; then
                    echo "[OK] ${ROLE_NAME} has ECR pull policy"
                else
                    # Check inline policies for ecr actions
                    HAS_ECR=$(aws iam simulate-principal-policy \
                        --policy-source-arn "$NODE_ROLE" \
                        --action-names ecr:BatchGetImage \
                        --query 'EvaluationResults[0].EvalDecision' \
                        --output text 2>/dev/null || echo "unknown")
                    if [[ "$HAS_ECR" == "allowed" ]]; then
                        echo "[OK] ${ROLE_NAME} — ecr:BatchGetImage allowed"
                    else
                        echo "[WARN] ${ROLE_NAME} — ECR pull may be denied (${HAS_ECR})"
                    fi
                fi
            fi
        done
    done
else
    echo "  kubectl not available — checking node roles via EKS API only"
    CLUSTERS=$(aws eks list-clusters --query 'clusters[]' --output text --region "$REGION" 2>/dev/null || true)
    for CLUSTER in $CLUSTERS; do
        NG_NAMES=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' \
            --output text --region "$REGION" 2>/dev/null || true)
        for NG in $NG_NAMES; do
            NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" \
                --query 'nodegroup.nodeRole' --output text --region "$REGION" 2>/dev/null || true)
            if [[ -n "$NODE_ROLE" && "$NODE_ROLE" != "None" ]]; then
                echo "  ${CLUSTER}/${NG}: ${NODE_ROLE}"
            fi
        done
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
