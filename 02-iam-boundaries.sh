#!/usr/bin/env bash
# 02-iam-boundaries.sh — Permissions boundary detection and effective policy enumeration
set -euo pipefail

# shellcheck source=lib.sh
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f "${_LIB_DIR}/lib.sh" ]] && source "${_LIB_DIR}/lib.sh" || { echo "[ERROR] lib.sh not found — run scripts from their directory"; exit 1; }

section() { echo ""; echo "--- $1 ---"; echo ""; }

# Credential check first — if STS is unreachable, diagnose before spending
# time on IAM calls that will all fail for the same reason.
sts_preflight || true

# Determine our identity
IDENTITY=$(aws_safe sts get-caller-identity --output json) || true
if [[ -z "$IDENTITY" ]]; then
    echo "[FAIL] Cannot call sts:GetCallerIdentity — no valid credentials"
    exit 1
fi

ARN=$(echo "$IDENTITY" | jq -r '.Arn')
ACCOUNT=$(echo "$IDENTITY" | jq -r '.Account')
echo "Caller ARN: ${ARN}"
echo "Account:    ${ACCOUNT}"

# Extract role/user name from ARN
# Handles path prefixes: arn:aws-us-gov:iam::ACCT:role/org/team/ROLE_NAME
# Handles assumed-role:  arn:aws-us-gov:sts::ACCT:assumed-role/ROLE_NAME/SESSION
# Handles users:         arn:aws-us-gov:iam::ACCT:user/admins/USER_NAME
ROLE_NAME=""
ROLE_PATH=""
USER_NAME=""
ENTITY_TYPE=""

if [[ "$ARN" == *":assumed-role/"* ]]; then
    # assumed-role ARNs: always role-name/session (no path prefix)
    ROLE_NAME=$(echo "$ARN" | sed 's|.*:assumed-role/||' | cut -d/ -f1)
    ROLE_PATH="$ROLE_NAME"
    ENTITY_TYPE="role"
elif [[ "$ARN" == *":role/"* ]]; then
    # role ARNs may have path: role/path/to/ROLE_NAME
    ROLE_PATH=$(echo "$ARN" | sed 's|.*:role/||')
    ROLE_NAME=$(basename "$ROLE_PATH")
    ENTITY_TYPE="role"
elif [[ "$ARN" == *":user/"* ]]; then
    local_path=$(echo "$ARN" | sed 's|.*:user/||')
    USER_NAME=$(basename "$local_path")
    ENTITY_TYPE="user"
fi

# ---------- Role Details ----------
if [[ "$ENTITY_TYPE" == "role" && -n "$ROLE_NAME" ]]; then
    section "IAM Role Details: ${ROLE_NAME}"

    echo "Fetching role metadata..."
    ROLE_INFO=$(aws iam get-role --role-name "$ROLE_NAME" --output json 2>&1) || true

    if echo "$ROLE_INFO" | jq . &>/dev/null; then
        echo "$ROLE_INFO" | jq '{
            RoleName: .Role.RoleName,
            RoleId: .Role.RoleId,
            Arn: .Role.Arn,
            CreateDate: .Role.CreateDate,
            MaxSessionDuration: .Role.MaxSessionDuration,
            Path: .Role.Path
        }'

        # ---------- Permissions Boundary ----------
        section "Permissions Boundary"
        BOUNDARY=$(echo "$ROLE_INFO" | jq -r '.Role.PermissionsBoundary // empty')
        if [[ -n "$BOUNDARY" ]]; then
            BOUNDARY_ARN=$(echo "$BOUNDARY" | jq -r '.PermissionsBoundaryArn')
            BOUNDARY_TYPE=$(echo "$BOUNDARY" | jq -r '.PermissionsBoundaryType')
            echo "Boundary Type: ${BOUNDARY_TYPE}"
            echo "Boundary ARN:  ${BOUNDARY_ARN}"

            echo ""
            echo "Boundary Policy Document:"
            # Extract policy name from ARN for managed policies
            if [[ "$BOUNDARY_ARN" == *":policy/"* ]]; then
                POLICY_NAME=$(echo "$BOUNDARY_ARN" | sed 's|.*:policy/||')
                # Get the policy version
                DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$BOUNDARY_ARN" \
                    --query 'Policy.DefaultVersionId' --output text 2>/dev/null || echo "")
                if [[ -n "$DEFAULT_VERSION" ]]; then
                    aws iam get-policy-version \
                        --policy-arn "$BOUNDARY_ARN" \
                        --version-id "$DEFAULT_VERSION" \
                        --query 'PolicyVersion.Document' \
                        --output json 2>&1 | jq . 2>/dev/null || echo "[Could not retrieve boundary policy document]"
                else
                    echo "[Could not determine default policy version]"
                fi
            fi
        else
            echo "No permissions boundary attached to this role"
        fi

        # ---------- Trust Policy ----------
        section "Trust Policy (AssumeRolePolicyDocument)"
        echo "$ROLE_INFO" | jq '.Role.AssumeRolePolicyDocument' 2>/dev/null || echo "[unavailable]"

        # ---------- Attached Managed Policies ----------
        section "Attached Managed Policies"
        aws iam list-attached-role-policies --role-name "$ROLE_NAME" --output json 2>&1 | \
            jq '.AttachedPolicies[]? | {PolicyName, PolicyArn}' 2>/dev/null || echo "[Access denied or no policies]"

        # ---------- Inline Policies ----------
        section "Inline Policies"
        INLINE=$(aws iam list-role-policies --role-name "$ROLE_NAME" --output json 2>&1)
        echo "$INLINE" | jq '.PolicyNames[]?' 2>/dev/null || echo "[Access denied or no inline policies]"

        # Enumerate each inline policy document
        if echo "$INLINE" | jq -e '.PolicyNames | length > 0' &>/dev/null; then
            for POLICY in $(echo "$INLINE" | jq -r '.PolicyNames[]'); do
                echo ""
                echo "  Policy: ${POLICY}"
                aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY" \
                    --query 'PolicyDocument' --output json 2>&1 | jq . 2>/dev/null || echo "  [Access denied]"
            done
        fi

        # ---------- Instance Profiles ----------
        section "Instance Profiles for Role"
        aws iam list-instance-profiles-for-role --role-name "$ROLE_NAME" --output json 2>&1 | \
            jq '.InstanceProfiles[]? | {InstanceProfileName, InstanceProfileId, Arn}' 2>/dev/null || \
            echo "[Access denied]"

    else
        echo "[WARN] Could not get role details (likely access denied):"
        echo "$ROLE_INFO"
    fi

