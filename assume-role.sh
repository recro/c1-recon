#!/usr/bin/env bash
# assume-role.sh — Assume an IAM role and export credentials into the calling shell.
#
# MUST be sourced, not executed directly:
#   source ./assume-role.sh <role-arn> [session-name] [duration-seconds]
#
# Or set AWS_ROLE_ARN in the environment and source with no arguments:
#   export AWS_ROLE_ARN=arn:aws-us-gov:iam::123456789012:role/ReconRole
#   source ./assume-role.sh
#
# After sourcing, AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
# are exported into the calling shell. All subsequent aws cli calls (including
# child scripts invoked from that shell) will use these credentials.
#
# Optional env vars:
#   AWS_ROLE_ARN           — role to assume
#   AWS_ROLE_SESSION_NAME  — session label (default: c1-recon-<hostname>-<epoch>)
#   AWS_ROLE_DURATION      — seconds (default: 3600, max depends on role max session)

# ── Guard: must be sourced ───────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: assume-role.sh must be sourced, not executed directly." >&2
    echo "Usage: source ./assume-role.sh <role-arn>" >&2
    exit 1
fi

# ── Resolve arguments ─────────────────────────────────────────────────────────
_ROLE_ARN="${1:-${AWS_ROLE_ARN:-}}"
_SESSION_NAME="${2:-${AWS_ROLE_SESSION_NAME:-c1-recon-$(hostname -s)-$(date +%s)}}"
_DURATION="${3:-${AWS_ROLE_DURATION:-3600}}"

if [[ -z "$_ROLE_ARN" ]]; then
    echo "[ERROR] assume-role.sh: no role ARN supplied." >&2
    echo "        Pass as first argument or set AWS_ROLE_ARN." >&2
    return 1
fi

echo "[INFO]  Assuming role ..."
echo "[INFO]  ARN:     ${_ROLE_ARN}"
echo "[INFO]  Session: ${_SESSION_NAME}"
echo "[INFO]  Duration: ${_DURATION}s"

# ── Assume the role ───────────────────────────────────────────────────────────
_ASSUME_OUT=$(aws sts assume-role \
    --role-arn         "$_ROLE_ARN" \
    --role-session-name "$_SESSION_NAME" \
    --duration-seconds  "$_DURATION" \
    --output json 2>&1)

if ! echo "$_ASSUME_OUT" | jq -e '.Credentials' > /dev/null 2>&1; then
    echo "[FAIL] sts:AssumeRole failed" >&2
    echo "       Raw error: ${_ASSUME_OUT}" >&2
    echo "" >&2
    # Classify the error using lib.sh if available, otherwise inline
    if declare -f classify_aws_error > /dev/null 2>&1; then
        classify_aws_error "$_ASSUME_OUT"
        case "${_AWS_ERR_CLASS:-unknown}" in
            denied)
                echo "[DIAGNOSIS] sts:AssumeRole denied by policy." >&2
                echo "  - Verify the trust policy on '${_ROLE_ARN}' allows this principal to assume it." >&2
                echo "  - Verify the caller's permission policy allows sts:AssumeRole on this role ARN." >&2
                echo "  - Check for a permissions boundary that blocks sts:AssumeRole." >&2
                ;;
            network)
                echo "[DIAGNOSIS] Cannot reach the STS endpoint." >&2
                echo "  - In C1D, STS requires VPC endpoint: com.amazonaws.us-gov-west-1.sts" >&2
                echo "  - Check: aws ec2 describe-vpc-endpoints --filters 'Name=service-name,Values=*sts*'" >&2
                ;;
            no_credentials|expired_token|invalid_credentials)
                echo "[DIAGNOSIS] Caller's own credentials are not valid (${_AWS_ERR_CLASS})." >&2
                echo "  - Fix the caller's credentials before attempting to assume another role." >&2
                ;;
            *)
                echo "[DIAGNOSIS] Unknown failure — see raw error above." >&2
                ;;
        esac
    else
        # lib.sh not loaded — inline classification
        if   grep -qi "AccessDenied\|is not authorized" <<< "$_ASSUME_OUT"; then
            echo "[DIAGNOSIS] sts:AssumeRole denied. Check trust policy on '${_ROLE_ARN}'." >&2
        elif grep -qi "Could not connect\|ConnectTimeout\|Endpoint URL" <<< "$_ASSUME_OUT"; then
            echo "[DIAGNOSIS] Network error — STS VPC endpoint may be missing in this VPC." >&2
        elif grep -qi "Unable to locate credentials\|NoCredentialProviders" <<< "$_ASSUME_OUT"; then
            echo "[DIAGNOSIS] No credentials for the caller — fix caller creds first." >&2
        elif grep -qi "ExpiredToken" <<< "$_ASSUME_OUT"; then
            echo "[DIAGNOSIS] Caller's token expired — check IMDS / instance profile refresh." >&2
        fi
    fi
    unset _ROLE_ARN _SESSION_NAME _DURATION _ASSUME_OUT
    return 1
fi

# ── Export credentials ────────────────────────────────────────────────────────
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN

AWS_ACCESS_KEY_ID=$(echo "$_ASSUME_OUT"    | jq -r '.Credentials.AccessKeyId')
AWS_SECRET_ACCESS_KEY=$(echo "$_ASSUME_OUT" | jq -r '.Credentials.SecretAccessKey')
AWS_SESSION_TOKEN=$(echo "$_ASSUME_OUT"     | jq -r '.Credentials.SessionToken')
_EXPIRY=$(echo "$_ASSUME_OUT"               | jq -r '.Credentials.Expiration')

echo "[INFO]  Credentials exported. Expires: ${_EXPIRY}"
echo "[INFO]  Effective identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo '[sts unavailable]')"

# ── Cleanup locals ────────────────────────────────────────────────────────────
unset _ROLE_ARN _SESSION_NAME _DURATION _ASSUME_OUT _EXPIRY
