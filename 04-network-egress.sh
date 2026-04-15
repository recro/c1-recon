#!/usr/bin/env bash
# 04-network-egress.sh — Egress model detection: NAT, proxy, direct, VPC endpoints
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }

# ---------- Detect region ----------
_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"
echo "Detected region: ${REGION}"

# ---------- Public IP Check ----------
section "External IP (egress path)"
echo "Checking external IP to determine egress model..."
echo "NOTE: In this airgapped environment, ALL external IP checks are expected to fail."
echo "      Failure confirms the airgap is working correctly (no internet egress path)."
echo ""
for service in "https://checkip.amazonaws.com" "https://ifconfig.me" "https://api.ipify.org"; do
    printf "  %-40s " "$service"
    RESULT=$(curl -sfm 10 "$service" 2>/dev/null) || RESULT="[timeout/unreachable]"
    echo "$RESULT"
done

# ---------- Proxy Detection ----------
section "Proxy Configuration"
echo "HTTP_PROXY:  ${HTTP_PROXY:-[not set]}"
echo "HTTPS_PROXY: ${HTTPS_PROXY:-[not set]}"
echo "http_proxy:  ${http_proxy:-[not set]}"
echo "https_proxy: ${https_proxy:-[not set]}"
echo "NO_PROXY:    ${NO_PROXY:-[not set]}"
echo "no_proxy:    ${no_proxy:-[not set]}"

# Check for system proxy files
echo ""
echo "Proxy config files:"
for f in /etc/profile.d/proxy.sh /etc/environment /etc/sysconfig/proxy; do
    if [[ -f "$f" ]]; then
        echo "  [FOUND] $f"
        grep -i proxy "$f" 2>/dev/null | head -5 | sed 's/^/    /'
    fi
done

