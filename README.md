# CloudOne GovCloud Reconnaissance Scripts

Diagnostic scripts designed to run from a deployed EC2 instance inside the HNCD CloudOne (GovCloud) environment. Each script is self-contained and outputs structured results to help map the environment's IAM, networking, DNS, and service boundaries.

## Prerequisites

- AWS CLI v2 installed and configured (instance profile or environment credentials)
- `jq` installed (most AL2023 AMIs include it)
- `curl`, `dig`/`nslookup`, `openssl` available
- Run as `ec2-user` or equivalent (some checks note when root is needed)

## Scripts

| Script | Purpose |
|--------|---------|
| `00-run-all.sh` | Orchestrator — runs all scripts, collects output into timestamped report |
| `01-identity.sh` | Who am I? STS caller identity, instance metadata, attached roles |
| `02-iam-boundaries.sh` | Permissions boundary detection, effective policy enumeration |
| `03-iam-capabilities.sh` | Probe specific IAM actions (CreateOIDCProvider, AssumeRole, etc.) |
| `04-network-egress.sh` | Egress model detection: NAT, proxy, direct, VPC endpoints |
| `05-dns-resolution.sh` | DNS resolution tests for critical AWS service endpoints |
| `06-endpoint-reachability.sh` | HTTPS connectivity to AWS service endpoints (EKS, ECR, STS, S3, OIDC) |
| `07-eks-cluster.sh` | EKS cluster details, OIDC provider config, node group info |
| `08-vpc-environment.sh` | VPC, subnet, route table, security group enumeration |
| `09-ecr-access.sh` | ECR authentication test, repository listing, image pull test |
| `10-spectro-readiness.sh` | SpectroCloud Palette/VerteX deployment readiness (IAM limits, subnet tags, addons, Pod Identity, tooling) |

## Usage

```bash
# Copy to EC2 instance
scp -r scripts/c1-recon/ ec2-user@<instance>:~/recon/

# Run everything
chmod +x ~/recon/*.sh
cd ~/recon && ./00-run-all.sh

# Or run individual scripts
./01-identity.sh
./05-dns-resolution.sh
```

## Output

Each script writes to stdout with section headers. `00-run-all.sh` tees all output to `recon-report-<timestamp>.txt` in the current directory.

## Notes

- These scripts are **read-only** — they do not create, modify, or delete any AWS resources
- Some IAM enumeration calls may be denied by permissions boundaries — that denial itself is diagnostic data
- Designed for `us-gov-west-1` but region is auto-detected from instance metadata
