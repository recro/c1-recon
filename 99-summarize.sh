#!/usr/bin/env bash
# 99-summarize.sh — Analyze recon output and produce a prioritized findings report.
#
# Usage: ./99-summarize.sh [script-outputs-dir]
#   script-outputs-dir: directory containing per-script .txt files (default: script-outputs)
#
# Called automatically by 00-run-all.sh at the end of a full recon run.
# Can also be run standalone against a previous run's artifacts:
#   ./99-summarize.sh /path/to/script-outputs

set -uo pipefail

OUTDIR="${1:-script-outputs}"
OUTDIR="${OUTDIR%/}"  # strip trailing slash if present
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
_FINDINGS_FILE=$(mktemp)
trap 'rm -f "$_FINDINGS_FILE"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

# _resolve FILE — returns the actual path, trying FILE, FILE.txt, and FILE.sh.txt
_resolve() {
    local base="${OUTDIR}/${1}"
    if   [[ -f "${base}"     ]]; then echo "${base}"
    elif [[ -f "${base}.txt" ]]; then echo "${base}.txt"
    else echo ""; fi
}

# check FILE PATTERN — returns 0 if PATTERN found (regex). FILE="" searches all files.
check() {
    local file="$1" pattern="$2"
    if [[ -z "$file" ]]; then
        grep -rq "$pattern" "${OUTDIR}/" 2>/dev/null
    else
        local _p; _p=$(_resolve "$file")
        [[ -n "$_p" ]] && grep -q "$pattern" "$_p" 2>/dev/null || return 1
    fi
}

# checkf FILE PATTERN — same but fixed-string (for literal strings like [MISSING])
checkf() {
    local file="$1" pattern="$2"
    if [[ -z "$file" ]]; then
        grep -rqF "$pattern" "${OUTDIR}/" 2>/dev/null
    else
        local _p; _p=$(_resolve "$file")
        [[ -n "$_p" ]] && grep -qF "$pattern" "$_p" 2>/dev/null || return 1
    fi
}

# add_finding SORT_KEY ID PRIORITY TITLE IMPACT LOE OWNER ACTION
# SORT_KEY: 00–99 (lower = higher priority)
# Write as pipe-delimited line to findings file
add_finding() {
    printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$_FINDINGS_FILE"
}

# ── Detection ─────────────────────────────────────────────────────────────────

# ────────── P0: Credential / connectivity blockers ───────────────────────────

if check "" "Error class: network" && check "" "sts:GetCallerIdentity"; then
    add_finding "00" "P0-CRED-001" "P0 — CRITICAL" \
        "STS endpoint unreachable — all AWS API calls fail" \
        "No AWS data can be collected. No Palette install possible. Every API call silently fails." \
        "Low (30 min for admin)" \
        "C1-ADMIN" \
        "Create VPC interface endpoint: com.amazonaws.us-gov-west-1.sts (private DNS enabled). Submit C1 network change ticket."
fi

if check "" "Error class: no_credentials"; then
    add_finding "01" "P0-CRED-002" "P0 — CRITICAL" \
        "No IAM instance profile attached to runner EC2" \
        "AWS CLI finds no credential source. All AWS calls fail." \
        "Low (15 min)" \
        "HNCD-TEAM" \
        "Attach an IAM instance profile to the runner EC2 via EC2 console → Actions → Security → Modify IAM role."
fi

if check "" "Error class: expired_token"; then
    add_finding "02" "P0-CRED-003" "P0 — CRITICAL" \
        "STS token expired — IMDS likely inaccessible" \
        "Instance profile credentials cannot refresh. All AWS calls fail with ExpiredTokenException." \
        "Low (30 min)" \
        "HNCD-TEAM" \
        "Set IMDSv2 hop limit ≥ 1 on the runner EC2: aws ec2 modify-instance-metadata-options --instance-id <ID> --http-put-response-hop-limit 2 --http-endpoint enabled"
fi

if check "" "Error class: invalid_credentials"; then
    add_finding "03" "P0-CRED-004" "P0 — CRITICAL" \
        "Credentials invalid for GovCloud partition" \
        "AWS CLI is using commercial partition credentials against a GovCloud endpoint (or vice versa)." \
        "Low (15 min)" \
        "RECRO" \
        "Ensure AWS_DEFAULT_REGION=us-gov-west-1 is set on the runner. Check that the instance profile belongs to the correct GovCloud account."
fi

