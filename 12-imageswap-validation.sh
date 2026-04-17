#!/usr/bin/env bash
# 12-imageswap-validation.sh — Validate SpectroCloud ImageSwap webhook and ECR mutation chain
#
# Palette VerteX uses phenixblue/imageswap-webhook as a mutating admission webhook
# to transparently rewrite container image references from upstream registries
# (gcr.io, us-docker.pkg.dev, registry.k8s.io, docker.io) to the airgap ECR.
#
# The rewrite preserves the FULL original path under the ECR base, creating
# deeply nested repo paths dynamically. This script validates every link in
# that chain: webhook health, swap configuration, ECR repo inventory, and
# actual mutation of running pods.
#
# Reference: github.com/phenixblue/imageswap-webhook
set -euo pipefail

# shellcheck source=lib.sh
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${_LIB_DIR}/lib.sh" ]] && source "${_LIB_DIR}/lib.sh" || { echo "[ERROR] lib.sh not found — run scripts from their directory"; exit 1; }

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
# ── Credential check — diagnoses STS/credential failures before AWS calls ──
sts_preflight || true  # non-fatal: outputs diagnosis, scripts continue for non-AWS checks

ACCOUNT=$(aws_safe sts get-caller-identity --query Account --output text) || ACCOUNT="unknown"
ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "Region:   ${REGION}"
echo "Account:  ${ACCOUNT}"
echo "ECR:      ${ECR_REGISTRY}"

HAS_KUBECTL=false
if command -v kubectl &>/dev/null; then
    HAS_KUBECTL=true
fi

# ============================================================
# 1. MUTATING WEBHOOK CONFIGURATION
# ============================================================
section "MutatingWebhookConfiguration (ImageSwap)"
echo "ImageSwap registers as a MutatingWebhookConfiguration to intercept pod CREATE."
echo "Without it, pods reference upstream registries that are unreachable in airgap."
echo ""

if $HAS_KUBECTL; then
    # Look for imageswap-related webhook configs
    WEBHOOKS=$(kubectl get mutatingwebhookconfiguration -o json 2>/dev/null) || true

    if [[ -n "$WEBHOOKS" ]]; then
        # Search for imageswap or image-swap in webhook names
        IMAGESWAP_HOOKS=$(echo "$WEBHOOKS" | jq -r '.items[] | select(
            .metadata.name | test("imageswap|image-swap|image.swap"; "i")
        ) | .metadata.name' 2>/dev/null || true)

        if [[ -n "$IMAGESWAP_HOOKS" ]]; then
            for HOOK in $IMAGESWAP_HOOKS; do
                ok "Found MutatingWebhookConfiguration: ${HOOK}"

                # Get webhook details
                echo "$WEBHOOKS" | jq --arg name "$HOOK" '.items[] | select(.metadata.name == $name) | {
                    name: .metadata.name,
                    webhooks: [.webhooks[]? | {
                        name: .name,
                        namespace_selector: .namespaceSelector,
                        failure_policy: .failurePolicy,
                        match_policy: .matchPolicy,
                        rules: .rules,
                        timeout_seconds: .timeoutSeconds,
                        service: .clientConfig.service
                    }]
                }' 2>/dev/null | sed 's/^/       /'
            done
        else
            # Check for other mutation webhooks that might serve this purpose
            ALL_HOOKS=$(echo "$WEBHOOKS" | jq -r '.items[].metadata.name' 2>/dev/null || true)
            warn "No imageswap-named MutatingWebhookConfiguration found"
            echo "  All mutating webhooks present:"
            for H in $ALL_HOOKS; do
                echo "    - $H"
            done
            echo ""
            info "ImageSwap may be named differently in this Palette deployment"
            info "Check for webhooks targeting pod CREATE with image rewrite behavior"
        fi
    else
        fail "Cannot list MutatingWebhookConfigurations"
    fi
else
    info "kubectl not available — skip webhook configuration check"
fi

# ============================================================
# 2. IMAGESWAP POD HEALTH
# ============================================================
section "ImageSwap Pod Health"

