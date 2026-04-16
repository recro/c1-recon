#!/usr/bin/env bash
# 11-export-twin.sh — Export structured JSON snapshot for digital twin provisioning
#
# Captures the full environment topology as machine-parseable JSON so a commercial
# AWS account can replicate the CloudOne GovCloud network, IAM, EKS, and endpoint
# structure. The output is a single JSON document written to stdout (pipe to file).
#
# Usage:
#   ./11-export-twin.sh > twin-snapshot-$(date -u +%Y%m%d).json
#
# The JSON is organized into sections that map 1:1 to Terraform resources/modules.
# Sensitive values (account IDs, role ARNs) are captured — they're needed to model
# the twin accurately. Review before sharing outside the team.
set -euo pipefail

# ---------- Bootstrap ----------
_IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null) || true
if [[ -n "$_IMDS_TOKEN" ]]; then
    REGION=$(curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" \
        "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null) || true
fi
REGION="${REGION:-${AWS_DEFAULT_REGION:-us-gov-west-1}}"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "unknown")
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "unknown")
PARTITION="aws"
[[ "$REGION" == *"gov"* ]] && PARTITION="aws-us-gov"

# Instance metadata
INSTANCE_ID="unknown"
INSTANCE_TYPE="unknown"
AMI_ID="unknown"
AZ="unknown"
PRIVATE_IP="unknown"
INSTANCE_VPC="unknown"
INSTANCE_SUBNET="unknown"
if [[ -n "$_IMDS_TOKEN" ]]; then
    imds() { curl -sf -H "X-aws-ec2-metadata-token: $_IMDS_TOKEN" "http://169.254.169.254$1" 2>/dev/null || echo "unknown"; }
    INSTANCE_ID=$(imds /latest/meta-data/instance-id)
    INSTANCE_TYPE=$(imds /latest/meta-data/instance-type)
    AMI_ID=$(imds /latest/meta-data/ami-id)
    AZ=$(imds /latest/meta-data/placement/availability-zone)
    PRIVATE_IP=$(imds /latest/meta-data/local-ipv4)
    MAC=$(imds /latest/meta-data/mac)
    INSTANCE_VPC=$(imds "/latest/meta-data/network/interfaces/macs/${MAC}/vpc-id")
    INSTANCE_SUBNET=$(imds "/latest/meta-data/network/interfaces/macs/${MAC}/subnet-id")
fi

# Helper: run AWS CLI, return JSON or null
aws_json() {
    aws "$@" --output json --region "$REGION" 2>/dev/null || echo "null"
}

# ============================================================
# Collect all data into shell variables as JSON fragments,
# then assemble at the end with jq.
# ============================================================

# ---------- 1. VPCs ----------
VPCS=$(aws_json ec2 describe-vpcs | jq '[.Vpcs[] | {
    vpc_id: .VpcId,
    cidr_block: .CidrBlock,
    additional_cidrs: [.CidrBlockAssociationSet[]? | select(.CidrBlockState.State == "associated") | .CidrBlock] | if length <= 1 then [] else .[1:] end,
    is_default: .IsDefault,
    enable_dns_support: .EnableDnsSupport,
    enable_dns_hostnames: .EnableDnsHostnames,
    tags: (.Tags // []) | map({key: .Key, value: .Value})
}]' 2>/dev/null || echo "[]")

# ---------- 2. Subnets ----------
SUBNETS=$(aws_json ec2 describe-subnets | jq '[.Subnets[] | {
    subnet_id: .SubnetId,
    vpc_id: .VpcId,
    cidr_block: .CidrBlock,
    availability_zone: .AvailabilityZone,
    availability_zone_id: .AvailabilityZoneId,
    map_public_ip_on_launch: .MapPublicIpOnLaunch,
    available_ip_count: .AvailableIpAddressCount,
    tags: (.Tags // []) | map({key: .Key, value: .Value})
}]' 2>/dev/null || echo "[]")

