# First Recon Run — Friday April 17, 2026

Driver's guide for today's session. Follow these steps top-to-bottom.
Estimated time: **45–60 minutes total** (mostly waiting on pipeline jobs).

---

## What We're Doing Today

1. Get onto the right EC2 and register the GitLab runner *(~10 min)*
2. Confirm the runner shows online in LevelUp *(~2 min)*
3. Trigger and watch the `preflight` job — confirms tools + AWS creds *(~2 min)*
4. Trigger and watch the `recon` job — 13-script diagnostic sweep *(~15 min)*
5. Trigger and watch the `export-twin` job — JSON environment snapshot *(~5 min)*
6. Download and stash the artifacts *(~5 min)*
7. Enable the weekly schedule *(~2 min)*

No code changes today. Pure execution.

---

## Pre-Session Checklist

Before you do anything else, confirm you have:

- [ ] **The EC2 to use.** You need an EC2 inside the C1 GovCloud VPC that can reach `code.levelup.cce.af.mil` over HTTPS. If you don't know which one, ask Marcus Gales — he'll give you an IP or hostname and login credentials.
- [ ] **RDP access** to that EC2 (or SSH — either works).
- [ ] A browser tab open and logged into LevelUp:
  `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon`
  Log in as `cwilson613`. If you don't have credentials, ask Chris Wilson.
- [ ] **Maintainer role** on the c1-recon project — needed to see the runners settings page in Step 3. `cwilson613` already has this. If you're using a different account, ask Chris to grant it.

---

## Step 1 — Get onto the EC2 and Open a Terminal

**If accessing via RDP (Windows desktop on the EC2):**
Once connected, open a terminal. Look for:
- A "Terminal" icon on the desktop or taskbar
- Right-click the desktop → "Open Terminal"
- Or press `Super` key and type "terminal"

**If accessing via SSH directly:**
```bash
ssh ec2-user@<ip-address-from-Marcus>
```

Once you have a terminal prompt, create a working directory:
```bash
mkdir -p ~/recon && cd ~/recon
```

All commands for the rest of this guide run from `~/recon`.

---

## Step 2 — Get the Setup Script onto the EC2

Try these options in order. Stop at the first one that works.