if $HAS_KUBECTL; then
    # Search for imageswap pods across namespaces
    IMAGESWAP_PODS=$(kubectl get pods --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(
            .metadata.name | test("imageswap|image-swap"; "i")
        ) | "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)"' 2>/dev/null || true)

    if [[ -n "$IMAGESWAP_PODS" ]]; then
        echo "$IMAGESWAP_PODS" | while read -r line; do
            POD_REF=$(echo "$line" | awk '{print $1}')
            PHASE=$(echo "$line" | awk '{print $2}')
            if [[ "$PHASE" == "Running" ]]; then
                ok "${POD_REF} (${PHASE})"
            else
                fail "${POD_REF} (${PHASE}) — webhook will not intercept mutations"
            fi
        done
    else
        warn "No imageswap pods found — checking palette/hubble namespaces for embedded webhook"
        # Palette may embed imageswap as a sidecar or within its own pods
        for NS in hubble-system palette-system spectro-system imageswap-system kube-system; do
            PODS=$(kubectl get pods -n "$NS" -o name 2>/dev/null | grep -iE "swap|mutate|webhook" || true)
            if [[ -n "$PODS" ]]; then
                echo "  Found in ${NS}:"
                echo "$PODS" | sed 's/^/    /'
            fi
        done
    fi

    # Check webhook TLS certificate
    section "ImageSwap Webhook TLS Certificate"
    echo "The webhook requires valid TLS for the API server to send admission reviews."
    for NS in imageswap-system hubble-system palette-system spectro-system; do
        SECRETS=$(kubectl get secrets -n "$NS" -o json 2>/dev/null | \
            jq -r '.items[] | select(
                .metadata.name | test("imageswap|image-swap|webhook.*tls|tls.*webhook"; "i")
            ) | .metadata.name' 2>/dev/null || true)
        if [[ -n "$SECRETS" ]]; then
            for SECRET in $SECRETS; do
                CERT_DATA=$(kubectl get secret -n "$NS" "$SECRET" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
                if [[ -n "$CERT_DATA" ]]; then
                    EXPIRY=$(echo "$CERT_DATA" | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
                    SUBJECT=$(echo "$CERT_DATA" | base64 -d 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
                    ok "TLS cert in ${NS}/${SECRET}: expires ${EXPIRY}"
                    echo "       Subject: ${SUBJECT}"
                fi
            done
        fi
    done
else
    info "kubectl not available — skip pod health and TLS checks"
fi

# ============================================================
# 3. IMAGESWAP MAP CONFIGURATION
# ============================================================
section "ImageSwap Map Configuration"
echo "The swap map defines how upstream image references are rewritten to ECR paths."
echo "Syntax: source-registry::target-registry (preserves full original path after swap)"
echo ""

if $HAS_KUBECTL; then
    # Look for imageswap configmaps across known namespaces
    SWAP_MAP_FOUND=false
    for NS in imageswap-system hubble-system palette-system spectro-system kube-system; do
        CONFIGMAPS=$(kubectl get configmaps -n "$NS" -o json 2>/dev/null | \
            jq -r '.items[] | select(
                .metadata.name | test("imageswap|image-swap|swap-map|mirror"; "i")
            ) | .metadata.name' 2>/dev/null || true)

        if [[ -n "$CONFIGMAPS" ]]; then
            for CM in $CONFIGMAPS; do
                ok "Found swap map ConfigMap: ${NS}/${CM}"
                SWAP_MAP_FOUND=true
                echo ""
                echo "  Map contents:"
                kubectl get configmap -n "$NS" "$CM" -o json 2>/dev/null | \
                    jq -r '.data | to_entries[] | "    \(.key):\n\(.value | split("\n") | map("      " + .) | join("\n"))"' 2>/dev/null || \
                    kubectl get configmap -n "$NS" "$CM" -o yaml 2>/dev/null | sed 's/^/    /'

                echo ""
                echo "  Expected source registries (Palette standard set):"
                MAP_DATA=$(kubectl get configmap -n "$NS" "$CM" -o json 2>/dev/null | jq -r '.data | to_entries[].value' 2>/dev/null || true)
                for SRC in "us-docker.pkg.dev" "gcr.io" "registry.k8s.io" "docker.io" "quay.io" "ghcr.io"; do
                    printf "    %-30s " "$SRC"
                    if echo "$MAP_DATA" | grep -qF "$SRC"; then
                        echo "[MAPPED]"
                    else
                        echo "[MISSING] — images from this registry will not be rewritten"
                    fi
                done

                # Check noswap_wildcards to prevent infinite loops
                echo ""
                echo "  Loop prevention (noswap_wildcards):"
                if echo "$MAP_DATA" | grep -q "noswap_wildcards"; then
                    NOSWAP=$(echo "$MAP_DATA" | grep "noswap_wildcards" | head -1)
                    echo "    ${NOSWAP}"
                    if echo "$NOSWAP" | grep -qF "$ECR_REGISTRY" || echo "$NOSWAP" | grep -qF "ecr.amazonaws.com"; then
                        ok "ECR endpoint excluded from swapping (no infinite rewrite loop)"
                    else
                        fail "ECR endpoint NOT in noswap_wildcards — risk of infinite rewrite loop"
                    fi
                else
                    warn "No noswap_wildcards found — verify ECR images are not double-rewritten"
                fi
            done
        fi
    done

    if ! $SWAP_MAP_FOUND; then
        warn "No ImageSwap ConfigMap found"
        info "The swap configuration may be embedded in Palette Helm values or the Kubernetes pack"
        echo ""
        echo "  Check these Palette Helm values for imageSwap configuration:"
        echo "    - charts/extras/image-swap/image-swap/values.yaml (mirrorRegistries)"
        echo "    - charts/palette/values.yaml (ociImageRegistry.mirrorRegistries)"
        echo "    - Kubernetes pack in cluster profile (imageSwap.imageChange block)"
    fi
else
    info "kubectl not available — skip map configuration check"
fi

# ============================================================
# 4. ECR REPOSITORY PATTERN ANALYSIS
# ============================================================
section "ECR Repository Pattern Analysis"
echo "ImageSwap dynamically creates ECR repos by embedding the full original image path."
echo "Example: gcr.io/spectro-images-public/capi:v1.5"
echo "  → ECR repo: <base>/spectro-images/gcr.io/spectro-images-public/capi"
echo ""

ALL_REPOS=$(aws ecr describe-repositories --region "$REGION" --output json \
    --query 'repositories[].{name:repositoryName,uri:repositoryUri,created:createdAt}' 2>/dev/null) || true

if [[ -n "$ALL_REPOS" && "$ALL_REPOS" != "null" ]]; then
    TOTAL_REPOS=$(echo "$ALL_REPOS" | jq 'length')
    echo "Total ECR repositories: ${TOTAL_REPOS}"
    echo ""

    # Categorize repos by type
    SPECTRO_IMAGE_REPOS=$(echo "$ALL_REPOS" | jq '[.[] | select(.name | test("spectro-images"))]' 2>/dev/null)
    SPECTRO_PACK_REPOS=$(echo "$ALL_REPOS" | jq '[.[] | select(.name | test("spectro-packs"))]' 2>/dev/null)
    OTHER_REPOS=$(echo "$ALL_REPOS" | jq '[.[] | select(.name | test("spectro-images|spectro-packs") | not)]' 2>/dev/null)

    SI_COUNT=$(echo "$SPECTRO_IMAGE_REPOS" | jq 'length')
    SP_COUNT=$(echo "$SPECTRO_PACK_REPOS" | jq 'length')
    OTHER_COUNT=$(echo "$OTHER_REPOS" | jq 'length')

    echo "  spectro-images/* (container images):  ${SI_COUNT} repos"
    echo "  spectro-packs/*  (pack artifacts):    ${SP_COUNT} repos"
    echo "  other:                                ${OTHER_COUNT} repos"

    # Analyze image repos by source registry (the embedded upstream path)
    if (( SI_COUNT > 0 )); then
        section "Image Repos by Source Registry"
        echo "These show which upstream registries have been mirrored into ECR."
        echo ""

        for SRC in "us-docker.pkg.dev" "gcr.io" "registry.k8s.io" "docker.io" "quay.io" "ghcr.io"; do
            SRC_COUNT=$(echo "$SPECTRO_IMAGE_REPOS" | jq --arg src "$SRC" '[.[] | select(.name | contains($src))] | length')
            printf "  %-30s %d repos\n" "$SRC" "$SRC_COUNT"
        done

        # Show first 10 image repos as sample
        echo ""
        echo "  Sample image repos (first 20):"
        echo "$SPECTRO_IMAGE_REPOS" | jq -r '.[0:20][].name' 2>/dev/null | sed 's/^/    /'

        if (( SI_COUNT > 20 )); then
            echo "    ... and $((SI_COUNT - 20)) more"
        fi
    fi

    # Check pack repos
    if (( SP_COUNT > 0 )); then
        section "Pack Repos"
        echo "$SPECTRO_PACK_REPOS" | jq -r '.[].name' 2>/dev/null | sed 's/^/    /'
    fi

    # ---------- Empty repos (created but no images pushed) ----------
    section "Empty Repositories (created but push may have failed)"
    echo "ECR repos must be pre-created before push. Empty repos indicate the mirror"
    echo "script created the repo but the image copy failed or hasn't run yet."
    echo ""

    EMPTY_COUNT=0
    SAMPLE_CHECKED=0
    MAX_SAMPLE=30  # Check a sample to avoid API throttling

    # Check spectro-images repos for emptiness
    REPO_NAMES=$(echo "$SPECTRO_IMAGE_REPOS" | jq -r '.[].name' 2>/dev/null || true)
    for REPO in $REPO_NAMES; do
        if (( SAMPLE_CHECKED >= MAX_SAMPLE )); then
            echo "  (sampled ${MAX_SAMPLE} of ${SI_COUNT} repos — increase MAX_SAMPLE for full audit)"
            break
        fi
        IMG_COUNT=$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
            --query 'imageDetails | length(@)' --output text 2>/dev/null || echo "?")
        if [[ "$IMG_COUNT" == "0" ]]; then
            warn "Empty: ${REPO}"
            EMPTY_COUNT=$((EMPTY_COUNT+1))
        fi
        SAMPLE_CHECKED=$((SAMPLE_CHECKED+1))
        sleep 0.05  # Light rate-limiting
    done

    # Also check pack repos
    PACK_REPO_NAMES=$(echo "$SPECTRO_PACK_REPOS" | jq -r '.[].name' 2>/dev/null || true)
    for REPO in $PACK_REPO_NAMES; do
        IMG_COUNT=$(aws ecr describe-images --repository-name "$REPO" --region "$REGION" \
            --query 'imageDetails | length(@)' --output text 2>/dev/null || echo "?")
        if [[ "$IMG_COUNT" == "0" ]]; then
            warn "Empty pack repo: ${REPO}"
            EMPTY_COUNT=$((EMPTY_COUNT+1))
        fi
    done

    if (( EMPTY_COUNT == 0 )); then
        ok "No empty repositories found in sample"
    else
        echo ""
        echo "  ${EMPTY_COUNT} empty repos found — verify airgap mirror completed successfully"
    fi

    # ---------- ECR Repository Limit ----------
    section "ECR Repository Limit"
    echo "Default ECR limit: 10,000 repos per region. ImageSwap mirror can create hundreds."
    echo "Current usage: ${TOTAL_REPOS} / 10,000"
    if (( TOTAL_REPOS > 8000 )); then
        warn "Approaching ECR repository limit — request quota increase"
    else
        ok "Well within limits"
    fi

else
    fail "Cannot enumerate ECR repositories"
fi

# ============================================================
# 5. POD IMAGE MUTATION VERIFICATION
# ============================================================
section "Pod Image Mutation Verification"
echo "Verifies that running pods have rewritten image references (pointing to ECR)"
echo "rather than upstream registries (which are unreachable in airgap)."
echo ""

if $HAS_KUBECTL; then
    MUTATION_OK=0
    MUTATION_UPSTREAM=0
    MUTATION_ERRORS=""

    # Check pods in palette-related namespaces
    for NS in hubble-system palette-system spectro-system jet-system; do
        PODS_JSON=$(kubectl get pods -n "$NS" -o json 2>/dev/null) || continue
        POD_COUNT=$(echo "$PODS_JSON" | jq '.items | length')
        if (( POD_COUNT == 0 )); then
            continue
        fi

        echo "  Namespace: ${NS} (${POD_COUNT} pods)"

        # Extract all container images from pods in this namespace
        IMAGES=$(echo "$PODS_JSON" | jq -r '.items[].spec.containers[].image' 2>/dev/null || true)
        INIT_IMAGES=$(echo "$PODS_JSON" | jq -r '.items[].spec.initContainers[]?.image' 2>/dev/null || true)
        ALL_IMAGES=$(echo -e "${IMAGES}\n${INIT_IMAGES}" | sort -u | grep -v '^$')

        for IMG in $ALL_IMAGES; do
            printf "    %-70s " "$(echo "$IMG" | rev | cut -c1-70 | rev)"
            # Check if image points to ECR (mutated) or upstream (not mutated)
            if echo "$IMG" | grep -qE "ecr\.(us-gov-west-1|${REGION})\.amazonaws\.com|public\.ecr\.aws"; then
                echo "[ECR] ✓"
                MUTATION_OK=$((MUTATION_OK+1))
            elif echo "$IMG" | grep -qE "gcr\.io|us-docker\.pkg\.dev|registry\.k8s\.io|docker\.io|quay\.io|ghcr\.io"; then
                echo "[UPSTREAM] ← NOT MUTATED"
                MUTATION_UPSTREAM=$((MUTATION_UPSTREAM+1))
                MUTATION_ERRORS+="    ${NS}: ${IMG}\n"
            else
                echo "[OTHER]"
            fi
        done
        echo ""
    done

    section "Mutation Summary"
    echo "  Images pointing to ECR (mutated):   ${MUTATION_OK}"
    echo "  Images pointing upstream (unmutated): ${MUTATION_UPSTREAM}"

    if (( MUTATION_UPSTREAM > 0 )); then
        fail "${MUTATION_UPSTREAM} images still reference upstream registries"
        echo ""
        echo "  These images will fail to pull in an airgapped environment:"
        echo -e "$MUTATION_ERRORS"
        echo ""
        echo "  Possible causes:"
        echo "    1. ImageSwap webhook is not running or not intercepting this namespace"
        echo "    2. Namespace missing label: k8s.twr.io/imageswap=enabled"
        echo "    3. Swap map is missing a mapping for the source registry"
        echo "    4. Pod was created before ImageSwap was deployed (bootstrap ordering)"
    elif (( MUTATION_OK > 0 )); then
        ok "All checked images point to ECR — mutation working correctly"
    else
        info "No Palette pods found to verify mutation"
    fi

    # ---------- ImagePullBackOff Detection ----------
    section "ImagePullBackOff Detection"
    echo "Pods stuck in ImagePullBackOff often indicate a swap map points to an ECR repo"
    echo "that exists but is empty, or the repo was never created."
    echo ""

    BACKOFF_PODS=$(kubectl get pods --all-namespaces -o json 2>/dev/null | \
        jq -r '.items[] | select(
            .status.containerStatuses[]?.state.waiting.reason == "ImagePullBackOff" or
            .status.containerStatuses[]?.state.waiting.reason == "ErrImagePull" or
            .status.initContainerStatuses[]?.state.waiting.reason == "ImagePullBackOff" or
            .status.initContainerStatuses[]?.state.waiting.reason == "ErrImagePull"
        ) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true)

    if [[ -n "$BACKOFF_PODS" ]]; then
        fail "Pods with ImagePullBackOff/ErrImagePull:"
        for POD in $BACKOFF_PODS; do
            NS=$(echo "$POD" | cut -d/ -f1)
            NAME=$(echo "$POD" | cut -d/ -f2)
            # Get the failing image
            FAILING_IMG=$(kubectl get pod -n "$NS" "$NAME" -o json 2>/dev/null | \
                jq -r '(.status.containerStatuses[]? // .status.initContainerStatuses[]?) |
                    select(.state.waiting.reason == "ImagePullBackOff" or .state.waiting.reason == "ErrImagePull") |
                    .image' 2>/dev/null | head -1)
            echo "    ${POD}: ${FAILING_IMG}"
        done
    else
        ok "No pods in ImagePullBackOff state"
    fi
else
    info "kubectl not available — skip mutation verification"
    echo ""
    echo "  To verify manually from the C1 instance:"
    echo "    kubectl get pods -n hubble-system -o jsonpath='{range .items[*]}{.metadata.name}{\"\\t\"}{.spec.containers[*].image}{\"\\n\"}{end}'"
    echo ""
    echo "  All images should reference ECR, not gcr.io/us-docker.pkg.dev/registry.k8s.io"
fi

# ============================================================
# 6. BOOTSTRAP ORDERING CHECK
# ============================================================
section "Bootstrap Ordering"
echo "Palette bootstraps in this order:"
echo "  1. cert-manager (images MUST be hardcoded ECR paths — no ImageSwap yet)"
echo "  2. ImageSwap webhook deploys"
echo "  3. All subsequent pods get images rewritten by ImageSwap"
echo ""
echo "If cert-manager images reference upstream registries, the bootstrap fails."
echo ""

if $HAS_KUBECTL; then
    CM_NS="cert-manager"
    CM_PODS=$(kubectl get pods -n "$CM_NS" -o json 2>/dev/null) || true
    if [[ -n "$CM_PODS" ]] && echo "$CM_PODS" | jq -e '.items | length > 0' &>/dev/null; then
        echo "  cert-manager pods:"
        CM_IMAGES=$(echo "$CM_PODS" | jq -r '.items[].spec.containers[].image' 2>/dev/null | sort -u)
        for IMG in $CM_IMAGES; do
            printf "    %-70s " "$IMG"
            if echo "$IMG" | grep -qE "ecr\..*\.amazonaws\.com|public\.ecr\.aws"; then
                echo "[ECR — correct for pre-ImageSwap bootstrap]"
            else
                warn "NOT ECR — must be hardcoded to ECR path for airgap bootstrap"
            fi
        done
    else
        info "cert-manager namespace not found or empty"
    fi
else
    info "kubectl not available — skip bootstrap check"
fi

# ============================================================
# 7. PALETTE REGISTRY HELM CONFIGURATION
# ============================================================
section "Palette Registry Configuration (Helm)"
echo "Checking for Palette Helm release values that configure registry endpoints."
echo ""

if $HAS_KUBECTL; then
    # Check for palette/hubble Helm releases
    if command -v helm &>/dev/null; then
        for RELEASE in palette hubble spectro vertex; do
            for NS in hubble-system palette-system spectro-system default; do
                VALUES=$(helm get values "$RELEASE" -n "$NS" -o json 2>/dev/null) || continue
                if [[ -n "$VALUES" && "$VALUES" != "null" ]]; then
                    echo "  Helm release: ${RELEASE} (namespace: ${NS})"
                    echo ""

                    # Extract registry configuration
                    echo "  ociImageRegistry:"
                    echo "$VALUES" | jq '.ociImageRegistry // .config.ociImageRegistry // "not found"' 2>/dev/null | sed 's/^/    /'

                    echo ""
                    echo "  ociPackRegistry / ociPackEcrRegistry:"
                    echo "$VALUES" | jq '{
                        ociPackRegistry: (.ociPackRegistry // .config.ociPackRegistry // null),
                        ociPackEcrRegistry: (.ociPackEcrRegistry // .config.ociPackEcrRegistry // null)
                    } | with_entries(select(.value != null))' 2>/dev/null | sed 's/^/    /'

                    echo ""
                    echo "  mirrorRegistries:"
                    echo "$VALUES" | jq -r '
                        (.ociImageRegistry.mirrorRegistries // .config.ociImageRegistry.mirrorRegistries // .mirrorRegistries // null)
                    ' 2>/dev/null | sed 's/^/    /'

                    echo ""
                    echo "  imageSwapConfig:"
                    echo "$VALUES" | jq '.imageSwapConfig // .config.imageSwapConfig // "not found"' 2>/dev/null | sed 's/^/    /'
                    echo ""
                fi
            done
        done
    else
        info "helm not available — checking ConfigMaps/Secrets for registry config"
        # Fallback: look for registry config in ConfigMaps
        for NS in hubble-system palette-system spectro-system; do
            kubectl get configmaps -n "$NS" -o json 2>/dev/null | \
                jq -r '.items[] | select(.data | to_entries[] | .value | test("spectro-images|spectro-packs|ociImageRegistry|ociPackRegistry"; "i")) | .metadata.name' 2>/dev/null | \
                while read -r CM; do
                    info "Registry config found in ConfigMap: ${NS}/${CM}"
                done
        done
    fi
else
    info "kubectl not available — skip Helm configuration check"
fi

echo ""
echo "ImageSwap validation complete."
echo ""
echo "Key metrics to report to SpectroCloud SE:"
echo "  - Webhook present and healthy: check section 1 and 2"
echo "  - Swap map covers all source registries: check section 3"
echo "  - ECR repos created for mirrored images: check section 4"
echo "  - Running pods use ECR (not upstream): check section 5"
echo "  - No ImagePullBackOff pods: check section 5"
echo "  - cert-manager images hardcoded to ECR: check section 6"
