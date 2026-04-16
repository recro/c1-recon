#!/usr/bin/env bash
# 00-run-all.sh — Orchestrator: runs all recon scripts and collects output
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="recon-report-${TIMESTAMP}.txt"

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
    # 11-export-twin.sh runs separately — outputs JSON, not part of text report
)

PASS=0
FAIL=0
SKIP=0

for script in "${SCRIPTS[@]}"; do
    script_path="${SCRIPT_DIR}/${script}"
    if [[ ! -x "$script_path" ]]; then
        echo "[SKIP] ${script} — not found or not executable" | tee -a "$REPORT"
        ((SKIP++))
        continue
    fi

    header "Running: ${script}" | tee -a "$REPORT"

    if "$script_path" 2>&1 | tee -a "$REPORT"; then
        echo "" | tee -a "$REPORT"
        echo "[DONE] ${script} completed successfully" | tee -a "$REPORT"
        ((PASS++))
    else
        echo "" | tee -a "$REPORT"
        echo "[WARN] ${script} exited with errors (may be expected if permissions are restricted)" | tee -a "$REPORT"
        ((FAIL++))
    fi
done

header "Summary" | tee -a "$REPORT"
echo "  Passed: ${PASS}" | tee -a "$REPORT"
echo "  Errors: ${FAIL}" | tee -a "$REPORT"
echo "  Skipped: ${SKIP}" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "Full report: $(pwd)/${REPORT}" | tee -a "$REPORT"
echo "" | tee -a "$REPORT"
echo "To export structured JSON for digital twin provisioning:" | tee -a "$REPORT"
echo "  ./11-export-twin.sh > twin-snapshot-${TIMESTAMP}.json" | tee -a "$REPORT"
