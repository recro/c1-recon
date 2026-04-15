#!/usr/bin/env bash
# 08-vpc-environment.sh — VPC, subnet, route table, security group enumeration
set -euo pipefail

section() { echo ""; echo "--- $1 ---"; echo ""; }

_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

echo "Region: ${REGION}"

# Get this instance's VPC
TOKEN="$_IMDS_TOKEN"
if [[ -n "$TOKEN" ]]; then
    MAC=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/mac" 2>/dev/null || true)
    INSTANCE_VPC=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id" 2>/dev/null || true)
    INSTANCE_SUBNET=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/subnet-id" 2>/dev/null || true)
    INSTANCE_SG=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/security-group-ids" 2>/dev/null || true)
else
    INSTANCE_VPC=""
    INSTANCE_SUBNET=""
    INSTANCE_SG=""
fi

echo "Instance VPC:    ${INSTANCE_VPC:-[unknown]}"
echo "Instance Subnet: ${INSTANCE_SUBNET:-[unknown]}"
echo "Instance SGs:    ${INSTANCE_SG:-[unknown]}"

# ---------- VPCs ----------
section "VPCs"
aws ec2 describe-vpcs --region "$REGION" --output json 2>/dev/null | \
    jq '.Vpcs[] | {
        VpcId,
        CidrBlock,
        State,
        IsDefault,
        OwnerId,
        Tags: [(.Tags[]? // empty) | select(.Key == "Name") | .Value] | first // "untagged"
    }' 2>/dev/null || echo "[DENIED] Cannot describe VPCs"

# ---------- Subnets (focus on instance's VPC) ----------
section "Subnets"
if [[ -n "$INSTANCE_VPC" ]]; then
    echo "Showing subnets for instance VPC: ${INSTANCE_VPC}"
    echo ""
    aws ec2 describe-subnets --region "$REGION" \
        --filters "Name=vpc-id,Values=${INSTANCE_VPC}" --output json 2>/dev/null | \
        jq '.Subnets[] | {
            SubnetId,
            AvailabilityZone,
            CidrBlock,
            AvailableIpAddressCount,
            MapPublicIpOnLaunch,
            State,
            Name: [(.Tags[]? // empty) | select(.Key == "Name") | .Value] | first // "untagged"
        }' 2>/dev/null || echo "[DENIED]"
else
    echo "All subnets:"
    aws ec2 describe-subnets --region "$REGION" --output json 2>/dev/null | \
        jq '.Subnets[] | {SubnetId, VpcId, AvailabilityZone, CidrBlock, MapPublicIpOnLaunch}' 2>/dev/null || echo "[DENIED]"
fi

# ---------- Route Tables ----------
section "Route Tables"
if [[ -n "$INSTANCE_VPC" ]]; then
    echo "Route tables for VPC: ${INSTANCE_VPC}"
    echo ""
    aws ec2 describe-route-tables --region "$REGION" \
        --filters "Name=vpc-id,Values=${INSTANCE_VPC}" --output json 2>/dev/null | \
        jq '.RouteTables[] | {
            RouteTableId,
            VpcId,
            Name: [(.Tags[]? // empty) | select(.Key == "Name") | .Value] | first // "untagged",
            Associations: [.Associations[]? | {SubnetId, Main}],
            Routes: [.Routes[] | {
                Destination: (.DestinationCidrBlock // .DestinationPrefixListId // "other"),
                Target: (.GatewayId // .NatGatewayId // .TransitGatewayId // .VpcPeeringConnectionId // .NetworkInterfaceId // "local"),
                State
            }]
        }' 2>/dev/null || echo "[DENIED]"
else
    aws ec2 describe-route-tables --region "$REGION" --output json 2>/dev/null | \
        jq '.RouteTables[] | {RouteTableId, VpcId, Routes: [.Routes[] | {Destination: .DestinationCidrBlock, Target: (.GatewayId // .NatGatewayId // "other")}]}' 2>/dev/null || echo "[DENIED]"
fi

# ---------- Security Groups (instance's SGs) ----------
section "Security Groups (this instance)"
if [[ -n "$INSTANCE_SG" ]]; then
    for SG in $INSTANCE_SG; do
        echo "Security Group: ${SG}"
        aws ec2 describe-security-groups --region "$REGION" \
            --group-ids "$SG" --output json 2>/dev/null | \
            jq '.SecurityGroups[] | {
                GroupId,
                GroupName,
                VpcId,
                Description,
                IngressRules: [.IpPermissions[] | {
                    Protocol: .IpProtocol,
                    FromPort: .FromPort,
                    ToPort: .ToPort,
                    Sources: ([.IpRanges[]?.CidrIp] + [.UserIdGroupPairs[]?.GroupId] + [.PrefixListIds[]?.PrefixListId])
                }],
                EgressRules: [.IpPermissionsEgress[] | {
                    Protocol: .IpProtocol,
                    FromPort: .FromPort,
                    ToPort: .ToPort,
                    Destinations: ([.IpRanges[]?.CidrIp] + [.UserIdGroupPairs[]?.GroupId] + [.PrefixListIds[]?.PrefixListId])
                }]
            }' 2>/dev/null || echo "  [DENIED]"
        echo ""
    done
else
    echo "Instance SGs unknown — showing all SGs in account:"
    aws ec2 describe-security-groups --region "$REGION" --output json 2>/dev/null | \
        jq '.SecurityGroups[] | {GroupId, GroupName, VpcId, Description}' 2>/dev/null || echo "[DENIED]"
fi

# ---------- VPC Endpoints (critical in airgap) ----------
section "VPC Endpoints (airgapped — sole path to AWS services)"
echo "In this airgapped environment, VPC endpoints are the ONLY path to AWS services."
echo "Missing endpoints = broken functionality. Every AWS API call requires a corresponding"
echo "interface endpoint (PrivateLink) or gateway endpoint (S3/DynamoDB)."
echo ""
if [[ -n "$INSTANCE_VPC" ]]; then
    ENDPOINTS=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
        --filters "Name=vpc-id,Values=${INSTANCE_VPC}" --output json 2>/dev/null) || true
else
    ENDPOINTS=$(aws ec2 describe-vpc-endpoints --region "$REGION" --output json 2>/dev/null) || true
fi

if [[ -n "$ENDPOINTS" ]] && echo "$ENDPOINTS" | jq -e '.VpcEndpoints | length > 0' &>/dev/null; then
    EP_COUNT=$(echo "$ENDPOINTS" | jq '.VpcEndpoints | length')
    echo "Found ${EP_COUNT} VPC endpoints:"
    echo ""
    echo "$ENDPOINTS" | jq -r '.VpcEndpoints[] | "  \(.VpcEndpointId)\t\(.VpcEndpointType)\t\(.ServiceName)\t\(.State)\tPrivateDNS=\(.PrivateDnsEnabled)"' | \
        sort -t$'\t' -k3 | column -t -s$'\t' 2>/dev/null || \
        echo "$ENDPOINTS" | jq -r '.VpcEndpoints[] | "  \(.VpcEndpointId) \(.VpcEndpointType) \(.ServiceName) \(.State)"'

    # Check for critical missing endpoints
    echo ""
    echo "Critical endpoint coverage check:"
    REQUIRED_SERVICES=(
        "com.amazonaws.${REGION}.eks"
        "com.amazonaws.${REGION}.ecr.api"
        "com.amazonaws.${REGION}.ecr.dkr"
        "com.amazonaws.${REGION}.s3"
        "com.amazonaws.${REGION}.sts"
        "com.amazonaws.${REGION}.ec2"
        "com.amazonaws.${REGION}.elasticloadbalancing"
        "com.amazonaws.${REGION}.autoscaling"
        "com.amazonaws.${REGION}.logs"
        "com.amazonaws.${REGION}.kms"
        "com.amazonaws.${REGION}.secretsmanager"
        "com.amazonaws.${REGION}.ssm"
    )
    for SVC in "${REQUIRED_SERVICES[@]}"; do
        printf "    %-55s " "$SVC"
        if echo "$ENDPOINTS" | jq -r '.VpcEndpoints[].ServiceName' | grep -qF "$SVC"; then
            echo "[PRESENT]"
        else
            echo "[MISSING] — this AWS service is unreachable"
        fi
    done
else
    echo "[WARN] No VPC endpoints found (or access denied)"
    echo "       In an airgapped environment, this means NO AWS services are reachable."
fi

# ---------- VPC Peering ----------
section "VPC Peering Connections"
aws ec2 describe-vpc-peering-connections --region "$REGION" --output json 2>/dev/null | \
    jq '.VpcPeeringConnections[]? | {
        PeeringId: .VpcPeeringConnectionId,
        Status: .Status.Code,
        Requester: {VpcId: .RequesterVpcInfo.VpcId, CidrBlock: .RequesterVpcInfo.CidrBlock, OwnerId: .RequesterVpcInfo.OwnerId},
        Accepter: {VpcId: .AccepterVpcInfo.VpcId, CidrBlock: .AccepterVpcInfo.CidrBlock, OwnerId: .AccepterVpcInfo.OwnerId}
    }' 2>/dev/null || echo "[INFO] No peering connections or access denied"

# ---------- Transit Gateway Attachments ----------
section "Transit Gateway Attachments"
aws ec2 describe-transit-gateway-attachments --region "$REGION" --output json 2>/dev/null | \
    jq '.TransitGatewayAttachments[]? | {
        TransitGatewayAttachmentId,
        TransitGatewayId,
        ResourceType,
        ResourceId,
        State
    }' 2>/dev/null || echo "[INFO] No TGW attachments or access denied"

# ---------- Network ACLs ----------
section "Network ACLs"
if [[ -n "$INSTANCE_VPC" ]]; then
    aws ec2 describe-network-acls --region "$REGION" \
        --filters "Name=vpc-id,Values=${INSTANCE_VPC}" --output json 2>/dev/null | \
        jq '.NetworkAcls[] | {
            NetworkAclId,
            VpcId,
            IsDefault,
            Associations: [.Associations[]?.SubnetId],
            InboundRules: [.Entries[] | select(.Egress == false) | {
                RuleNumber, Protocol, RuleAction,
                CidrBlock: (.CidrBlock // .Ipv6CidrBlock),
                PortRange: .PortRange
            }],
            OutboundRules: [.Entries[] | select(.Egress == true) | {
                RuleNumber, Protocol, RuleAction,
                CidrBlock: (.CidrBlock // .Ipv6CidrBlock),
                PortRange: .PortRange
            }]
        }' 2>/dev/null || echo "[DENIED]"
fi

# ---------- DHCP Options ----------
section "DHCP Options"
if [[ -n "$INSTANCE_VPC" ]]; then
    DHCP_ID=$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$INSTANCE_VPC" \
        --query 'Vpcs[0].DhcpOptionsId' --output text 2>/dev/null || echo "")
    if [[ -n "$DHCP_ID" && "$DHCP_ID" != "None" ]]; then
        echo "DHCP Options Set: ${DHCP_ID}"
        aws ec2 describe-dhcp-options --region "$REGION" --dhcp-options-ids "$DHCP_ID" --output json 2>/dev/null | \
            jq '.DhcpOptions[].DhcpConfigurations[] | {Key, Values: [.Values[].Value]}' 2>/dev/null || echo "[DENIED]"
    fi
fi