# ---------- User Details ----------
elif [[ "$ENTITY_TYPE" == "user" && -n "$USER_NAME" ]]; then
    section "IAM User Details: ${USER_NAME}"

    USER_INFO=$(aws iam get-user --user-name "$USER_NAME" --output json 2>&1) || true

    if echo "$USER_INFO" | jq . &>/dev/null; then
        echo "$USER_INFO" | jq '{
            UserName: .User.UserName,
            UserId: .User.UserId,
            Arn: .User.Arn,
            CreateDate: .User.CreateDate,
            Path: .User.Path
        }'

        section "Permissions Boundary"
        BOUNDARY=$(echo "$USER_INFO" | jq -r '.User.PermissionsBoundary // empty')
        if [[ -n "$BOUNDARY" ]]; then
            BOUNDARY_ARN=$(echo "$BOUNDARY" | jq -r '.PermissionsBoundaryArn')
            echo "Boundary ARN: ${BOUNDARY_ARN}"

            if [[ "$BOUNDARY_ARN" == *":policy/"* ]]; then
                DEFAULT_VERSION=$(aws iam get-policy --policy-arn "$BOUNDARY_ARN" \
                    --query 'Policy.DefaultVersionId' --output text 2>/dev/null || echo "")
                if [[ -n "$DEFAULT_VERSION" ]]; then
                    echo ""
                    echo "Boundary Policy Document:"
                    aws iam get-policy-version \
                        --policy-arn "$BOUNDARY_ARN" \
                        --version-id "$DEFAULT_VERSION" \
                        --query 'PolicyVersion.Document' \
                        --output json 2>&1 | jq . 2>/dev/null || echo "[Could not retrieve]"
                fi
            fi
        else
            echo "No permissions boundary attached to this user"
        fi

        section "Attached Managed Policies"
        aws iam list-attached-user-policies --user-name "$USER_NAME" --output json 2>&1 | \
            jq '.AttachedPolicies[]? | {PolicyName, PolicyArn}' 2>/dev/null || echo "[Access denied]"

        section "Inline Policies"
        aws iam list-user-policies --user-name "$USER_NAME" --output json 2>&1 | \
            jq '.PolicyNames[]?' 2>/dev/null || echo "[Access denied]"

        section "Group Memberships"
        aws iam list-groups-for-user --user-name "$USER_NAME" --output json 2>&1 | \
            jq '.Groups[]? | {GroupName, Arn}' 2>/dev/null || echo "[Access denied]"
    else
        echo "[WARN] Could not get user details:"
        echo "$USER_INFO"
    fi
else
    echo "[WARN] Could not determine entity type from ARN: ${ARN}"
fi

# ---------- Simulate Key Actions ----------
section "Policy Simulation (iam:SimulatePrincipalPolicy)"
echo "Attempting to simulate key actions against caller's effective policies..."
echo "(This call itself requires iam:SimulatePrincipalPolicy permission)"
echo ""

# Build the principal ARN (must be the role ARN, not the assumed-role ARN)
# Use ROLE_PATH to preserve any path prefix (e.g., role/org/team/MyRole)
if [[ "$ENTITY_TYPE" == "role" && -n "$ROLE_NAME" ]]; then
    PARTITION="aws"
    [[ "$ARN" == *"aws-us-gov"* ]] && PARTITION="aws-us-gov"
    PRINCIPAL_ARN="arn:${PARTITION}:iam::${ACCOUNT}:role/${ROLE_PATH}"
elif [[ "$ENTITY_TYPE" == "user" && -n "$USER_NAME" ]]; then
    PARTITION="aws"
    [[ "$ARN" == *"aws-us-gov"* ]] && PARTITION="aws-us-gov"
    PRINCIPAL_ARN="arn:${PARTITION}:iam::${ACCOUNT}:user/${USER_NAME}"
else
    PRINCIPAL_ARN="$ARN"
fi

SIMULATE_ACTIONS=(
    "iam:CreateOpenIDConnectProvider"
    "iam:GetOpenIDConnectProvider"
    "iam:ListOpenIDConnectProviders"
    "sts:AssumeRole"
    "sts:AssumeRoleWithWebIdentity"
    "eks:DescribeCluster"
    "eks:ListClusters"
    "ec2:DescribeVpcs"
    "ec2:DescribeSubnets"
    "ecr:GetAuthorizationToken"
    "s3:ListBucket"
)

aws iam simulate-principal-policy \
    --policy-source-arn "$PRINCIPAL_ARN" \
    --action-names "${SIMULATE_ACTIONS[@]}" \
    --output json 2>&1 | \
    jq '.EvaluationResults[]? | {Action: .EvalActionName, Decision: .EvalDecision, MatchedStatements: (.MatchedStatements | length)}' 2>/dev/null || \
    echo "[Access denied — iam:SimulatePrincipalPolicy not permitted. Use 03-iam-capabilities.sh for empirical testing.]"