**Option A — Clone the repo (fastest, requires git + LevelUp access from the EC2):**
```bash
cd ~/recon
git clone https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon.git .
```
If it asks for a username/password, use `cwilson613` and the LevelUp personal access token (ask Chris if you don't have it). If it hangs or errors, try Option B.

**Option B — Download just the setup script via curl:**
```bash
cd ~/recon
curl -sk https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/raw/main/setup-runner.sh \
  -o setup-runner.sh
chmod +x setup-runner.sh
```
If curl errors or the file is empty, try Option C.

**Option C — Transfer via S3 (for when the EC2 can't reach LevelUp at all):**

First, from your local machine (not the EC2):
```bash
curl -sk https://raw.githubusercontent.com/recro/c1-recon/main/setup-runner.sh \
  -o setup-runner.sh
aws s3 cp setup-runner.sh s3://hncd-airgap-transfer/tools/setup-runner.sh
```

Then, back on the EC2:
```bash
cd ~/recon
aws s3 cp s3://hncd-airgap-transfer/tools/setup-runner.sh setup-runner.sh
chmod +x setup-runner.sh
```

**Quick sanity check — confirm you got the right file:**
```bash
head -3 setup-runner.sh
```
You should see:
```
#!/usr/bin/env bash
# setup-runner.sh — Register and start the c1-recon GitLab Runner on an EC2 instance
```
If you see HTML or an error message instead, the download failed — try the next option.

**✓ Done when:** `head -3 setup-runner.sh` shows the bash shebang and comment.

---

## Step 3 — Install AWS CLI (if needed)

The setup script requires `aws` to be present. Check first:
```bash
aws --version
```

If that prints `aws-cli/2.x.x ...` you're good — skip to Step 4.

If you get `command not found`, also download and run the AWS CLI installer:
```bash
# Download (same three options as Step 2 — replace filename with install-awscli.sh)
curl -sk https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/raw/main/install-awscli.sh \
  -o install-awscli.sh
chmod +x install-awscli.sh
sudo ./install-awscli.sh
```
The script tries to download AWS CLI directly, then falls back to S3 if the internet is unreachable.

---

## Step 4 — Run the Setup Script

```bash
cd ~/recon
sudo ./setup-runner.sh
```

**What you'll see (expected output):**
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
          Account:   123456789012
          Role/User: arn:aws-us-gov:sts::...
...
[INFO]  === Setup complete ===
```

**If you see errors:**

| Error message | What to do |
|---|---|
| `aws cli not found` | Run `sudo ./install-awscli.sh` (Step 3), then re-run setup |
| `Could not reach packages.gitlab.com` | Follow the [manual gitlab-runner install](#appendix-manual-gitlab-runner-install) in the Appendix below |
| `Service did not start after 15 seconds` | Run `sudo journalctl -u gitlab-runner -n 30` and send the output to Chris |
| `AWS sts get-caller-identity failed` | Runner is registered and will start. AWS calls inside the recon scripts will fail. Ask Marcus to confirm an IAM instance profile is attached to this EC2. |
| `Run with sudo` | You forgot `sudo` — re-run as `sudo ./setup-runner.sh` |

**✓ Done when:** You see `=== Setup complete ===` at the bottom.

---

## Step 5 — Confirm the Runner is Online in LevelUp

1. In your browser, go to:
   `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/settings/ci_cd`
   *(If you don't see a Settings menu, you don't have Maintainer role — ask Chris to check.)*

2. Scroll down to the **Runners** section and click **Expand**.

3. Look for a runner named **`c1-recon-airgapped-<hostname>`** with a **green dot** next to it.
   - Green dot = online and ready
   - Grey dot = not yet connected — wait 60 seconds and refresh (it polls every 30s)
   - Red / no dot = something went wrong — see below

**If the runner shows grey after 2 minutes:**
```bash
# Back on the EC2
sudo systemctl status gitlab-runner
sudo journalctl -u gitlab-runner -n 30
```
Look for connection errors and send them to Chris.

**✓ Done when:** Green dot in the GitLab UI.

---

## Step 6 — Run the Preflight Job

The preflight job confirms the runner has all the tools it needs before we run the full diagnostic.

1. Go to: `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/pipelines`

2. Click the blue **Run pipeline** button (top right corner).

3. On the next screen, leave the branch as `main` and click the blue **Run pipeline** button again.

4. You'll land on a pipeline status page. The `preflight` job should start automatically. Click its name to watch the live output.

**What a passing preflight looks like:**
```
=== c1-recon preflight ===
Runner hostname: ip-10-x-x-x

  bash            [OK] /bin/bash
  aws             [OK] /usr/local/bin/aws
  jq              [OK] /usr/bin/jq
  curl            [OK] /usr/bin/curl
  openssl         [OK] /usr/bin/openssl

Optional tools:
  kubectl         [not available]   ← this is fine for today
  helm            [not available]   ← this is fine for today
  dig             [OK]

{
    "UserId": "AROAEXAMPLE",
    "Account": "123456789012",
    "Arn": "arn:aws-us-gov:sts::123456789012:assumed-role/..."
}
Preflight passed.
```

**If preflight fails because a tool is missing:**
```bash
# Back on the EC2
sudo dnf install -y jq bind-utils openssl curl
```
Then go back to the pipeline list and click **Run pipeline** again.

**Note on kubectl:** If it shows `[not available]`, that's fine today. Scripts 07, 10, and 12 will skip their Kubernetes-specific sections and still run the AWS API sections. Make a note of whether kubectl is present — we may configure it on a follow-up session.

**✓ Done when:** The preflight job shows a green checkmark (✅) and you see `Preflight passed.` in the log.

---

## Step 7 — Run the Recon Job

The `recon` job runs the 13 diagnostic scripts. It is **manual** — it won't start on its own.

1. Go back to the pipeline page (click **← Back to pipelines** or navigate to `/pipelines`).

2. Click the pipeline you just ran (it should say `passed` or still be running).

3. In the pipeline graph, find the `recon` job. It will have a **grey play button (▶)** next to it — click that button to start it.

4. Click the job name to watch live output. **Expected runtime: 10–15 minutes.**

**Key things to watch for as it runs:**

| Script | What to look for |
|--------|-----------------|
| `01-identity.sh` | Which AWS account and role we're running as |
| `02-iam-boundaries.sh` | A lot of `DENY` results here is **normal and expected** — that's data |
| `04-network-egress.sh` | Does it confirm LevelUp GitLab is reachable? |
| `05-dns-resolution.sh` | **Key question:** Does `oidc.eks.us-gov-west-1.amazonaws.com` resolve? Look for `RESOLVED` or `FAILED` next to that line |
| `08-vpc-environment.sh` | How many VPC endpoints are listed? Note the count |
| `10-spectro-readiness.sh` | Expect several `WARN` items — that's normal, it's mapping what's missing |

**About job status colours:**
- ✅ Green = all scripts exited cleanly
- 🟡 Yellow / "passed with warnings" = one or more scripts returned a non-zero exit — this is **expected and fine** (e.g. a denied IAM call). The artifacts are still collected.
- ❌ Red = the job itself crashed (not just a script inside it) — send the log to Chris

**✓ Done when:** The `recon` job finishes (green or yellow both count).

---

## Step 8 — Run the Export Twin Job

The `export-twin` job captures a full JSON snapshot of the environment for building the digital twin. Also **manual** — start it the same way as the recon job.

1. On the pipeline page, find the `export-twin` job and click its grey **▶** play button.

2. **Expected runtime: 3–5 minutes.**

3. When done, the last few lines of the job log will show a summary like:
   ```json
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
   Note those numbers — they're useful context for the team.

**✓ Done when:** `export-twin` job is green.

---

## Step 9 — Download the Artifacts

**From the recon job:**

1. Click the `recon` job name to open it.
2. On the right side of the job page, look for an **Artifacts** panel or a **Download** button. Click it.
   - If you see a **Browse** button instead, click that and then download individual files.
3. You'll get a zip. Inside, look for:
   - `script-outputs/` — one `.txt` file per script (e.g. `05-dns-resolution.txt`)
   - `recon-report-<timestamp>.txt` — everything combined in one file

**From the export-twin job:**

1. Click the `export-twin` job name.
2. Same process — download the artifact.
3. You'll get `twin-snapshot-<timestamp>.json`.

**What to do with the files:**

| File | Send to |
|------|---------|
| Full recon report (`.txt`) | Chris Wilson + William Shepard for review |
| `05-dns-resolution.txt` | Marcus Gales — answers the OIDC DNS question |
| `10-spectro-readiness.txt` | Tommy Scherer + Will Crum at SpectroCloud |
| `12-imageswap-validation.txt` | Tommy Scherer + Will Crum at SpectroCloud |
| `twin-snapshot-*.json` | Keep internal for now — contains real account IDs and ARNs |

---

## Step 10 — Enable the Weekly Schedule

While you're logged in, set up the recurring run so we get weekly drift detection automatically.

1. Go to: `https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/pipeline_schedules`
   *(Or navigate: left sidebar → **Build** → **Pipeline schedules** → **New schedule**)*

2. Fill in:
   - **Description:** `Weekly c1-recon baseline`
   - **Interval Pattern:** `0 6 * * 1`
     *(This means: every Monday at 06:00 UTC, which is 02:00 Eastern)*
   - **Target branch:** `main`

3. Under **Variables**, click **Add variable** and set:
   - Key: `SCHEDULED_RUN`
   - Value: `true`

4. Click **Save pipeline schedule**.

5. Confirm the new schedule appears in the list with a green **Active** indicator and shows a "Next run" date.

**✓ Done when:** Schedule is active and shows a next run date.

---

## Done — Notes to Capture

Jot these down for the weekly action report (WAR) and team sync:

- [ ] Which EC2 the runner is on (hostname or IP)
- [ ] Is kubectl present on the runner? (from preflight output)
- [ ] Which AWS account and role (from script 01 output)
- [ ] Did `oidc.eks.us-gov-west-1.amazonaws.com` resolve? (from script 05 — yes/no)
- [ ] VPC endpoint count (from twin export summary)
- [ ] EKS cluster count (from twin export summary)
- [ ] Any unexpected failures or blockers

---

## Appendix: Manual gitlab-runner Install

Use this if `setup-runner.sh` fails at the "Installing GitLab Runner" step because `packages.gitlab.com` is unreachable.

**From a connected machine (not the EC2), stage the binary in S3:**
```bash
curl -LO "https://gitlab-ci-multi-runner-downloads.s3.amazonaws.com/latest/binaries/gitlab-runner-linux-amd64"
aws s3 cp gitlab-runner-linux-amd64 s3://hncd-airgap-transfer/tools/gitlab-runner-linux-amd64
```

**Then on the EC2:**
```bash
# Download from S3 and install
aws s3 cp s3://hncd-airgap-transfer/tools/gitlab-runner-linux-amd64 /tmp/gitlab-runner
sudo install -m 755 /tmp/gitlab-runner /usr/local/bin/gitlab-runner

# Register (the token is pre-issued and never expires)
sudo gitlab-runner register \
  --non-interactive \
  --url "https://code.levelup.cce.af.mil" \
  --token "glrt-1MW4BbRbqQIEWSskqtKxG286MQpwOnpragp0OjMKdTpraGMT.01.1c1624b2p" \
  --name "c1-recon-airgapped-$(hostname -s)" \
  --executor "shell" \
  --tag-list "airgapped" \
  --run-untagged "false" \
  --tls-skip-verify "true"

# Start as a service
sudo gitlab-runner install
sudo systemctl enable --now gitlab-runner
sudo systemctl status gitlab-runner
```

After this, pick up at **Step 5** (verify the runner shows green in LevelUp).
