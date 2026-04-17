# First Recon Run — Friday April 17, 2026

Driver's guide for today's session. Follow these steps top-to-bottom.
Estimated time: **45–60 minutes total** (mostly waiting on pipeline jobs).

---

## What We're Doing Today

1. Register the GitLab runner on a GovCloud EC2 *(~10 min)*
2. Verify it shows online in LevelUp *(~2 min)*
3. Run the `preflight` job — confirm tools + AWS creds *(~2 min)*
4. Run the `recon` job — full 13-script diagnostic sweep *(~15 min)*
5. Run the `export-twin` job — JSON environment snapshot *(~5 min)*
6. Download and stash the artifacts

That's it. No code changes today. Pure execution.

---

## Pre-Session Checklist

Before you RDP in, confirm:

- [ ] RDP credentials for a GovCloud EC2 that has outbound HTTPS to `code.levelup.cce.af.mil`
- [ ] That EC2 has the AWS CLI v2 available (or an instance profile that provides credentials)
- [ ] You have a browser open to: `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon`
- [ ] You're logged into LevelUp as `cwilson613` (or ask Chris)

---

## Step 1 — RDP in and Get the Script onto the EC2

Once you're on the GovCloud EC2:

```bash
# Option A: Clone directly (if the EC2 can reach code.levelup.cce.af.mil)
git clone https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon.git
cd c1-recon
```

```bash
# Option B: If git clone fails, grab just the setup script via curl
curl -sk https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/raw/main/setup-runner.sh \
  -o setup-runner.sh
chmod +x setup-runner.sh
```

```bash
# Option C: If the EC2 can't reach LevelUp at all — transfer via S3
# (Run this from your local machine or a connected jumpbox first)
curl -sk https://raw.githubusercontent.com/recro/c1-recon/main/setup-runner.sh \
  -o setup-runner.sh
aws s3 cp setup-runner.sh s3://hncd-airgap-transfer/tools/setup-runner.sh

# Then on the EC2:
aws s3 cp s3://hncd-airgap-transfer/tools/setup-runner.sh setup-runner.sh
chmod +x setup-runner.sh
```

**✓ Done when:** `setup-runner.sh` is on the EC2 and executable.

---

## Step 2 — Run the Setup Script

```bash
sudo ./setup-runner.sh
```

**What you'll see:**

```
[INFO]  === c1-recon GitLab Runner Setup ===
[INFO]  Host:        ip-10-x-x-x
[INFO]  Runner name: c1-recon-airgapped-ip-10-x-x-x
...
[INFO]  Step 1: Installing required tools
[INFO]  Required tools already present
...
[INFO]  Step 2: Installing GitLab Runner
[INFO]  gitlab-runner installed: version 17.x.x
...
[INFO]  Step 3: Registering runner with LevelUp GitLab
[INFO]  Runner registered
...
[INFO]  Step 4: Starting gitlab-runner service
[INFO]  gitlab-runner service: ACTIVE
...
[INFO]  Step 5: Verifying AWS credentials
[INFO]  AWS identity confirmed:
          Account: 123456789012
          User/Role: arn:aws-us-gov:sts::...
...
[INFO]  === Setup complete ===
```

**If you see errors:**

