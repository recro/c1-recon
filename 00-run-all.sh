#!/usr/bin/env bash
# 00-run-all.sh — Orchestrator: runs all recon scripts and collects output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="recon-report-${TIMESTAMP}.txt"
OUTDIR="script-outputs"
mkdir -p "$OUTDIR"

header() {
    echo ""
    echo "================================================================"
    echo "  $1"
    echo "  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "================================================================"
    echo ""
}

header "CloudOne GovCloud Recon — ${TIMESTAMP}" | tee "$REPORT"
echo "Environment: Airgapped GovCloud (us-gov-west-1)" | tee -a "$REPORT"
echo "  - No internet egress" | tee -a "$REPORT"
echo "  - AWS services via VPC endpoints only" | tee -a "$REPORT"
echo "  - Dedicated punch-through link to LevelUp GitLab (code.levelup.cce.af.mil)" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"

# ── Optional role assumption ─────────────────────────────────────────────────
# Set AWS_ROLE_ARN (env var or GitLab CI variable) to assume a specific IAM
# role before running the diagnostic scripts. If not set, the runner's default
# credentials (instance profile or env vars) are used.
if [[ -n "${AWS_ROLE_ARN:-}" ]]; then
    echo "AWS_ROLE_ARN set — assuming role before running scripts" | tee -a "$REPORT"
    # Note: source must NOT be in a pipeline (subshell). Capture output via temp file
    # so exports propagate back to this shell and all child scripts inherit them.
    _ASSUME_LOG=$(mktemp)
    # shellcheck source=assume-role.sh
    source "${SCRIPT_DIR}/assume-role.sh" > "$_ASSUME_LOG" 2>&1
    cat "$_ASSUME_LOG" | tee -a "$REPORT"
    rm -f "$_ASSUME_LOG"
fi


SCRIPTS=(
    "01-identity.sh"
    "02-iam-boundaries.sh"
    "03-iam-capabilities.sh"
    "04-network-egress.sh"
    "05-dns-resolution.sh"
    "06-endpoint-reachability.sh"
    "07-eks-cluster.sh"
    "08-vpc-environment.sh"
    "09-ecr-access.sh"
    "10-spectro-readiness.sh"
    "12-imageswap-validation.sh"
    "13-spectro-permissions.sh"
    # 11-export-twin.sh runs separately — outputs JSON, not part of text report
)

PASS=0
FAIL=0
SKIP=0

for script in "${SCRIPTS[@]}"; do
    script_path="${SCRIPT_DIR}/${script}"
    if [[ ! -x "$script_path" ]]; then
        echo "[SKIP] ${script} — not found or not executable" | tee -a "$REPORT"
        SKIP=$((SKIP+1))
        continue
    fi

    header "Running: ${script}" | tee -a "$REPORT"

    BASENAME=$(echo "$script" | sed 's/\.sh$//')
    if "$script_path" 2>&1 | tee "${OUTDIR}/${BASENAME}.txt" | tee -a "$REPORT"; then
        echo "" | tee -a "$REPORT"
        echo "[DONE] ${script} completed successfully" | tee -a "$REPORT"
        PASS=$((PASS+1))
    else
        echo "" | tee -a "$REPORT"
        echo "[WARN] ${script} exited with errors (may be expected if permissions are restricted)" | tee -a "$REPORT"
        FAIL=$((FAIL+1))
    fi
done

header "Summary" | tee -a "$REPORT"
echo "  Passed: ${PASS}" | tee -a "$REPORT"
echo "  Errors: ${FAIL}" | tee -a "$REPORT"
echo "  Skipped: ${SKIP}" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "Full report: $(pwd)/${REPORT}" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
# ── Findings summary ────────────────────────────────────────────────────────
if [[ -x "${SCRIPT_DIR}/99-summarize.sh" ]]; then
    "${SCRIPT_DIR}/99-summarize.sh" "$OUTDIR" 2>&1 | tee -a "$REPORT"
fi

echo "To export structured JSON for digital twin provisioning:" | tee -a "$REPORT"
echo "  ./11-export-twin.sh > twin-snapshot-${TIMESTAMP}.json" | tee -a "$REPORT"