# ---------- NAT Gateway Detection ----------
section "NAT Gateways"
if aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
    --region "$REGION" --output json 2>/dev/null | jq -e '.NatGateways | length > 0' &>/dev/null; then
    aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
        --region "$REGION" --output json 2>/dev/null | \
        jq '.NatGateways[] | {
            NatGatewayId,
            State,
            SubnetId,
            VpcId,
            ConnectivityType,
            PublicIp: (.NatGatewayAddresses[]?.PublicIp // "N/A"),
            PrivateIp: (.NatGatewayAddresses[]?.PrivateIp // "N/A")
        }'
else
    echo "[INFO] No NAT gateways found (or ec2:DescribeNatGateways denied)"
fi

# ---------- VPC Endpoints ----------
section "VPC Endpoints"
ENDPOINTS=$(aws ec2 describe-vpc-endpoints --region "$REGION" --output json 2>/dev/null) || true

if [[ -n "$ENDPOINTS" ]] && echo "$ENDPOINTS" | jq -e '.VpcEndpoints | length > 0' &>/dev/null; then
    echo "Found VPC endpoints:"
    echo ""
    echo "$ENDPOINTS" | jq -r '.VpcEndpoints[] | "  \(.VpcEndpointId)\t\(.VpcEndpointType)\t\(.ServiceName)\t\(.State)"'

    echo ""
    echo "Endpoint details:"
    echo "$ENDPOINTS" | jq '.VpcEndpoints[] | {
        VpcEndpointId,
        VpcEndpointType,
        ServiceName,
        State,
        VpcId,
        SubnetIds: (.SubnetIds // []),
        RouteTableIds: (.RouteTableIds // []),
        PrivateDnsEnabled: .PrivateDnsEnabled
    }'
else
    echo "[INFO] No VPC endpoints found (or ec2:DescribeVpcEndpoints denied)"
    echo ""
    echo "Without VPC endpoints, this VPC likely relies on NAT gateway or proxy for AWS service access."
    echo "Key endpoints that may be needed:"
    echo "  - com.amazonaws.${REGION}.eks"
    echo "  - com.amazonaws.${REGION}.ecr.api"
    echo "  - com.amazonaws.${REGION}.ecr.dkr"
    echo "  - com.amazonaws.${REGION}.s3"
    echo "  - com.amazonaws.${REGION}.sts"
    echo "  - com.amazonaws.${REGION}.ec2"
    echo "  - com.amazonaws.${REGION}.elasticloadbalancing"
fi

# ---------- Internet Gateway ----------
section "Internet Gateways"
aws ec2 describe-internet-gateways --region "$REGION" --output json 2>/dev/null | \
    jq '.InternetGateways[]? | {
        InternetGatewayId,
        Attachments: [.Attachments[]? | {VpcId, State}]
    }' 2>/dev/null || echo "[INFO] Could not enumerate internet gateways"

# ---------- Route Tables (default routes) ----------
section "Default Routes (0.0.0.0/0)"
aws ec2 describe-route-tables --region "$REGION" --output json 2>/dev/null | \
    jq '.RouteTables[] |
        {RouteTableId, VpcId, Routes: [.Routes[] | select(.DestinationCidrBlock == "0.0.0.0/0") | {
            DestinationCidrBlock,
            GatewayId: (.GatewayId // null),
            NatGatewayId: (.NatGatewayId // null),
            TransitGatewayId: (.TransitGatewayId // null),
            NetworkInterfaceId: (.NetworkInterfaceId // null),
            State
        }]} | select(.Routes | length > 0)' 2>/dev/null || \
    echo "[INFO] Could not enumerate route tables"

# ---------- Egress Model Summary ----------
section "Egress Model Assessment"
echo "Based on the checks above, determine which egress model is in use:"
echo ""
echo "  1. NAT Gateway — private subnet routes 0.0.0.0/0 via nat-xxxxx"
echo "     Implications: full internet egress, public IP is NAT's EIP"
echo ""
echo "  2. Internet Gateway (direct) — public subnet routes 0.0.0.0/0 via igw-xxxxx"
echo "     Implications: instance has public IP, direct internet access"
echo ""
echo "  3. Proxy — HTTP_PROXY/HTTPS_PROXY set, traffic funnels through proxy"
echo "     Implications: must configure AWS CLI and container runtimes for proxy"
echo ""
echo "  4. VPC Endpoints only — no internet route, AWS services via privatelink"
echo "     Implications: only allowlisted AWS services reachable, no external"
echo ""
echo "  5. Transit Gateway — routes via tgw-xxxxx to shared services VPC"
echo "     Implications: centralized egress, firewall rules controlled by network team"
echo ""
echo "  6. Airgapped with VPC Endpoints + dedicated connectivity"
echo "     Topology: AWS services accessed exclusively via VPC interface endpoints."
echo "     No NAT gateway, no internet gateway, no internet route whatsoever."
echo "     Dedicated punch-through link to LevelUp GitLab (code.levelup.cce.af.mil)"
echo "     provides the sole external path for CI/CD (GitLab runners deploy through it)."
echo "     Implications: every AWS service call must have a corresponding VPC endpoint;"
echo "     container images must be pre-staged in ECR or pulled via the GitLab link."

# ---------- GitLab Connectivity ----------
section "GitLab Connectivity (dedicated punch-through)"
echo "code.levelup.cce.af.mil is the sole external connectivity path in this airgapped"
echo "environment. GitLab runners deploy through this link for CI/CD operations."
echo ""
printf "  %-40s " "DNS resolution"
if command -v dig &>/dev/null; then
    GL_DNS=$(dig +short +timeout=5 code.levelup.cce.af.mil 2>/dev/null | head -1)
elif command -v nslookup &>/dev/null; then
    GL_DNS=$(nslookup code.levelup.cce.af.mil 2>/dev/null | grep -A1 "Name:" | grep "Address" | awk '{print $2}' | head -1)
else
    GL_DNS=""
fi
if [[ -n "$GL_DNS" ]]; then
    echo "[OK] ${GL_DNS}"
else
    echo "[FAIL] Cannot resolve code.levelup.cce.af.mil"
fi

printf "  %-40s " "HTTPS connectivity"
GL_HTTP=$(curl -so /dev/null -w "%{http_code}" -m 10 "https://code.levelup.cce.af.mil/" 2>/dev/null) || GL_HTTP="000"
case "$GL_HTTP" in
    000) echo "[UNREACHABLE]" ;;
    *)   echo "[OK] HTTP ${GL_HTTP}" ;;
esac
