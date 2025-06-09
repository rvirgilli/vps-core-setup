#!/usr/bin/env bash
#
# update-vps.sh — Update the core monitoring stack on the VPS
#
# This script pulls the latest changes from the vps-core-setup repository
# and applies the updated configurations to the live monitoring stack.
# It is designed to be run safely on a live VPS.
#
# USAGE:
#   cd /opt/vps-core-setup
#   sudo ./update-vps.sh

set -euo pipefail

echo "VPS Update Script Started"
echo "========================"

# --- Configuration ---
REPO_CLONE_DIR="/opt/vps-core-setup"
MONITORING_DIR="/opt/monitoring"
# --- End Configuration ---

# 1) Verify script is run as root (via sudo)
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Please run this script with: sudo ./update-vps.sh"
  exit 1
fi

# 2) Verify script is run from the repository directory
if [[ "$PWD" != "${REPO_CLONE_DIR}" ]]; then
    echo "ERROR: This script must be run from the ${REPO_CLONE_DIR} directory."
    echo "Please run: cd ${REPO_CLONE_DIR} && sudo ./update-vps.sh"
    exit 1
fi

echo
echo "1) Pulling latest changes from GitHub..."
echo "-----------------------------------------"
if git pull origin main; then
    echo "   → Latest changes pulled successfully."
else
    echo "   ⚠️ ERROR: Failed to pull changes from GitHub. Aborting update."
    exit 1
fi

echo
echo "2) Copying updated monitoring configurations to ${MONITORING_DIR}..."
echo "-------------------------------------------------------------------"

# Define source and destination paths
SOURCE_MONITORING_DIR="${REPO_CLONE_DIR}/monitoring"
DEST_MONITORING_DIR="${MONITORING_DIR}"

# Ensure destination directory exists (it should, but this is a safeguard)
mkdir -p "${DEST_MONITORING_DIR}"

# Copy the main docker-compose file
echo "   → Copying docker-compose.monitoring.yml..."
cp "${SOURCE_MONITORING_DIR}/docker-compose.monitoring.yml" "${DEST_MONITORING_DIR}/"

# Copy the main prometheus.yml config file
echo "   → Copying prometheus.yml..."
cp "${SOURCE_MONITORING_DIR}/prometheus_config/prometheus.yml" "${DEST_MONITORING_DIR}/prometheus_config/"

# Use rsync to sync the contents of the conf.d and grafana directories.
# This is efficient and will remove any old files that are no longer in the repository,
# keeping the configuration clean.
echo "   → Syncing prometheus_config/conf.d/ directory..."
# We intentionally do NOT use --delete here, so that user-added application
# scrape configs are preserved during an update.
rsync -av "${SOURCE_MONITORING_DIR}/prometheus_config/conf.d/" "${DEST_MONITORING_DIR}/prometheus_config/conf.d/"

echo "   → Syncing grafana/ directory..."
rsync -av --delete "${SOURCE_MONITORING_DIR}/grafana/" "${DEST_MONITORING_DIR}/grafana/"

echo "   → All configurations copied."

echo
echo "3) Applying changes with Docker Compose..."
echo "------------------------------------------"
cd "${DEST_MONITORING_DIR}"
echo "   → Running 'docker compose -f docker-compose.monitoring.yml up -d'. This will recreate any services whose configuration has changed."
docker compose -f docker-compose.monitoring.yml up -d

echo
echo "✅ Update complete. The monitoring stack has been updated to the latest version." 