| Error | Fix |
|-------|-----|
| `aws cli not found` | Install aws cli v2 first: `sudo ./install-awscli.sh` or via S3 (see `DEPLOYMENT_PLAN.md` fallback) |
| `gitlab-runner install failed` | packages.gitlab.com unreachable — use the [manual binary fallback](#appendix-manual-gitlab-runner-install) below |
| `AWS identity failed` | Instance profile may be missing — check IAM role attached to EC2; scripts will still run but AWS calls will fail |
| `systemctl: not found` | Non-systemd host — run `gitlab-runner run &` manually instead |

**✓ Done when:** Script exits with `gitlab-runner service: ACTIVE` and AWS identity is confirmed.

---

## Step 3 — Verify Runner Shows Online in LevelUp

1. Open: `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/settings/ci_cd`
2. Expand **Runners**
3. Find **`c1-recon-airgapped-<hostname>`** — it should show a **green dot** (online)

**If it shows offline/red:**
```bash
# On the EC2 — check service status
sudo systemctl status gitlab-runner
sudo journalctl -u gitlab-runner -n 50

# If it's running but showing offline in GitLab, wait 60s and refresh —
# it polls every 30 seconds
```

**✓ Done when:** Green dot next to the runner in the GitLab UI.

---

## Step 4 — Run the Preflight Job

1. Go to: `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/pipelines`
2. Click **Run pipeline** (blue button, top right)
3. Branch: `main` → click **Run pipeline**
4. The `preflight` job starts automatically — click it to watch live output

**What you're looking for:**
```
  bash            [OK] /bin/bash
  aws             [OK] /usr/local/bin/aws
  jq              [OK] /usr/bin/jq
  curl            [OK] /usr/bin/curl
  openssl         [OK] /usr/bin/openssl

Optional tools:
  kubectl         [not available]     ← OK for today, note it
  helm            [not available]     ← OK for today
  dig             [OK]
  ...

Preflight passed.
```

**If preflight fails on missing tools:**
```bash
# On the EC2
sudo dnf install -y jq bind-utils openssl curl
sudo systemctl restart gitlab-runner
```
Then re-run the pipeline.

**Note on kubectl:** If not available, scripts 07 (EKS), 10 (Palette), and 12 (ImageSwap pod checks) will skip their Kubernetes sections. The AWS API sections still run. Note whether kubectl is present — we may want to configure it on a second pass.

**✓ Done when:** Preflight job shows ✅ green.

---

## Step 5 — Run the Recon Job

1. In the same pipeline, click the **▶ play button** next to the `recon` job (it's manual — won't auto-start)
2. Watch the live output — it runs scripts 01 through 12 sequentially
3. **Expected runtime: 10–15 minutes**

**What to watch for during the run:**

| Script | Key signal |
|--------|-----------|
| `01-identity.sh` | Confirms which role/account we're in |
| `02-iam-boundaries.sh` | Shows the permissions boundary policy — lots of DENYs is expected and informative |
| `04-network-egress.sh` | Can we reach LevelUp? Any other egress? |
| `05-dns-resolution.sh` | **Does `oidc.eks.us-gov-west-1.amazonaws.com` resolve?** This is the CAPA blocker question |
| `08-vpc-environment.sh` | Lists VPC endpoints — note any gaps (S3, ECR, STS, etc.) |
| `10-spectro-readiness.sh` | Palette pre-flight — expect several WARN items |

Individual scripts that fail or show WARNs do **not** fail the pipeline — that's by design.

**✓ Done when:** `recon` job completes (green or yellow — yellow is fine).

---

## Step 6 — Run the Export Twin Job

1. In the same pipeline, click the **▶ play button** next to `export-twin`
2. **Expected runtime: 3–5 minutes**
3. When done, the job log shows a summary like:
   ```
   {
     "vpcs": 2,
     "subnets": 8,
     "security_groups": 15,
     "vpc_endpoints": 12,
     "eks_clusters": 2,
     "ecr_repos": 47,
     "s3_buckets": 6
   }
   ```

**✓ Done when:** `export-twin` job completes green.

---

## Step 7 — Download the Artifacts

1. Go to the completed `recon` job page
2. Click **Browse** (artifacts section, right side) or **Download**
3. Grab:
   - `script-outputs/` directory — individual `.txt` files per script
   - `recon-report-<timestamp>.txt` — combined human-readable report
4. Go to the completed `export-twin` job page
5. Download `twin-snapshot-<timestamp>.json`

**Stash the artifacts** locally and share:
- Full report → Chris + William for review
- Script 10 output (`10-spectro-readiness.txt`) → Tommy Scherer / Will Crum (SpectroCloud)
- Script 05 output (`05-dns-resolution.txt`) → Marcus (OIDC DNS question)
- Twin JSON → keep internal for now (contains real ARNs/account IDs)

---

## Step 8 — Enable Weekly Schedule (while you're in there)

1. Go to: **CI/CD → Schedules → New schedule**
2. Fill in:
   - Description: `Weekly c1-recon baseline`
   - Interval: `0 6 * * 1`  *(Monday 06:00 UTC = 02:00 EST)*
   - Target branch: `main`
3. Add variable: `SCHEDULED_RUN` = `true`
4. Save and activate

**✓ Done when:** Schedule shows active with next run date.

---

## Done — What to Note

Take a quick note on whatever you observe for the WAR and team sync:

- [ ] Runner hostname / EC2 instance it's on
- [ ] kubectl present or not?
- [ ] AWS identity (which role / account)
- [ ] OIDC DNS — did `oidc.eks.us-gov-west-1.amazonaws.com` resolve? (script 05)
- [ ] VPC endpoint count (from twin export summary above)
- [ ] EKS cluster count
- [ ] Any unexpected blockers

---

## Appendix: Manual gitlab-runner Install

If `packages.gitlab.com` is unreachable from inside GovCloud:

```bash
# From a connected machine — download and stage in S3
curl -LO "https://gitlab-ci-multi-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64"
aws s3 cp gitlab-runner-linux-amd64 s3://hncd-airgap-transfer/tools/gitlab-runner-linux-amd64

# On the GovCloud EC2
aws s3 cp s3://hncd-airgap-transfer/tools/gitlab-runner-linux-amd64 /tmp/gitlab-runner
sudo install -m 755 /tmp/gitlab-runner /usr/local/bin/gitlab-runner

# Register manually (token pre-issued, no expiry)
sudo gitlab-runner register \
  --non-interactive \
  --url "https://code.levelup.cce.af.mil" \
  --token "glrt-1MW4BbRbqQIEWSskqtKxG286MQpwOnpragp0OjMKdTpraGMT.01.1c1624b2p" \
  --name "c1-recon-airgapped-$(hostname -s)" \
  --executor "shell" \
  --tag-list "airgapped" \
  --run-untagged "false" \
  --tls-skip-verify "true"

sudo gitlab-runner install
sudo gitlab-runner start
```