# ---------- 3. Route Tables ----------
ROUTE_TABLES=$(aws_json ec2 describe-route-tables | jq '[.RouteTables[] | {
    route_table_id: .RouteTableId,
    vpc_id: .VpcId,
    associations: [.Associations[]? | {
        subnet_id: .SubnetId,
        main: .Main
    }],
    routes: [.Routes[] | {
        destination: (.DestinationCidrBlock // .DestinationPrefixListId // .DestinationIpv6CidrBlock // "unknown"),
        target_type: (
            if .GatewayId != null and .GatewayId != "local" then "igw"
            elif .GatewayId == "local" then "local"
            elif .NatGatewayId != null then "nat"
            elif .TransitGatewayId != null then "tgw"
            elif .VpcPeeringConnectionId != null then "peering"
            elif .NetworkInterfaceId != null then "eni"
            elif .VpcEndpointId != null then "vpce"
            else "other"
            end
        ),
        target_id: (.GatewayId // .NatGatewayId // .TransitGatewayId // .VpcPeeringConnectionId // .NetworkInterfaceId // .VpcEndpointId // "local"),
        state: .State
    }],
    tags: (.Tags // []) | map({key: .Key, value: .Value})
}]' 2>/dev/null || echo "[]")

# ---------- 4. Security Groups ----------
SECURITY_GROUPS=$(aws_json ec2 describe-security-groups | jq '[.SecurityGroups[] | {
    group_id: .GroupId,
    group_name: .GroupName,
    vpc_id: .VpcId,
    description: .Description,
    ingress: [.IpPermissions[] | {
        protocol: .IpProtocol,
        from_port: .FromPort,
        to_port: .ToPort,
        cidr_blocks: [.IpRanges[]?.CidrIp],
        source_groups: [.UserIdGroupPairs[]?.GroupId],
        prefix_lists: [.PrefixListIds[]?.PrefixListId]
    }],
    egress: [.IpPermissionsEgress[] | {
        protocol: .IpProtocol,
        from_port: .FromPort,
        to_port: .ToPort,
        cidr_blocks: [.IpRanges[]?.CidrIp],
        source_groups: [.UserIdGroupPairs[]?.GroupId],
        prefix_lists: [.PrefixListIds[]?.PrefixListId]
    }],
    tags: (.Tags // []) | map({key: .Key, value: .Value})
}]' 2>/dev/null || echo "[]")

# ---------- 5. NAT Gateways ----------
NAT_GATEWAYS=$(aws_json ec2 describe-nat-gateways --filter "Name=state,Values=available" | jq '[.NatGateways[]? | {
    nat_gateway_id: .NatGatewayId,
    vpc_id: .VpcId,
    subnet_id: .SubnetId,
    connectivity_type: .ConnectivityType,
    addresses: [.NatGatewayAddresses[]? | {
        public_ip: .PublicIp,
        private_ip: .PrivateIp,
        allocation_id: .AllocationId
    }]
}]' 2>/dev/null || echo "[]")

# ---------- 6. Internet Gateways ----------
IGWS=$(aws_json ec2 describe-internet-gateways | jq '[.InternetGateways[]? | {
    igw_id: .InternetGatewayId,
    attachments: [.Attachments[]? | {vpc_id: .VpcId, state: .State}]
}]' 2>/dev/null || echo "[]")