if check "" "Error class: clock_skew"; then
    add_finding "04" "P0-CRED-005" "P0 — CRITICAL" \
        "System clock out of sync — all signed requests rejected" \
        "AWS rejects requests where the timestamp differs from server time by more than 5 minutes." \
        "Low (15 min)" \
        "RECRO" \
        "Sync clock on runner: sudo chronyd -q 'pool pool.ntp.org iburst'  OR  sudo timedatectl set-ntp true"
fi

# LevelUp GitLab — CI/CD lifeline
if check "04-network-egress" "[FAIL]" && check "04-network-egress" "code.levelup.cce.af.mil"; then
    _lvup_unreachable=1
elif check "06-endpoint-reachability" "UNREACHABLE" && check "06-endpoint-reachability" "LevelUp"; then
    _lvup_unreachable=1
else
    _lvup_unreachable=0
fi
if [[ $_lvup_unreachable -eq 1 ]]; then
    add_finding "05" "P0-NET-001" "P0 — CRITICAL" \
        "LevelUp GitLab (code.levelup.cce.af.mil) unreachable — CI/CD dead" \
        "GitLab runner cannot poll for jobs. No pipelines will execute. This is the sole external connectivity path." \
        "Medium (1-2 days incl. change ticket)" \
        "C1-ADMIN" \
        "Verify the dedicated punch-through link to code.levelup.cce.af.mil is active. Check firewall rules and routing from this VPC to the link. Submit C1 network ticket if the route is missing."
fi

# ────────── P1: SpectroCloud deployment blockers ─────────────────────────────

# No VPC endpoints at all (superset of individual missing-endpoint findings)
_no_endpoints=0
if checkf "08-vpc-environment" "[WARN] No VPC endpoints found"; then
    _no_endpoints=1
    add_finding "10" "P1-VPC-000" "P1 — HIGH" \
        "No VPC endpoints exist in this VPC" \
        "All AWS service traffic has nowhere to go. Every AWS API call will fail for any workload in this VPC." \
        "High (1-2 days — multiple endpoints)" \
        "C1-ADMIN" \
        "Create VPC interface endpoints for at minimum: sts, ec2, eks, ecr.api, ecr.dkr, s3 (gateway), elasticloadbalancing, logs, kms, secretsmanager, ssm. Submit C1 network change ticket."
fi

# Individual missing critical endpoints — check each service by fixed string match.
# Uses grep -F for exact service name matching (no regex ambiguity).
if [[ $_no_endpoints -eq 0 ]] && [[ -f "${OUTDIR}/08-vpc-environment.txt" ]]; then
    _ep08="${OUTDIR}/08-vpc-environment.txt"
    _p1_endpoint() {
        local svc="$1" sort="$2" id="$3" name="$4" impact="$5" action="$6"
        if grep -qF "${svc}" "$_ep08" 2>/dev/null &&            grep -F "${svc}" "$_ep08" 2>/dev/null | grep -qF "[MISSING]"; then
            add_finding "$sort" "$id" "P1 — HIGH" \
                "VPC endpoint missing: ${name}" \
                "$impact" \
                "Low (30 min per endpoint)" \
                "C1-ADMIN" \
                "$action Submit C1 network change ticket."
        fi
    }
    _p1_endpoint ".sts"     "11" "P1-VPC-001" "STS" \
        "All credential-based API calls fail. No AWS operations possible from any workload." \
        "Create VPC interface endpoint: com.amazonaws.us-gov-west-1.sts (private DNS enabled)."
    _p1_endpoint ".ecr.api" "12" "P1-VPC-002" "ECR API" \
        "Cannot authenticate to ECR or list/pull container images. SpectroCloud cannot pull Palette images." \
        "Create VPC interface endpoint: com.amazonaws.us-gov-west-1.ecr.api (private DNS enabled)."
    _p1_endpoint ".ecr.dkr" "13" "P1-VPC-003" "ECR DKR (Docker registry)" \
        "Container image pulls fail even if ECR API endpoint exists. Separate endpoint required for actual image data." \
        "Create VPC interface endpoint: com.amazonaws.us-gov-west-1.ecr.dkr (private DNS enabled)."
    _p1_endpoint ".eks "    "14" "P1-VPC-004" "EKS" \
        "eks:* API calls fail. Cannot describe clusters, update kubeconfigs, or manage node groups." \
        "Create VPC interface endpoint: com.amazonaws.us-gov-west-1.eks (private DNS enabled)."
    _p1_endpoint ".ec2 "    "15" "P1-VPC-005" "EC2" \
        "ec2:Describe* calls fail. Network enumeration (VPCs, subnets, endpoints, SGs) blocked. Required by EKS node bootstrap and scripts 04, 08." \
        "Create VPC interface endpoint: com.amazonaws.us-gov-west-1.ec2 (private DNS enabled)."
