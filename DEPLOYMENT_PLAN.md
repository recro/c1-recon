# c1-recon Deployment Plan

## Objective

Deploy the c1-recon diagnostic suite on the HNCD CloudOne GovCloud environment via the existing LevelUp GitLab CI/CD infrastructure. Collect the first baseline recon report and digital twin snapshot, then enable weekly scheduled runs for drift detection.

## Prerequisites

| Requirement | Status | Owner |
|-------------|--------|-------|
| c1-recon repo exists on LevelUp GitLab | Done | Recro |
| `.gitlab-ci.yml` committed with airgapped runner pipeline | Done | Recro |
| RDP access to GovCloud environment | Available | Chris Wilson |
| Airgapped shell runner registered with `airgapped` tag | Exists (used by airgap-bundler) | HNCD |
| Runner has: bash, aws cli v2, jq, curl, openssl | Verify in Step 1 | HNCD |
| Runner has valid AWS credentials (instance profile or env) | Verify in Step 1 | HNCD |
| kubectl configured with EKS cluster access (optional) | Verify in Step 1 | HNCD |

## Step 1: Verify Runner Eligibility

From the LevelUp GitLab UI or via RDP:

1. Navigate to `siem-devgroup/siem/c1-recon` → CI/CD → Pipelines → Run pipeline
2. Run the pipeline on `main` — the `preflight` job triggers automatically
3. Review preflight output:
   - Required tools present (bash, aws, jq, curl, openssl)
   - Optional tools inventory (kubectl, helm, dig — note what's missing)
   - AWS identity confirmed (`sts:GetCallerIdentity` succeeds)
4. If preflight fails, install missing tools on the runner host:
   ```bash
   # On the runner EC2 instance (AL2023)
   sudo dnf install -y jq bind-utils openssl curl
   ```

**Decision point:** If kubectl is not available, scripts 07 (EKS cluster), 10 (Palette readiness sections 6-8), and 12 (ImageSwap webhook/pod checks) will skip their Kubernetes-dependent sections. The AWS API sections still run. Determine if kubectl + kubeconfig should be configured on the runner for full coverage.

## Step 2: First Manual Recon Run

1. In the pipeline UI, click the play button on the `recon` job
2. Monitor job output — expect 10-15 minutes for full run (13 scripts, 5-min timeout each)
3. When complete, download artifacts from the job page:
   - `script-outputs/` directory with per-script `.txt` files
   - `recon-report-<timestamp>.txt` combined report
4. Review the report for:
   - Which IAM actions are DENIED (02, 03) — this maps the permissions boundary
   - Which VPC endpoints are PRESENT vs MISSING (08) — this is the airgap surface
   - Whether `oidc.eks.us-gov-west-1.amazonaws.com` resolves (05) — the CAPA blocker
   - EKS cluster config and OIDC registration status (07)
   - ECR repo inventory and ImageSwap classification (09, 12)
   - GitLab punch-through connectivity (04, 05, 06)

## Step 3: First Twin Export

1. Click the play button on the `export-twin` job
2. Download the `twin-snapshot-<timestamp>.json` artifact
3. Validate the JSON:
   ```bash
   jq '._metadata' twin-snapshot-*.json          # Verify metadata
   jq '.network.vpc_endpoints | length' twin-snapshot-*.json  # Count VPC endpoints
   jq '.eks | length' twin-snapshot-*.json        # Count EKS clusters
   ```
4. Store the snapshot — this is the input for the commercial AWS digital twin build

## Step 4: Review and Share Results

1. Review the recon report with the team (Chris, William)
2. Share relevant sections with HNCD (Marcus Gales):
   - VPC endpoint coverage gaps
   - DNS resolution results for OIDC
   - IAM permissions boundary findings
3. Share with SpectroCloud SE (Tommy Scherer, Will Crum):
   - Script 10 output (Palette readiness)
   - Script 12 output (ImageSwap validation)
   - ECR repo classification from script 09
4. File action items for any blockers discovered

## Step 5: Enable Scheduled Runs

Once the first manual run is validated:

1. Navigate to CI/CD → Schedules → New schedule
2. Configure:
   - Description: `Weekly c1-recon baseline`
   - Interval pattern: `0 6 * * 1` (Monday 0600 UTC / 0100 EST)
   - Target branch: `main`
   - Variables: `SCHEDULED_RUN` = `true`
3. Save and activate
4. The `scheduled-recon` job runs both the diagnostic report and twin export automatically
5. Artifacts retained for 90 days — compare week-over-week for drift

## Step 6: Digital Twin Build (Subsequent)

Using the twin snapshot JSON, provision the commercial AWS replica:

1. Translate region (`us-gov-west-1` → `us-east-1`) and partition (`aws-us-gov` → `aws`)
2. Terraform the network layer: VPCs, subnets, route tables, security groups, NACLs
3. Create matching VPC endpoints (the airgap simulation)
4. Stand up EKS with same version, endpoint config, addons, node group sizing
5. Create ECR repos matching the spectro-images/spectro-packs structure
6. Replicate the permissions boundary policy document
7. Simulate GitLab punch-through with a peered VPC running GitLab CE
8. Run c1-recon against the twin to validate parity

## Risk Register

| Risk | Impact | Mitigation |
|------|--------|------------|
| Runner lacks kubectl/kubeconfig | Scripts 07, 10, 12 skip K8s checks | Configure kubeconfig or accept API-only data |
| Permissions boundary blocks IAM enumeration | Scripts 02, 03 show DENIED — that's data, not failure | Use empirical probe results to map boundary |
| IMDS restricted on runner (IMDSv2 hop limit) | Script 01 shows [unavailable] for instance metadata | Falls back to AWS CLI region/identity — non-blocking |
| ECR describe-repositories throttled | Script 09 rate-limited on large repo count | Built-in sleep + sample cap (30 repos) |
| Pipeline schedule misses due to runner offline | No weekly baseline collected | Monitor schedule history; alert on missed runs |
| Twin snapshot contains real account IDs/ARNs | Sensitive if shared broadly | Review before distribution; sanitize for external use |

## Timeline

| When | What |
|------|------|
| Day 1 (first RDP session) | Steps 1-3: preflight, first recon, first twin export |
| Day 1-2 | Step 4: review with team, share with HNCD and SpectroCloud |
| Day 2 | Step 5: enable weekly schedule |
| Week 2+ | Step 6: begin digital twin provisioning from snapshot |