# ---------- 7. VPC Endpoints ----------
VPC_ENDPOINTS=$(aws_json ec2 describe-vpc-endpoints | jq '[.VpcEndpoints[]? | {
    endpoint_id: .VpcEndpointId,
    service_name: .ServiceName,
    endpoint_type: .VpcEndpointType,
    vpc_id: .VpcId,
    state: .State,
    private_dns_enabled: .PrivateDnsEnabled,
    subnet_ids: (.SubnetIds // []),
    route_table_ids: (.RouteTableIds // []),
    security_group_ids: [.Groups[]?.GroupId],
    policy: (.PolicyDocument // null)
}]' 2>/dev/null || echo "[]")

# ---------- 8. VPC Peering ----------
VPC_PEERING=$(aws_json ec2 describe-vpc-peering-connections | jq '[.VpcPeeringConnections[]? | {
    peering_id: .VpcPeeringConnectionId,
    status: .Status.Code,
    requester: {vpc_id: .RequesterVpcInfo.VpcId, cidr: .RequesterVpcInfo.CidrBlock, owner: .RequesterVpcInfo.OwnerId, region: .RequesterVpcInfo.Region},
    accepter: {vpc_id: .AccepterVpcInfo.VpcId, cidr: .AccepterVpcInfo.CidrBlock, owner: .AccepterVpcInfo.OwnerId, region: .AccepterVpcInfo.Region}
}]' 2>/dev/null || echo "[]")

# ---------- 9. Transit Gateway Attachments ----------
TGW_ATTACHMENTS=$(aws_json ec2 describe-transit-gateway-attachments | jq '[.TransitGatewayAttachments[]? | {
    attachment_id: .TransitGatewayAttachmentId,
    tgw_id: .TransitGatewayId,
    resource_type: .ResourceType,
    resource_id: .ResourceId,
    state: .State
}]' 2>/dev/null || echo "[]")

# ---------- 10. Network ACLs ----------
NACLS=$(aws_json ec2 describe-network-acls | jq '[.NetworkAcls[]? | {
    nacl_id: .NetworkAclId,
    vpc_id: .VpcId,
    is_default: .IsDefault,
    associations: [.Associations[]?.SubnetId],
    inbound: [.Entries[] | select(.Egress == false) | {
        rule_number: .RuleNumber,
        protocol: .Protocol,
        action: .RuleAction,
        cidr: (.CidrBlock // .Ipv6CidrBlock),
        port_range: .PortRange
    }],
    outbound: [.Entries[] | select(.Egress == true) | {
        rule_number: .RuleNumber,
        protocol: .Protocol,
        action: .RuleAction,
        cidr: (.CidrBlock // .Ipv6CidrBlock),
        port_range: .PortRange
    }]
}]' 2>/dev/null || echo "[]")

# ---------- 11. DHCP Options ----------
DHCP_OPTIONS=$(aws_json ec2 describe-dhcp-options | jq '[.DhcpOptions[]? | {
    dhcp_options_id: .DhcpOptionsId,
    configurations: [.DhcpConfigurations[]? | {key: .Key, values: [.Values[].Value]}]
}]' 2>/dev/null || echo "[]")