fi

# OIDC DNS
if check "05-dns-resolution" "oidc.eks" && check "05-dns-resolution" "\[FAIL\] No resolution"; then
    add_finding "20" "P1-OIDC-001" "P1 — HIGH" \
        "OIDC endpoint does not resolve (oidc.eks.us-gov-west-1.amazonaws.com)" \
        "EKS Pod Identity, IRSA, and SpectroCloud CAPI controller all depend on resolving this hostname. This is the root cause of the previously reported CAPA controller failure." \
        "Medium (C1 ticket + DNS change, 1-2 days)" \
        "C1-ADMIN" \
        "Add a Route 53 Resolver forwarding rule or split-horizon DNS entry for oidc.eks.us-gov-west-1.amazonaws.com pointing to the AWS-managed OIDC service IP. Submit C1 DNS change ticket referencing the CAPA blocker."
fi

# OIDC not in IAM
if checkf "07-eks-cluster" "[MISSING] OIDC provider is NOT registered in IAM"; then
    add_finding "21" "P1-OIDC-002" "P1 — HIGH" \
        "EKS OIDC provider not registered in IAM" \
        "IRSA (IAM Roles for Service Accounts) and EKS Pod Identity will not work. SpectroCloud Palette requires this for its service account roles." \
        "Low (one CLI command if permitted)" \
        "RECRO (if iam:CreateOpenIDConnectProvider allowed) — else HNCD-TEAM" \
        "Run: eksctl utils associate-iam-oidc-provider --cluster <name> --approve  OR  aws iam create-open-id-connect-provider --url <issuer-url> --client-id-list sts.amazonaws.com  Check 03-iam-capabilities output to confirm iam:CreateOpenIDConnectProvider is allowed."
fi

# ECR auth failure
if checkf "09-ecr-access" "[FAIL] Cannot get ECR authorization token"; then
    add_finding "22" "P1-ECR-001" "P1 — HIGH" \
        "ECR authorization token request failed" \
        "Cannot pull any container images from ECR. SpectroCloud Palette images, Packer CI images — all blocked." \
        "Low (IAM policy update)" \
        "HNCD-TEAM" \
        "Grant ecr:GetAuthorizationToken to the runner role. Also verify the ECR DKR VPC endpoint exists and has private DNS enabled. Check 08-vpc-environment output for endpoint status."
fi

# ────────── P2: Functional gaps ───────────────────────────────────────────────

