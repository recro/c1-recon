# CloudOne GovCloud Reconnaissance Scripts

Diagnostic scripts designed to run from a deployed EC2 instance inside the HNCD CloudOne (GovCloud) environment. Each script is self-contained and outputs structured results to help map the environment's IAM, networking, DNS, and service boundaries.

## Running Today?

→ **[sessions/2026-04-17-first-recon.md](sessions/2026-04-17-first-recon.md)** — Step-by-step driver's guide for the April 17 session (runner registration + first recon run + twin export). Start here.

For the full deployment plan and ongoing ops, see [DEPLOYMENT_PLAN.md](DEPLOYMENT_PLAN.md).

---

## Environment Assumptions

- **Airgapped** — no internet egress whatsoever
- **AWS services** via VPC interface endpoints (PrivateLink) only
- **Dedicated punch-through** to LevelUp GitLab (`code.levelup.cce.af.mil`) for CI/CD
- **Region**: `us-gov-west-1` (auto-detected from instance metadata)

## Prerequisites

- AWS CLI v2 installed and configured (instance profile or environment credentials)
- `jq` installed (most AL2023 AMIs include it)
- `curl`, `dig`/`nslookup`, `openssl` available
- Run as `ec2-user` or equivalent (some checks note when root is needed)

## Scripts

| Script | Purpose |
|--------|---------|
| `00-run-all.sh` | Orchestrator — runs all diagnostic scripts, collects output into timestamped report |
| `01-identity.sh` | Who am I? STS caller identity, instance metadata, attached roles |
| `02-iam-boundaries.sh` | Permissions boundary detection, effective policy enumeration |
| `03-iam-capabilities.sh` | Probe ~40 read-only API calls to determine effective permissions |
| `04-network-egress.sh` | Egress model detection: VPC endpoints, GitLab connectivity, proxy config |
| `05-dns-resolution.sh` | DNS resolution tests for critical AWS service + GitLab endpoints |
| `06-endpoint-reachability.sh` | HTTPS/TLS connectivity to AWS services, GitLab punch-through, OIDC |
| `07-eks-cluster.sh` | EKS cluster details, OIDC provider config, node groups, addons |
| `08-vpc-environment.sh` | VPC topology, subnets, route tables, security groups, VPC endpoint inventory |
| `09-ecr-access.sh` | ECR auth, ImageSwap-aware repo classification, source registry breakdown |
| `10-spectro-readiness.sh` | SpectroCloud Palette/VerteX deployment readiness (IAM limits, subnet tags, Pod Identity, tooling) |
| `11-export-twin.sh` | **Export structured JSON snapshot for digital twin provisioning** |
| `12-imageswap-validation.sh` | ImageSwap mutating webhook health, swap map config, ECR mutation chain, pod verification |

## Usage

```bash
# Copy to EC2 instance
scp -r c1-recon/ ec2-user@<instance>:~/recon/

# Run all diagnostic scripts (human-readable report)
chmod +x ~/recon/*.sh
cd ~/recon && ./00-run-all.sh

# Run individual scripts
./01-identity.sh
./05-dns-resolution.sh

# Export environment snapshot for digital twin (machine-parseable JSON)
./11-export-twin.sh > twin-snapshot-$(date -u +%Y%m%d).json
```

## Output

**Diagnostic report** (`00-run-all.sh`): Human-readable text with section headers, teed to `recon-report-<timestamp>.txt`.

**Twin snapshot** (`11-export-twin.sh`): Single JSON document to stdout containing the full environment topology. Pipe to a file:

```
twin-snapshot-20260416.json
├── _metadata          # Snapshot time, source region/account, mapping notes
│   └── twin_mapping_notes  # Region translation, ARN prefix, endpoint guidance
├── network
│   ├── vpcs           # CIDR blocks, DNS settings, tags
│   ├── subnets        # AZ placement, CIDR, public IP mapping, tags
│   ├── route_tables   # Routes with target type classification (igw/nat/tgw/vpce/local)
│   ├── security_groups # Full ingress/egress rules with CIDR, SG refs, prefix lists
│   ├── nat_gateways   # (expected empty in airgap)
│   ├── internet_gateways  # (expected empty in airgap)
│   ├── vpc_endpoints  # Service name, type, private DNS, subnet/SG associations
│   ├── vpc_peering    # Cross-VPC/cross-account peering
│   ├── transit_gateway_attachments
│   ├── network_acls   # Inbound/outbound rules by subnet
│   └── dhcp_options   # DNS servers, domain name
├── eks[]              # Per-cluster:
│   ├── version, endpoint, access config
│   ├── node_groups[]  # Instance types, AMI type, scaling, subnets, role ARN
│   ├── addons[]       # Name, version, SA role ARN
│   ├── oidc_issuer + oidc_registered_in_iam
│   ├── pod_identity_associations[]
│   └── access_entries[]
├── ecr
│   └── repositories[] # Name, URI, tag mutability, encryption
├── iam
│   ├── caller_role    # Trust policy, boundary ARN + document, attached + inline policies
│   └── oidc_providers[]
└── s3
    └── buckets[]
```

### Using the Twin Snapshot

The JSON maps directly to Terraform resources. To build a commercial AWS replica:

1. **Region translation**: `us-gov-west-1` → target commercial region. Update all ARN prefixes from `aws-us-gov` → `aws`.
2. **Network**: Reproduce VPCs, subnets (same CIDR layout), route tables (no IGW/NAT — VPC endpoints only), security groups, NACLs.
3. **VPC endpoints**: Create the same set of interface/gateway endpoints. This is the core of the airgap simulation.
4. **EKS**: Create cluster with same version, endpoint access config, addons, node group sizing. Register OIDC provider in IAM.
5. **IAM**: Reproduce the permissions boundary document and attached policies. This is critical for testing what Palette can/can't do.
6. **ECR**: Create the same repository names (content populated by airgap-bundler).
7. **GitLab punch-through**: Simulate with a peered VPC or VPN hosting a GitLab CE instance.

## Notes

- All scripts are **read-only** — they do not create, modify, or delete any AWS resources
- Some IAM enumeration calls may be denied by permissions boundaries — that denial itself is diagnostic data
- `11-export-twin.sh` captures real account IDs and ARNs (needed for accurate modeling) — review before sharing outside the team
