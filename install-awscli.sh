#!/usr/bin/env bash
# install-awscli.sh — Install AWS CLI v2 on an AL2023 / RHEL 8/9 EC2 instance.
#
# Run this BEFORE setup-runner.sh if the aws command is not found.
#
# Usage:
#   chmod +x install-awscli.sh
#   sudo ./install-awscli.sh
#
# Two modes:
#   1. Direct download (requires HTTPS egress to awscli.amazonaws.com)
#   2. S3 fallback   (for fully airgapped instances — needs the binary pre-staged)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  error "Run with sudo: sudo $0"
  exit 1
fi

# Already installed?
if command -v aws &>/dev/null; then
  info "aws cli already installed: $(aws --version 2>&1 | head -1)"
  exit 0
fi

INSTALL_DIR="/usr/local/aws-cli"
WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

info "=== AWS CLI v2 Install ==="
echo ""

# ── Try direct download ──────────────────────────────────────────────────────
DOWNLOAD_URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
info "Attempting direct download from awscli.amazonaws.com..."

if curl -sL --max-time 30 --output "${WORK_DIR}/awscliv2.zip" "${DOWNLOAD_URL}" 2>/dev/null; then
  # Verify we actually got a zip (not an HTML error page)
  if file "${WORK_DIR}/awscliv2.zip" | grep -q "Zip archive"; then
    info "Download successful. Installing..."
    cd "$WORK_DIR"
    unzip -q awscliv2.zip
    ./aws/install --install-dir "$INSTALL_DIR" --bin-dir /usr/local/bin
    info "AWS CLI installed: $(aws --version 2>&1 | head -1)"
    exit 0
  else
    warn "Download appeared to succeed but file is not a valid zip (network may have returned an error page)."
  fi
else
  warn "Direct download failed — awscli.amazonaws.com may not be reachable."
fi

echo ""

# ── S3 fallback ──────────────────────────────────────────────────────────────
# If direct download failed, expect the zip to be pre-staged in S3.
# To stage it (run this from a connected machine first):
#
#   curl -LO https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip
#   aws s3 cp awscli-exe-linux-x86_64.zip s3://hncd-airgap-transfer/tools/awscliv2.zip
#
S3_URI="s3://hncd-airgap-transfer/tools/awscliv2.zip"

# We need *some* aws cli to pull from S3 — check for boto3/Python as last resort,
# or just tell the user to stage it manually.
warn "Trying S3 fallback: ${S3_URI}"
warn "This requires the file to be pre-staged. See comments in this script."

if command -v aws &>/dev/null; then
  aws s3 cp "$S3_URI" "${WORK_DIR}/awscliv2.zip"
  file "${WORK_DIR}/awscliv2.zip" | grep -q "Zip archive" || { error "S3 download corrupt."; exit 1; }
  cd "$WORK_DIR"
  unzip -q awscliv2.zip
  ./aws/install --install-dir "$INSTALL_DIR" --bin-dir /usr/local/bin
  info "AWS CLI installed: $(aws --version 2>&1 | head -1)"
else
  echo ""
  error "Cannot install AWS CLI automatically — no network path available."
  error ""
  error "Manual steps:"
  error "  1. On a connected machine, download:"
  error "       curl -LO https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  error "  2. Transfer the zip to this EC2 (via SCP, shared drive, or S3 bucket)"
  error "  3. On this EC2, run:"
  error "       unzip awscliv2.zip"
  error "       sudo ./aws/install"
  exit 1
fi
