#!/usr/bin/env bash
# lib.sh — Shared utilities for c1-recon scripts.
# Source this file from any recon script:
#   _LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#   [[ -f "$_LIB" ]] && source "$_LIB" || { echo "[ERROR] lib.sh not found"; exit 1; }

# ── Error classification ──────────────────────────────────────────────────────
# Sets global _AWS_ERR_CLASS to one of:
#   denied | expired_token | invalid_credentials | no_credentials |
#   network | clock_skew | not_found | unknown
classify_aws_error() {
    local err="$1"
    _AWS_ERR_CLASS="unknown"
    if   grep -qi "AccessDenied\|is not authorized\|UnauthorizedAccess\|forbidden"      <<< "$err"; then _AWS_ERR_CLASS="denied"
    elif grep -qi "ExpiredToken\|TokenRefreshRequired\|ExpiredTokenException"            <<< "$err"; then _AWS_ERR_CLASS="expired_token"
    elif grep -qi "InvalidClientTokenId\|InvalidUserToken\|UnrecognizedClientException" <<< "$err"; then _AWS_ERR_CLASS="invalid_credentials"
    elif grep -qi "Unable to locate credentials\|NoCredentialProviders\|No credentials" <<< "$err"; then _AWS_ERR_CLASS="no_credentials"
    elif grep -qi "Could not connect\|Connection refused\|ConnectTimeout\|ReadTimeout\|Endpoint URL cannot be reached\|timed out\|socket" <<< "$err"; then _AWS_ERR_CLASS="network"
    elif grep -qi "NoSuchEntity\|NotFoundException\|ResourceNotFound\|does not exist"   <<< "$err"; then _AWS_ERR_CLASS="not_found"
    elif grep -qi "RequestExpired\|Request has expired"                                 <<< "$err"; then _AWS_ERR_CLASS="clock_skew"
    fi
}

# Print a remediation hint for a given error class and optional service name
aws_err_hint() {
    local class="${1:-unknown}"
    local svc="${2:-AWS}"
    case "$class" in
        no_credentials)
            echo "  → No credentials found. Verify this EC2 has an IAM instance profile attached."
            echo "    IMDS check:  curl -sfm 2 http://169.254.169.254/latest/meta-data/iam/info"
            echo "    IMDS token:  curl -sfm 2 -X PUT http://169.254.169.254/latest/api/token \\"
            echo "                   -H 'X-aws-ec2-metadata-token-ttl-seconds: 60'"
            ;;
        expired_token)
            echo "  → STS token expired. IMDS may be unreachable (check IMDSv2 hop limit ≥ 1)."
            echo "    IMDS check:  curl -sfm 2 http://169.254.169.254/latest/meta-data/instance-id"
            echo "    If blank/timeout: the hop limit on this instance is 0 — needs to be ≥ 1."
            ;;
        invalid_credentials)
            echo "  → Credentials are invalid for this partition."
            echo "    GovCloud requires: AWS_DEFAULT_REGION=us-gov-west-1"
            echo "    Check region:  echo \${AWS_DEFAULT_REGION:-not set}"
            ;;
        network)
            echo "  → Cannot reach the ${svc} endpoint. In C1D, all AWS service calls require"
            echo "    a VPC interface endpoint. If no STS endpoint exists, all API calls fail."
            echo "    Check STS endpoint: aws ec2 describe-vpc-endpoints \\"
            echo "      --filters 'Name=service-name,Values=com.amazonaws.us-gov-west-1.sts'"
            echo "    If missing, request endpoint creation from the network/platform team."
            ;;
        clock_skew)
            echo "  → System clock is >5 minutes out of sync with AWS."
            echo "    Fix:  sudo chronyd -q 'pool pool.ntp.org iburst'"
            echo "    Or:   sudo timedatectl set-ntp true"
            ;;
        denied)
            echo "  → Permissions boundary or IAM policy denies this action."
            echo "    See 02-iam-boundaries.sh and 03-iam-capabilities.sh for boundary details."
            ;;
        not_found)
            echo "  → Resource does not exist (not a permissions issue)."
            ;;
        *)
            echo "  → Unclassified error — review the raw message above."
            ;;
    esac
}

# ── STS pre-flight check ──────────────────────────────────────────────────────
# Call near the top of any script that makes AWS API calls.
# On failure, prints the raw error, classifies it, shows remediation hints,
# and exits 1.
sts_preflight() {
    local _tmpf _out _err _rc
    _tmpf=$(mktemp)
    _out=$(aws sts get-caller-identity --output json 2>"$_tmpf")
    _rc=$?
    _err=$(cat "$_tmpf"); rm -f "$_tmpf"

    if [[ $_rc -eq 0 ]]; then
        echo "[OK] Credentials confirmed:"
        echo "$_out" | jq -r '"       Account: \(.Account)\n       ARN:     \(.Arn)"' 2>/dev/null \
          || echo "       $( echo "$_out" | tr -d '\n')"
        return 0
    fi

    classify_aws_error "$_err"
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  [FAIL] sts:GetCallerIdentity — credentials not working      ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "  Error class: ${_AWS_ERR_CLASS}"
    echo "  Raw error:   ${_err}"
    echo ""
    aws_err_hint "$_AWS_ERR_CLASS" "STS"
    echo ""
    echo "  All AWS API calls in this script will fail until credentials"
    echo "  are working. Continuing anyway to collect non-AWS diagnostics."
    echo ""
    return 1
}

# ── Safe AWS call wrapper ─────────────────────────────────────────────────────
# Runs an aws CLI command, captures stderr, classifies failures, and prints
# a useful diagnostic to stderr on failure. Returns the JSON output on success
# or an empty string on failure (so callers can use: OUT=$(aws_safe ...) || fallback).
#
# Usage:
#   aws_safe <service> <subcommand> [args...]
#   OUT=$(aws_safe ec2 describe-vpcs) || OUT="[]"
aws_safe() {
    local _svc="$1"; shift
    local _tmpf _out _err _rc
    _tmpf=$(mktemp)

    _out=$(aws "$_svc" "$@" 2>"$_tmpf")
    _rc=$?
    _err=$(cat "$_tmpf"); rm -f "$_tmpf"

    if [[ $_rc -eq 0 ]]; then
        echo "$_out"
        return 0
    fi

    classify_aws_error "$_err"
    {
        case "$_AWS_ERR_CLASS" in
            denied)
                echo "[DENIED] aws ${_svc} $* — action blocked by policy or boundary"
                ;;
            not_found)
                echo "[NOT FOUND] aws ${_svc} $*"
                ;;
            network)
                echo "[NETWORK ERROR] aws ${_svc} $* — cannot reach endpoint"
                echo "  ${_err}"
                aws_err_hint "network" "$_svc"
                ;;
            no_credentials|expired_token|invalid_credentials)
                echo "[CREDENTIAL ERROR] aws ${_svc} $* — class: ${_AWS_ERR_CLASS}"
                echo "  ${_err}"
                aws_err_hint "$_AWS_ERR_CLASS" "$_svc"
                ;;
            clock_skew)
                echo "[CLOCK SKEW] aws ${_svc} $*"
                echo "  ${_err}"
                aws_err_hint "clock_skew"
                ;;
            *)
                echo "[ERROR] aws ${_svc} $* (class: ${_AWS_ERR_CLASS})"
                echo "  ${_err}"
                ;;
        esac
    } >&2

    return 1
}
