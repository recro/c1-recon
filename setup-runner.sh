#!/usr/bin/env bash
# setup-runner.sh — Register and start the c1-recon GitLab Runner on an EC2 instance
#                   inside the HNCD CloudOne GovCloud environment.
#
# Prerequisites:
#   - AL2023 (or RHEL 8/9) EC2 instance with outbound HTTPS to code.levelup.cce.af.mil
#   - Run as a user with sudo
#   - aws cli v2 accessible (instance profile or env vars for AWS credentials)
#
# Usage:
#   chmod +x setup-runner.sh
#   sudo ./setup-runner.sh
#
# After running, the runner will register with LevelUp GitLab and begin polling
# for jobs tagged [airgapped]. Verify at:
#   https://code.levelup.cce.af.mil/siem-devgroup/siem/c1-recon/-/settings/ci_cd#js-runners-settings
#
# SECURITY NOTE: The token in this script is a GitLab runner authentication token.
# Do not paste it into chat, email, or ticket comments. If you believe it has been
# exposed, contact Chris Wilson to rotate it via the GitLab API.

set -euo pipefail

GITLAB_URL="https://code.levelup.cce.af.mil"
RUNNER_TOKEN="glrt-1MW4BbRbqQIEWSskqtKxG286MQpwOnpragp0OjMKdTpraGMT.01.1c1624b2p"
RUNNER_NAME="c1-recon-airgapped-$(hostname -s)"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Must run as root ─────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Run with sudo: sudo $0"
  exit 1
fi

info "=== c1-recon GitLab Runner Setup ==="
info "Host:        $(hostname)"
info "Runner name: ${RUNNER_NAME}"
info "GitLab URL:  ${GITLAB_URL}"
echo ""

# ── 1. Install required tools ────────────────────────────────────────────────
info "Step 1: Installing required tools"

if command -v dnf &>/dev/null; then
  PKG="dnf"
elif command -v yum &>/dev/null; then
  PKG="yum"
elif command -v apt-get &>/dev/null; then
  PKG="apt-get"
else
  error "No supported package manager found (dnf/yum/apt-get)"
  exit 1
fi

MISSING_PKGS=()
command -v jq      &>/dev/null || MISSING_PKGS+=(jq)
command -v curl    &>/dev/null || MISSING_PKGS+=(curl)
command -v openssl &>/dev/null || MISSING_PKGS+=(openssl)

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
  info "Installing: ${MISSING_PKGS[*]}"
  $PKG install -y "${MISSING_PKGS[@]}"
else
  info "Required tools already present"
fi

if ! command -v kubectl &>/dev/null; then
  warn "kubectl not found — EKS/Palette checks will skip K8s sections (non-blocking)"
fi

if ! command -v aws &>/dev/null; then
  error "aws cli not found. Run 'sudo ./install-awscli.sh' first, then re-run this script."
  exit 1
fi
info "aws cli: $(aws --version 2>&1 | head -1)"
echo ""

# ── 2. Install GitLab Runner ─────────────────────────────────────────────────
info "Step 2: Installing GitLab Runner"

if command -v gitlab-runner &>/dev/null; then
  CURRENT_VER=$(gitlab-runner --version | head -1 | awk '{print $3}')
  info "gitlab-runner already installed: ${CURRENT_VER} — skipping install"
else
  info "Downloading gitlab-runner package repository..."
  if [[ "$PKG" == "dnf" || "$PKG" == "yum" ]]; then
    if ! curl -sL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | bash; then
      error "Could not reach packages.gitlab.com."
      error "Use the manual binary install fallback in sessions/2026-04-17-first-recon.md (Appendix)."
      exit 1
    fi
    $PKG install -y gitlab-runner
  elif [[ "$PKG" == "apt-get" ]]; then
    if ! curl -sL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash; then
      error "Could not reach packages.gitlab.com."
      error "Use the manual binary install fallback in sessions/2026-04-17-first-recon.md (Appendix)."
      exit 1
    fi
    apt-get install -y gitlab-runner
  fi
  info "gitlab-runner installed: $(gitlab-runner --version | head -1)"
fi
echo ""

# ── 3. Register the runner ───────────────────────────────────────────────────
info "Step 3: Registering runner with LevelUp GitLab"

# Unregister any prior registration with the same name to avoid duplicates
if gitlab-runner list 2>/dev/null | grep -q "${RUNNER_NAME}"; then
  warn "Runner '${RUNNER_NAME}' already registered — removing old registration first"
  gitlab-runner unregister --name "${RUNNER_NAME}" 2>/dev/null || true
fi

gitlab-runner register \
  --non-interactive \
  --url              "${GITLAB_URL}" \
  --token            "${RUNNER_TOKEN}" \
  --name             "${RUNNER_NAME}" \
  --executor         "shell" \
  --tag-list         "airgapped" \
  --run-untagged     "false" \
  --locked           "false" \
  --tls-skip-verify  "true"

info "Runner registered"
echo ""

# ── 4. Start the runner service ──────────────────────────────────────────────
info "Step 4: Starting gitlab-runner service"

if systemctl is-active --quiet gitlab-runner; then
  info "Service already running — restarting to pick up new registration"
  systemctl restart gitlab-runner
else
  systemctl enable --now gitlab-runner
fi

# Wait up to 15 seconds for the service to become active
info "Waiting for service to start..."
RETRIES=5
for i in $(seq 1 $RETRIES); do
  sleep 3
  if systemctl is-active --quiet gitlab-runner; then
    info "gitlab-runner service: ACTIVE"
    break
  fi
  if [[ $i -eq $RETRIES ]]; then
    error "Service did not start after $((RETRIES * 3)) seconds."
    error "Check logs: sudo journalctl -u gitlab-runner -n 30"
    exit 1
  fi
  warn "Not yet active, retrying ($i/$RETRIES)..."
done
echo ""

# ── 5. Verify AWS credentials ────────────────────────────────────────────────
info "Step 5: Verifying AWS credentials"
if AWS_IDENTITY=$(aws sts get-caller-identity 2>/dev/null); then
  info "AWS identity confirmed:"
  echo "$AWS_IDENTITY" | jq -r '"  Account:   \(.Account)\n  Role/User: \(.Arn)"'
else
  warn "AWS sts get-caller-identity failed."
  warn "The runner is registered and running, but the recon scripts will not be"
  warn "able to make AWS API calls. Check that an IAM instance profile is attached"
  warn "to this EC2, or set AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars."
fi
echo ""

# ── 6. Final instructions ────────────────────────────────────────────────────
info "=== Setup complete ==="
echo ""
echo "  Runner name:  ${RUNNER_NAME}"
echo "  Runner ID:    18586"
echo "  Tags:         airgapped"
echo "  Executor:     shell"
echo ""
echo "  Verify runner is online (requires Maintainer role):"
echo "  ${GITLAB_URL}/siem-devgroup/siem/c1-recon/-/settings/ci_cd#js-runners-settings"
echo ""
echo "  Trigger the first pipeline run:"
echo "  ${GITLAB_URL}/siem-devgroup/siem/c1-recon/-/pipelines/new"
echo ""
info "Next: follow sessions/2026-04-17-first-recon.md starting at Step 3."
