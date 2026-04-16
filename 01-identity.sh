#!/usr/bin/env bash
# 01-identity.sh — Who am I? STS identity, instance metadata, attached roles
set -euo pipefail

IMDS_TOKEN_TTL=21600
section() { echo ""; echo "--- $1 ---"; echo ""; }

# ---------- IMDS Token (IMDSv2) ----------
section "Instance Metadata (IMDSv2)"

TOKEN=$(curl -sfm 2 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: ${IMDS_TOKEN_TTL}" 2>/dev/null) || true

if [[ -z "${TOKEN:-}" ]]; then
    echo "[WARN] Could not obtain IMDSv2 token — IMDS may be disabled or v1-only"
    echo "       Trying IMDSv1 fallback..."
    IMDS_HEADER=""
    IMDS_V=1
else
    IMDS_HEADER="X-aws-ec2-metadata-token: ${TOKEN}"
    IMDS_V=2
    echo "IMDSv2 token acquired (TTL=${IMDS_TOKEN_TTL}s)"
fi

imds_get() {
    local path="$1"
    if [[ "$IMDS_V" == "2" ]]; then
        curl -sf -H "${IMDS_HEADER}" "http://169.254.169.254${path}" 2>/dev/null || echo "[unavailable]"
    else
        curl -sf "http://169.254.169.254${path}" 2>/dev/null || echo "[unavailable]"
    fi
}

echo ""
echo "Instance ID:        $(imds_get /latest/meta-data/instance-id)"
echo "Instance Type:      $(imds_get /latest/meta-data/instance-type)"
echo "AMI ID:             $(imds_get /latest/meta-data/ami-id)"
echo "Availability Zone:  $(imds_get /latest/meta-data/placement/availability-zone)"
echo "Region:             $(imds_get /latest/meta-data/placement/region)"
echo "Private IP:         $(imds_get /latest/meta-data/local-ipv4)"
echo "Public IP:          $(imds_get /latest/meta-data/public-ipv4)"
echo "MAC Address:        $(imds_get /latest/meta-data/mac)"
echo "VPC ID:             $(imds_get /latest/meta-data/network/interfaces/macs/$(imds_get /latest/meta-data/mac)/vpc-id)"
echo "Subnet ID:          $(imds_get /latest/meta-data/network/interfaces/macs/$(imds_get /latest/meta-data/mac)/subnet-id)"
echo "Security Groups:    $(imds_get /latest/meta-data/security-groups)"

section "Instance Profile / IAM Role"
IAM_ROLE=$(imds_get /latest/meta-data/iam/info)
echo "$IAM_ROLE" | jq . 2>/dev/null || echo "$IAM_ROLE"

ROLE_NAME=$(imds_get /latest/meta-data/iam/security-credentials/)
echo ""
echo "Role Name:          ${ROLE_NAME}"

if [[ "$ROLE_NAME" != "[unavailable]" && -n "$ROLE_NAME" ]]; then
    echo ""
    echo "Credential Expiration:"
    CREDS=$(imds_get "/latest/meta-data/iam/security-credentials/${ROLE_NAME}")
    echo "$CREDS" | jq '{Type, LastUpdated, Expiration}' 2>/dev/null || echo "$CREDS"
fi

# ---------- STS Caller Identity ----------
section "STS Caller Identity"
if command -v aws &>/dev/null; then
    aws sts get-caller-identity --output json 2>&1 | jq . 2>/dev/null || aws sts get-caller-identity 2>&1
else
    echo "[SKIP] AWS CLI not found"
fi

# ---------- Region Detection ----------
section "Effective Region"
DETECTED_REGION=$(imds_get /latest/meta-data/placement/region)
CONFIGURED_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-[not set]}}"
echo "IMDS region:        ${DETECTED_REGION}"
echo "AWS_DEFAULT_REGION: ${AWS_DEFAULT_REGION:-[not set]}"
echo "AWS_REGION:         ${AWS_REGION:-[not set]}"
echo "aws configure get:  $(aws configure get region 2>/dev/null || echo '[not configured]')"

if [[ "$DETECTED_REGION" != "$CONFIGURED_REGION" && "$CONFIGURED_REGION" != "[not set]" ]]; then
    echo ""
    echo "[WARN] IMDS region (${DETECTED_REGION}) differs from configured region (${CONFIGURED_REGION})"
fi

# ---------- User Data ----------
section "User Data (first 20 lines, if available)"
echo "[CAUTION] User data may contain secrets — review before sharing this report."
USERDATA=$(imds_get /latest/user-data)
if [[ "$USERDATA" == "[unavailable]" ]]; then
    echo "No user data or access denied"
else
    # Redact common secret patterns
    echo "$USERDATA" | head -20 | \
        sed -E 's/(PASSWORD|SECRET|TOKEN|KEY|PASS)=.*/\1=<REDACTED>/gi'
    TOTAL=$(echo "$USERDATA" | wc -l)
    if (( TOTAL > 20 )); then
        echo "... (${TOTAL} total lines, truncated)"
    fi
fi