# Non-critical missing VPC endpoints
if [[ $_no_endpoints -eq 0 ]] && [[ -f "${OUTDIR}/08-vpc-environment.txt" ]]; then
    _p2_endpoints=()
    for _svc_key in "elasticloadbalancing" "\.s3" "\.logs" "\.kms" "secretsmanager" "\.ssm" "autoscaling"; do
        if grep -q "${_svc_key}.*\[MISSING\]" "${OUTDIR}/08-vpc-environment.txt" 2>/dev/null; then
            case "$_svc_key" in
                elasticloadbalancing) _p2_endpoints+=("ELB (elasticloadbalancing)") ;;
                \.s3)                 _p2_endpoints+=("S3 (gateway endpoint)") ;;
                \.logs)               _p2_endpoints+=("CloudWatch Logs") ;;
                \.kms)                _p2_endpoints+=("KMS") ;;
                secretsmanager)       _p2_endpoints+=("Secrets Manager") ;;
                \.ssm)                _p2_endpoints+=("SSM Parameter Store") ;;
                autoscaling)          _p2_endpoints+=("Auto Scaling") ;;
            esac
        fi
    done
    if [[ ${#_p2_endpoints[@]} -gt 0 ]]; then
        _ep_list=$(printf ', %s' "${_p2_endpoints[@]}"); _ep_list="${_ep_list:2}"
        add_finding "30" "P2-VPC-001" "P2 — MEDIUM" \
            "Secondary VPC endpoints missing: ${_ep_list}" \
            "EKS node-level operations (log shipping, secret fetching, scaling events, KMS encryption) will fail without these endpoints. Not a Day 1 blocker but breaks production operations." \
            "Low (30 min per endpoint, can batch)" \
            "C1-ADMIN" \
            "Create VPC interface endpoints for each missing service. S3 should use a gateway endpoint (free, higher performance). Batch the request in a single C1 change ticket."
    fi
fi

# kubectl missing
if check "" "kubectl.*\[not available\]" || checkf "" "kubectl         [not available]"; then
    add_finding "31" "P2-RUNNER-001" "P2 — MEDIUM" \
        "kubectl not installed on the recon runner" \
        "Scripts 07 (EKS cluster), 10 (Palette readiness), and 12 (ImageSwap) skip all Kubernetes-level checks. Only AWS API data is collected — no in-cluster state visible." \
        "Low (30 min)" \
        "RECRO" \
        "Install kubectl on the runner EC2: aws s3 cp s3://hncd-airgap-transfer/tools/kubectl /tmp/kubectl && sudo install -m755 /tmp/kubectl /usr/local/bin/kubectl  Then configure kubeconfig: aws eks update-kubeconfig --name <cluster> --region us-gov-west-1"
fi

# IAM simulate denied
if checkf "02-iam-boundaries" "[Access denied — iam:SimulatePrincipalPolicy"; then
    add_finding "32" "P2-IAM-001" "P2 — MEDIUM" \
        "iam:SimulatePrincipalPolicy denied — policy analysis limited" \
        "Cannot simulate what the role is allowed to do. The permissions boundary shape is unknown. Debugging future IAM failures is slower without this." \
        "Low (add one IAM action to the boundary or attached policy)" \
        "HNCD-TEAM" \
        "Add iam:SimulatePrincipalPolicy to the runner role's policy (not the boundary — boundaries only restrict, they don't grant). This is a read-only diagnostic action with no security impact."
fi

# SpectroCloud permission gaps (from 13-spectro-permissions.sh)
if [[ -f "${OUTDIR}/13-spectro-permissions.txt" ]]; then
    # Check for overall gap
    _perm_denied=$(grep -c '\[DENIED\]' "${OUTDIR}/13-spectro-permissions.txt" 2>/dev/null) || true
    _perm_denied="${_perm_denied:-0}"

    if (( _perm_denied > 0 )); then
        # Extract per-policy gap counts
        _gap_policies=""
        for _pol in "PaletteControllerPolicy" "PaletteControlPlanePolicy" "PaletteNodesPolicy" "PaletteDeploymentPolicy" "PaletteControllersEKSPolicy"; do
            _pol_denied=$(grep -A 1000 "Policy: ${_pol}" "${OUTDIR}/13-spectro-permissions.txt" 2>/dev/null | \
                grep -B 1000 -m1 "^  ─" | grep -c '\[DENIED\]' 2>/dev/null) || true
            if [[ -n "$_pol_denied" ]] && (( _pol_denied > 0 )); then
                _gap_policies="${_gap_policies:+${_gap_policies}, }${_pol} (${_pol_denied})"
            fi
        done

        add_finding "25" "P1-IAM-010" "P1 — HIGH" \
            "SpectroCloud IAM permission gaps: ${_perm_denied} actions denied" \
            "Role is missing ${_perm_denied} actions required by upstream SpectroCloud Palette/VerteX IAM policy documentation. Gaps in: ${_gap_policies:-unknown policies}. Palette controllers will fail to provision or manage clusters until these are granted." \
            "Medium (IAM policy update, may require C1 change process)" \
            "HNCD-TEAM" \
            "Review 13-spectro-permissions output for the full list of denied actions. Compare against docs.spectrocloud.com/clusters/public-cloud/aws/required-iam-policies/ and add missing actions to the role's attached policy. If a permissions boundary blocks the action, it must also be updated (requires C1-ADMIN)."
    fi

    # Untested actions (simulation denied)
    _perm_untested=$(grep -c '\[UNTESTED' "${OUTDIR}/13-spectro-permissions.txt" 2>/dev/null) || true
    _perm_untested="${_perm_untested:-0}"
    if (( _perm_untested > 0 )); then
        add_finding "33" "P2-IAM-002" "P2 — MEDIUM" \
            "SpectroCloud permission comparison incomplete — ${_perm_untested} actions untested" \
            "iam:SimulatePrincipalPolicy is denied, so the permission gap analysis could not test ${_perm_untested} actions. The actual gap may be larger than reported." \
            "Low (grant iam:SimulatePrincipalPolicy)" \
            "HNCD-TEAM" \
            "Grant iam:SimulatePrincipalPolicy to enable full permission comparison. Then re-run 13-spectro-permissions.sh."
    fi
fi

# ────────── P3: Advisory / low impact ────────────────────────────────────────

# No EKS clusters visible
if checkf "07-eks-cluster" "No EKS clusters found (or eks:ListClusters denied)"; then
    add_finding "50" "P3-EKS-001" "P3 — ADVISORY" \
        "EKS clusters not visible to this role (denied or none exist)" \
        "Cannot enumerate cluster config, OIDC state, or node groups from this runner. Limits what the recon can verify." \
        "Low (IAM permission)" \
        "HNCD-TEAM" \
        "Grant eks:ListClusters and eks:DescribeCluster to the runner role. These are read-only and have no security impact."
fi

# dig/nslookup missing
if checkf "05-dns-resolution" "Neither dig nor nslookup found"; then
    add_finding "51" "P3-TOOLS-001" "P3 — ADVISORY" \
        "DNS lookup tools (dig / nslookup) not installed" \
        "05-dns-resolution.sh exited early. No DNS data collected. Cannot verify OIDC endpoint resolution from this host." \
        "Low (5 min)" \
        "RECRO" \
        "Install on runner: sudo dnf install -y bind-utils"
fi

# No data collected at all (all files missing or empty)
_file_count=$(find "$OUTDIR" -name "*.txt" -size +0 2>/dev/null | wc -l)
if [[ $_file_count -eq 0 ]]; then
    add_finding "00" "P0-RUN-001" "P0 — CRITICAL" \
        "No recon data collected — all scripts failed or were skipped" \
        "The script-outputs directory is empty. A fundamental failure (credentials, missing lib.sh, or runner issue) prevented all data collection." \
        "Unknown — investigate manually" \
        "RECRO" \
        "Check the full recon-report-*.txt for error output at the top of each script section. Most likely cause: credentials not working (see P0-CRED-* findings above)."
fi

# ── Report output ─────────────────────────────────────────────────────────────

FINDING_COUNT=$(wc -l < "$_FINDINGS_FILE" | tr -d ' ')

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "  RECON FINDINGS SUMMARY"
echo "  Generated: ${GENERATED_AT}"
echo "  Source:    ${OUTDIR}/"
echo "  Findings:  ${FINDING_COUNT}"
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  Priority  Description"
echo "  ────────  ──────────────────────────────────────────────────────────────"
echo "  P0        Deployment completely blocked — fix before anything else"
echo "  P1        SpectroCloud install will fail — fix before Palette deploy"
echo "  P2        Functional gaps — fix for production readiness"
echo "  P3        Advisory — low immediate impact"
echo ""
echo "  Owner     Meaning"
echo "  ────────  ──────────────────────────────────────────────────────────────"
echo "  C1-ADMIN  Requires Cloud One platform/network team (submit change ticket)"
echo "  HNCD-TEAM Leidos/HNCD team (IAM, EC2 config, cluster access)"
echo "  RECRO     Recro team (runner setup, scripts, CI/CD)"

if [[ $FINDING_COUNT -eq 0 ]]; then
    echo ""
    echo "  ✓  No issues detected. Environment looks ready."
    echo ""
    exit 0
fi

echo ""

# Sort by sort_key and print with priority section headers on change
_LAST_PRI=""
sort -t'|' -k1,1 "$_FINDINGS_FILE" | while IFS='|' read -r _sort _id _pri _title _impact _loe _owner _action; do
    if [[ "$_pri" != "$_LAST_PRI" ]]; then
        echo "────────────────────────────────────────────────────────────────────────────"
        printf "  %s\n" "$_pri"
        echo "────────────────────────────────────────────────────────────────────────────"
        _LAST_PRI="$_pri"
    fi
    echo ""
    printf "  ID:      %s\n" "$_id"
    printf "  Issue:   %s\n" "$_title"
    echo ""
    printf "  Impact:  %s\n" "$_impact" | fold -sw 72 | sed '2,$s/^/           /'
    echo ""
    printf "  LoE:     %s\n" "$_loe"
    printf "  Owner:   %s\n" "$_owner"
    echo ""
    printf "  Action:  %s\n" "$_action" | fold -sw 72 | sed '2,$s/^/           /'
    echo ""
done

echo "════════════════════════════════════════════════════════════════════════════"
echo "  END OF FINDINGS  —  ${FINDING_COUNT} issue(s) detected"
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