# ---------- 12. EKS Clusters ----------
EKS_CLUSTERS="[]"
CLUSTER_NAMES=$(aws eks list-clusters --query 'clusters[]' --output text --region "$REGION" 2>/dev/null || true)
if [[ -n "$CLUSTER_NAMES" ]]; then
    EKS_JSON="["
    FIRST=true
    for CLUSTER in $CLUSTER_NAMES; do
        $FIRST || EKS_JSON+=","
        FIRST=false

        CLUSTER_INFO=$(aws_json eks describe-cluster --name "$CLUSTER")

        # Node groups
        NODEGROUPS="[]"
        NG_NAMES=$(aws eks list-nodegroups --cluster-name "$CLUSTER" --query 'nodegroups[]' --output text --region "$REGION" 2>/dev/null || true)
        if [[ -n "$NG_NAMES" ]]; then
            NG_JSON="["
            NG_FIRST=true
            for NG in $NG_NAMES; do
                $NG_FIRST || NG_JSON+=","
                NG_FIRST=false
                NG_JSON+=$(aws_json eks describe-nodegroup --cluster-name "$CLUSTER" --nodegroup-name "$NG" | jq '{
                    name: .nodegroup.nodegroupName,
                    status: .nodegroup.status,
                    instance_types: .nodegroup.instanceTypes,
                    ami_type: .nodegroup.amiType,
                    disk_size: .nodegroup.diskSize,
                    scaling: .nodegroup.scalingConfig,
                    subnets: .nodegroup.subnets,
                    node_role_arn: .nodegroup.nodeRole,
                    launch_template: .nodegroup.launchTemplate,
                    labels: (.nodegroup.labels // {}),
                    taints: (.nodegroup.taints // [])
                }' 2>/dev/null || echo 'null')
            done
            NODEGROUPS="${NG_JSON}]"
        fi

        # Addons
        ADDONS="[]"
        ADDON_NAMES=$(aws eks list-addons --cluster-name "$CLUSTER" --query 'addons[]' --output text --region "$REGION" 2>/dev/null || true)
        if [[ -n "$ADDON_NAMES" ]]; then
            ADDON_JSON="["
            ADDON_FIRST=true
            for ADDON in $ADDON_NAMES; do
                $ADDON_FIRST || ADDON_JSON+=","
                ADDON_FIRST=false
                ADDON_JSON+=$(aws_json eks describe-addon --cluster-name "$CLUSTER" --addon-name "$ADDON" | jq '{
                    name: .addon.addonName,
                    version: .addon.addonVersion,
                    status: .addon.status,
                    service_account_role_arn: .addon.serviceAccountRoleArn,
                    configuration_values: .addon.configurationValues
                }' 2>/dev/null || echo 'null')
            done
            ADDONS="${ADDON_JSON}]"
        fi

        # OIDC
        OIDC_ISSUER=$(echo "$CLUSTER_INFO" | jq -r '.cluster.identity.oidc.issuer // empty' 2>/dev/null)
        OIDC_REGISTERED=false
        if [[ -n "$OIDC_ISSUER" ]]; then
            OIDC_HOST=$(echo "$OIDC_ISSUER" | sed 's|https://||')
            PROVIDERS=$(aws iam list-open-id-connect-providers --output json 2>/dev/null || echo '{}')
            if echo "$PROVIDERS" | jq -r '.OpenIDConnectProviderList[]?.Arn' 2>/dev/null | grep -qF "$OIDC_HOST"; then
                OIDC_REGISTERED=true
            fi
        fi

        # Pod Identity Associations
        POD_ID=$(aws_json eks list-pod-identity-associations --cluster-name "$CLUSTER" | jq '[.associations[]? | {
            namespace: .namespace,
            service_account: .serviceAccount,
            association_arn: .associationArn
        }]' 2>/dev/null || echo "[]")

        # Access entries
        ACCESS_ENTRIES=$(aws_json eks list-access-entries --cluster-name "$CLUSTER" | jq '.accessEntries // []' 2>/dev/null || echo "[]")

        EKS_JSON+=$(echo "$CLUSTER_INFO" | jq --argjson nodegroups "$NODEGROUPS" \
            --argjson addons "$ADDONS" \
            --argjson oidc_registered "$OIDC_REGISTERED" \
            --argjson pod_identity "$POD_ID" \
            --argjson access_entries "$ACCESS_ENTRIES" '{
            name: .cluster.name,
            version: .cluster.version,
            platform_version: .cluster.platformVersion,
            status: .cluster.status,
            role_arn: .cluster.roleArn,
            endpoint: .cluster.endpoint,
            endpoint_public_access: .cluster.resourcesVpcConfig.endpointPublicAccess,
            endpoint_private_access: .cluster.resourcesVpcConfig.endpointPrivateAccess,
            public_access_cidrs: .cluster.resourcesVpcConfig.publicAccessCidrs,
            vpc_id: .cluster.resourcesVpcConfig.vpcId,
            subnet_ids: .cluster.resourcesVpcConfig.subnetIds,
            security_group_ids: .cluster.resourcesVpcConfig.securityGroupIds,
            cluster_security_group_id: .cluster.resourcesVpcConfig.clusterSecurityGroupId,
            service_ipv4_cidr: .cluster.kubernetesNetworkConfig.serviceIpv4Cidr,
            ip_family: .cluster.kubernetesNetworkConfig.ipFamily,
            oidc_issuer: .cluster.identity.oidc.issuer,
            oidc_registered_in_iam: $oidc_registered,
            encryption_config: .cluster.encryptionConfig,
            logging: .cluster.logging,
            node_groups: $nodegroups,
            addons: $addons,
            pod_identity_associations: $pod_identity,
            access_entries: $access_entries,
            tags: (.cluster.tags // {})
        }' 2>/dev/null || echo 'null')
    done
    EKS_CLUSTERS="${EKS_JSON}]"
fi

# ---------- 13. ECR Repositories ----------
ECR_REPOS=$(aws_json ecr describe-repositories | jq '[.repositories[]? | {
    name: .repositoryName,
    uri: .repositoryUri,
    arn: .repositoryArn,
    image_tag_mutability: .imageTagMutability,
    scan_on_push: .imageScanningConfiguration.scanOnPush,
    encryption_type: .encryptionConfiguration.encryptionType,
    kms_key: .encryptionConfiguration.kmsKey
}]' 2>/dev/null || echo "[]")

# ---------- 14. IAM Role (caller) ----------
IAM_ROLE="null"
ROLE_NAME=""
if [[ "$CALLER_ARN" == *":assumed-role/"* ]]; then
    ROLE_NAME=$(echo "$CALLER_ARN" | sed 's|.*:assumed-role/||' | cut -d/ -f1)
elif [[ "$CALLER_ARN" == *":role/"* ]]; then
    ROLE_NAME=$(basename "$(echo "$CALLER_ARN" | sed 's|.*:role/||')")
fi

if [[ -n "$ROLE_NAME" ]]; then
    ROLE_INFO=$(aws_json iam get-role --role-name "$ROLE_NAME")
    ATTACHED=$(aws_json iam list-attached-role-policies --role-name "$ROLE_NAME" | jq '[.AttachedPolicies[]? | {name: .PolicyName, arn: .PolicyArn}]' 2>/dev/null || echo "[]")
    INLINE_NAMES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[]' --output text 2>/dev/null || true)
    INLINE_POLICIES="[]"
    if [[ -n "$INLINE_NAMES" ]]; then
        IP_JSON="["
        IP_FIRST=true
        for POL in $INLINE_NAMES; do
            $IP_FIRST || IP_JSON+=","
            IP_FIRST=false
            IP_JSON+=$(aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$POL" --output json 2>/dev/null | jq '{name: .PolicyName, document: .PolicyDocument}' || echo 'null')
        done
        INLINE_POLICIES="${IP_JSON}]"
    fi

    BOUNDARY_ARN=$(echo "$ROLE_INFO" | jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // empty' 2>/dev/null)
    BOUNDARY_DOC="null"
    if [[ -n "$BOUNDARY_ARN" ]]; then
        DEFAULT_VER=$(aws iam get-policy --policy-arn "$BOUNDARY_ARN" --query 'Policy.DefaultVersionId' --output text 2>/dev/null || true)
        if [[ -n "$DEFAULT_VER" ]]; then
            BOUNDARY_DOC=$(aws iam get-policy-version --policy-arn "$BOUNDARY_ARN" --version-id "$DEFAULT_VER" --query 'PolicyVersion.Document' --output json 2>/dev/null || echo "null")
        fi
    fi

    IAM_ROLE=$(echo "$ROLE_INFO" | jq --argjson attached "$ATTACHED" \
        --argjson inline "$INLINE_POLICIES" \
        --argjson boundary_doc "$BOUNDARY_DOC" \
        --arg boundary_arn "${BOUNDARY_ARN:-null}" '{
        role_name: .Role.RoleName,
        role_arn: .Role.Arn,
        path: .Role.Path,
        max_session_duration: .Role.MaxSessionDuration,
        trust_policy: .Role.AssumeRolePolicyDocument,
        permissions_boundary_arn: (if $boundary_arn == "null" then null else $boundary_arn end),
        permissions_boundary_document: $boundary_doc,
        attached_policies: $attached,
        inline_policies: $inline
    }' 2>/dev/null || echo "null")
fi

# ---------- 15. OIDC Providers ----------
OIDC_PROVIDERS=$(aws iam list-open-id-connect-providers --output json 2>/dev/null | jq '[.OpenIDConnectProviderList[]? | .Arn]' || echo "[]")

# ---------- 16. S3 Buckets ----------
S3_BUCKETS=$(aws s3api list-buckets --output json 2>/dev/null | jq '[.Buckets[]? | {name: .Name, created: .CreationDate}]' || echo "[]")

# ---------- 17. Availability Zones ----------
AZS=$(aws_json ec2 describe-availability-zones | jq '[.AvailabilityZones[]? | {
    zone_name: .ZoneName,
    zone_id: .ZoneId,
    state: .State,
    region_name: .RegionName
}]' 2>/dev/null || echo "[]")

# ============================================================
# Assemble the final JSON document
# ============================================================
jq -n \
    --arg snapshot_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg source_region "$REGION" \
    --arg source_partition "$PARTITION" \
    --arg source_account "$ACCOUNT" \
    --arg caller_arn "$CALLER_ARN" \
    --arg instance_id "$INSTANCE_ID" \
    --arg instance_type "$INSTANCE_TYPE" \
    --arg ami_id "$AMI_ID" \
    --arg az "$AZ" \
    --arg private_ip "$PRIVATE_IP" \
    --arg instance_vpc "$INSTANCE_VPC" \
    --arg instance_subnet "$INSTANCE_SUBNET" \
    --argjson vpcs "$VPCS" \
    --argjson subnets "$SUBNETS" \
    --argjson route_tables "$ROUTE_TABLES" \
    --argjson security_groups "$SECURITY_GROUPS" \
    --argjson nat_gateways "$NAT_GATEWAYS" \
    --argjson internet_gateways "$IGWS" \
    --argjson vpc_endpoints "$VPC_ENDPOINTS" \
    --argjson vpc_peering "$VPC_PEERING" \
    --argjson tgw_attachments "$TGW_ATTACHMENTS" \
    --argjson nacls "$NACLS" \
    --argjson dhcp_options "$DHCP_OPTIONS" \
    --argjson eks_clusters "$EKS_CLUSTERS" \
    --argjson ecr_repositories "$ECR_REPOS" \
    --argjson iam_role "$IAM_ROLE" \
    --argjson oidc_providers "$OIDC_PROVIDERS" \
    --argjson s3_buckets "$S3_BUCKETS" \
    --argjson availability_zones "$AZS" \
'{
    _metadata: {
        schema_version: "1.0",
        snapshot_time: $snapshot_time,
        purpose: "Digital twin provisioning — replicate C1 GovCloud topology in commercial AWS",
        source: {
            region: $source_region,
            partition: $source_partition,
            account_id: $source_account,
            caller_arn: $caller_arn
        },
        collector_instance: {
            instance_id: $instance_id,
            instance_type: $instance_type,
            ami_id: $ami_id,
            availability_zone: $az,
            private_ip: $private_ip,
            vpc_id: $instance_vpc,
            subnet_id: $instance_subnet
        },
        twin_mapping_notes: {
            region: "Map us-gov-west-1 → us-east-1 (or target commercial region)",
            partition: "Map aws-us-gov → aws (ARN prefixes, service endpoints)",
            oidc: "EKS OIDC issuer hostnames change with region — re-register after cluster creation",
            vpc_endpoints: "Replicate all endpoints — twin must also be airgapped (no IGW/NAT)",
            gitlab_punch_through: "Simulate with a peered VPC or VPN hosting a GitLab CE instance",
            permissions_boundary: "Replicate boundary policy document to enforce same IAM constraints",
            ecr: "Mirror repository names — image content is handled by airgap-bundler"
        }
    },
    network: {
        vpcs: $vpcs,
        subnets: $subnets,
        route_tables: $route_tables,
        security_groups: $security_groups,
        nat_gateways: $nat_gateways,
        internet_gateways: $internet_gateways,
        vpc_endpoints: $vpc_endpoints,
        vpc_peering: $vpc_peering,
        transit_gateway_attachments: $tgw_attachments,
        network_acls: $nacls,
        dhcp_options: $dhcp_options,
        availability_zones: $availability_zones
    },
    eks: $eks_clusters,
    ecr: {
        repositories: $ecr_repositories
    },
    iam: {
        caller_role: $iam_role,
        oidc_providers: $oidc_providers
    },
    s3: {
        buckets: $s3_buckets
    }
}'
