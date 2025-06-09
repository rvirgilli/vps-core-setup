#!/usr/bin/env bash
#
# vps-setup.sh — Configure a fresh Debian 12 – Docker VPS automatically
#               (run with sudo, no interactive prompts)
#
# USAGE:
#   1) Upload this script to the VPS (e.g., /root/vps-setup.sh)
#   2) Make it executable:
#      sudo chmod +x /root/vps-setup.sh
#   3) Run it:
#      sudo /root/vps-setup.sh
#
# At the end, SSH→GitHub authentication is tested for user "deploy".
# The script also deploys a central monitoring stack (Prometheus, Grafana, etc.).
# Finally, it runs comprehensive tests to validate the entire setup.

set -euo pipefail

# Run in non-interactive mode and force keeping local config files (e.g., /etc/ssh/sshd_config)
export DEBIAN_FRONTEND=noninteractive
DPKG_OPTS=(-o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef")

# --- Configuration ---
DEPLOY_USER="deploy"
GITHUB_KEY_PATH="/home/${DEPLOY_USER}/.ssh/id_github"
MONITORING_DIR="/opt/monitoring"
PROMETHEUS_CONFIG_DIR="${MONITORING_DIR}/prometheus_config"
DOCKER_COMPOSE_MONITORING_FILE="${MONITORING_DIR}/docker-compose.monitoring.yml"
PROMETHEUS_CONFIG_FILE="${PROMETHEUS_CONFIG_DIR}/prometheus.yml"
REPO_URL="https://github.com/rvirgilli/vps-core-setup.git"
REPO_CLONE_DIR="/opt/vps-core-setup"
# --- End Configuration ---

# 1) Verify script is run as root (via sudo)
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run this script with: sudo /root/vps-setup.sh"
  exit 1
fi

echo
echo "VPS Setup Script Started"
echo "========================"

echo
echo "1) Updating system and installing basic packages..."
echo "--------------------------------------------------"
apt-get update
apt-get upgrade -y "${DPKG_OPTS[@]}"
apt-get install -y "${DPKG_OPTS[@]}" curl ufw jq git

echo
echo "2) Installing Docker (if not already installed)..."
echo "--------------------------------------------------"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | bash
else
  echo "   → Docker is already installed: $(docker --version)"
fi

echo
echo "3) Installing Docker Compose Plugin..."
echo "--------------------------------------"
apt-get update # Rerun update in case Docker install added sources
apt-get install -y "${DPKG_OPTS[@]}" docker-compose-plugin
echo "   → Docker Compose version: $(docker compose version)"

echo
echo "4) Creating user '${DEPLOY_USER}' and configuring access..."
echo "-----------------------------------------------------------------------"
if ! id -u "${DEPLOY_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${DEPLOY_USER}"
  echo "   → User '${DEPLOY_USER}' created."
else
  echo "   → User '${DEPLOY_USER}' already exists."
fi
usermod -aG docker,sudo "${DEPLOY_USER}"
echo "   → User '${DEPLOY_USER}' added to 'docker' and 'sudo' groups."

# Configure passwordless sudo for DEPLOY_USER
echo "   → Configuring passwordless sudo for '${DEPLOY_USER}'..."
echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${DEPLOY_USER}"
chmod 0440 "/etc/sudoers.d/${DEPLOY_USER}"
echo "   → Passwordless sudo configured via /etc/sudoers.d/${DEPLOY_USER}"

echo
echo "5) Copying your local public SSH key to '/home/${DEPLOY_USER}/.ssh/authorized_keys'..."
echo "-------------------------------------------------------------------------------"
mkdir -p "/home/${DEPLOY_USER}/.ssh"
chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
chmod 700 "/home/${DEPLOY_USER}/.ssh"

# If an authorized_keys file already exists for deploy, back it up
if [[ -f "/home/${DEPLOY_USER}/.ssh/authorized_keys" ]]; then
  mv "/home/${DEPLOY_USER}/.ssh/authorized_keys" "/home/${DEPLOY_USER}/.ssh/authorized_keys.bak_$(date +%s)" || true
  echo "   → Existing authorized_keys backed up."
fi

# Attempt to copy from the user who ran sudo (e.g., 'debian' or 'root')
SUDO_USER_HOME=""
if [ -n "${SUDO_USER}" ] && [ "${SUDO_USER}" != "root" ]; then
    SUDO_USER_HOME=$(eval echo "~${SUDO_USER}")
fi

COPIED_KEY=false
if [ -n "${SUDO_USER_HOME}" ] && [ -f "${SUDO_USER_HOME}/.ssh/authorized_keys" ]; then
    cp "${SUDO_USER_HOME}/.ssh/authorized_keys" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    echo "   → Copied authorized_keys from ${SUDO_USER_HOME}/.ssh/"
    COPIED_KEY=true
elif [[ -f "/root/.ssh/authorized_keys" ]]; then
    cp "/root/.ssh/authorized_keys" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    echo "   → Copied authorized_keys from /root/.ssh/"
    COPIED_KEY=true
else
    echo "   ⚠️  No 'authorized_keys' found for '${SUDO_USER:-root}'."
    echo "      You will need to add your local public SSH key manually to /home/${DEPLOY_USER}/.ssh/authorized_keys."
fi

if ${COPIED_KEY}; then
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
    echo "   → /home/${DEPLOY_USER}/.ssh/authorized_keys updated."
fi

echo
echo "6) Generating SSH keypair for GitHub (user '${DEPLOY_USER}')..."
echo "-------------------------------------------------------"
if [[ -f "${GITHUB_KEY_PATH}" ]]; then
  mv "${GITHUB_KEY_PATH}" "${GITHUB_KEY_PATH}.bak_$(date +%s)" || true
  mv "${GITHUB_KEY_PATH}.pub" "${GITHUB_KEY_PATH}.pub.bak_$(date +%s)" || true
  echo "   → Existing GitHub key backed up."
fi

sudo -u "${DEPLOY_USER}" ssh-keygen -t ed25519 \
  -f "${GITHUB_KEY_PATH}" -N "" \
  -C "github-vps-$(hostname)-${DEPLOY_USER}" </dev/null

echo
echo "   → New public key generated at ${GITHUB_KEY_PATH}.pub"
echo
echo "   COPY the entire content below and paste it as an 'Authentication key' on:"
echo "     GitHub » Settings » SSH and GPG keys » New SSH key"
echo
echo "================================================================================"
cat "${GITHUB_KEY_PATH}.pub"
echo "================================================================================"
echo
read -p "   After you paste this key in GitHub, press ENTER to continue..."

echo
echo "7) Creating ~/.ssh/config for user '${DEPLOY_USER}' to use ${GITHUB_KEY_PATH##*/}..."
echo "----------------------------------------------------------------"
cat << EOF > "/home/${DEPLOY_USER}/.ssh/config"
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/${GITHUB_KEY_PATH##*/}
  IdentitiesOnly yes
EOF
chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/config"
chmod 600 "/home/${DEPLOY_USER}/.ssh/config"
echo "   → /home/${DEPLOY_USER}/.ssh/config created."

echo
echo "8) Testing SSH→GitHub authentication as '${DEPLOY_USER}'..."
echo "---------------------------------------------------"
# Create known_hosts file with github's key to avoid prompt during test
sudo -u "${DEPLOY_USER}" mkdir -p "/home/${DEPLOY_USER}/.ssh"
sudo -u "${DEPLOY_USER}" touch "/home/${DEPLOY_USER}/.ssh/known_hosts"
sudo -u "${DEPLOY_USER}" chmod 600 "/home/${DEPLOY_USER}/.ssh/known_hosts"
ssh-keyscan github.com 2>/dev/null | sudo -u "${DEPLOY_USER}" tee "/home/${DEPLOY_USER}/.ssh/known_hosts" > /dev/null
sudo -u "${DEPLOY_USER}" chmod 600 "/home/${DEPLOY_USER}/.ssh/known_hosts"

echo "   Attempting SSH connection to GitHub as user '${DEPLOY_USER}'..."
# Temporarily disable 'exit on error' because ssh -T always exits with 1 on success.
set +e
# Capture all output (STDOUT and STDERR) and the exit code
SSH_OUTPUT=$(sudo -u "${DEPLOY_USER}" ssh -o ConnectTimeout=10 -T git@github.com 2>&1)
SSH_EXIT_CODE=$?
set -e
# Re-enabled 'exit on error'

# Check for the primary success message (case-insensitive)
if echo "${SSH_OUTPUT}" | grep -i -q "You've successfully authenticated"; then
    echo "   ✅ SSH to GitHub successful for user ${DEPLOY_USER}. Authentication confirmed."
    # For debugging or verbosity, you can uncomment the next two lines:
    # echo "      Full GitHub SSH output:"
    # echo "${SSH_OUTPUT}"
elif echo "${SSH_OUTPUT}" | grep -q "Warning: Permanently added 'github.com'"; then
    echo "   ✅ SSH to GitHub: Host key for github.com was added (first-time connection)."
    echo "      Full GitHub SSH output:"
    echo "${SSH_OUTPUT}" # This output should contain the authentication message too
    if echo "${SSH_OUTPUT}" | grep -i -q "You've successfully authenticated"; then
        echo "   ✅ Authentication confirmed within the same attempt after host key addition."
    else
        echo "   ℹ️  Host key added. The authentication message was not found in this attempt. If GitHub access fails later, ensure the key is correctly added to your GitHub account."
    fi
else
    echo "   ⚠️  SSH to GitHub authentication failed for user ${DEPLOY_USER}."
    echo "      Neither the standard success message nor a host key warning was found."
    echo "      Output from ssh -T git@github.com (Exit Code: ${SSH_EXIT_CODE}):"
    echo "${SSH_OUTPUT}"
    echo "      Common issues: SSH key not correctly added to your GitHub account, network connectivity problems, or local SSH configuration issues for the 'deploy' user."
    echo "      The script will continue, but git operations requiring GitHub authentication for '${DEPLOY_USER}' might fail."
fi

echo
echo "9) Cloning Repository and Setting up Central Monitoring Stack..."
echo "----------------------------------------------------------------"
# Clone the repository first to get monitoring configuration files
if [ ! -d "${REPO_CLONE_DIR}" ]; then
    echo "   → Cloning vps-core-setup repository to ${REPO_CLONE_DIR}..."
    if git clone "${REPO_URL}" "${REPO_CLONE_DIR}"; then
        echo "   → Repository cloned successfully."
    else
        echo "   ⚠️ ERROR: Failed to clone repository. Cannot set up monitoring stack."
        echo "      Please check your internet connection and GitHub access."
        exit 1
    fi
else
    echo "   → Repository already exists at ${REPO_CLONE_DIR}. Pulling latest changes..."
    (cd "${REPO_CLONE_DIR}" && git pull) || echo "   ⚠️  Warning: Failed to pull latest changes. Proceeding with existing code."
fi

# Define source paths from the cloned repository
SOURCE_MONITORING_DIR="${REPO_CLONE_DIR}/monitoring"
DEST_MONITORING_DIR="${MONITORING_DIR}"

echo "   → Ensuring monitoring directories exist: ${DEST_MONITORING_DIR}"
mkdir -p "${DEST_MONITORING_DIR}"

echo "   → Copying all monitoring configurations from ${SOURCE_MONITORING_DIR}..."
# Use rsync to be efficient and clean.
# This ensures that all necessary files and directories (docker-compose, grafana, prometheus_config) are copied.
rsync -av --delete "${SOURCE_MONITORING_DIR}/" "${DEST_MONITORING_DIR}/"
echo "   → All configurations copied to ${DEST_MONITORING_DIR}."

echo "   → Starting central Prometheus, Grafana, Node Exporter, and cAdvisor services..."
# Ensure the monitoring directory exists and cd into it to use relative paths in compose file
if [ -d "${DEST_MONITORING_DIR}" ]; then
    cd "${DEST_MONITORING_DIR}"
    echo "   → Running 'docker compose up -d' from ${PWD}..."
    docker compose up -d
else
    echo "   ⚠️ ERROR: Monitoring directory ${DEST_MONITORING_DIR} not found. Cannot start services."
    exit 1
fi

echo "     - Prometheus UI should be available at: http://<VPS_IP>:9090"
echo "     - Grafana UI should be available at: http://<VPS_IP>:3000 (default login: admin/admin)"
echo "     - Note: It might take a minute for services to be fully available."

echo
echo "10) Configuring UFW (firewall) and opening standard ports..."
echo "------------------------------------------------------------"
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH       comment 'Standard SSH port'
ufw allow 80/tcp        comment 'Standard HTTP'
ufw allow 443/tcp       comment 'Standard HTTPS'
ufw allow 3000/tcp      comment 'Grafana UI'
ufw allow 9090/tcp      comment 'Prometheus UI'
ufw allow 8000:8999/tcp comment 'Application ports range for user projects'
# ufw limit OpenSSH # Optional: rate limit SSH connections
if ufw --force enable; then
    echo "   → UFW enabled and configured."
    ufw status verbose
else
    echo "   ⚠️  Failed to enable UFW."
fi

echo
echo "11) Running Comprehensive Tests to Validate Setup..."
echo "----------------------------------------------------"
echo "   This will run all tests to validate the entire VPS setup and monitoring stack."

# Set proper ownership and permissions
echo "   → Setting ownership and permissions for ${DEPLOY_USER}..."
chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${REPO_CLONE_DIR}"
chmod +x "${REPO_CLONE_DIR}/test-vps-setup.sh"

# Wait a moment for all services to fully start up
echo "   → Waiting 30 seconds for all services to fully initialize..."
sleep 30

# Run the test script as the deploy user
echo "   → Running comprehensive validation tests as user '${DEPLOY_USER}'..."
echo "     This will test all components: monitoring stack, dummy app deployment, and cleanup."
echo
if sudo -u "${DEPLOY_USER}" bash -c "cd '${REPO_CLONE_DIR}' && ./test-vps-setup.sh"; then
    echo
    echo "🎉 ALL TESTS PASSED! VPS Setup is fully validated and ready for production use."
    echo
    echo "✅ VPS Core Setup Completed Successfully!"
    echo "========================================"
else
    echo
    echo "⚠️  Some tests failed. The VPS setup may have issues."
    echo "   Please review the test output above and check:"
    echo "   • Docker services status: sudo docker ps"
    echo "   • Monitoring logs: sudo docker logs central_prometheus"
    echo "   • Network connectivity to monitoring services"
    echo
    echo "❌ VPS Core Setup Completed with Test Failures!"
    echo "==============================================="
fi

echo
echo "✅ VPS Core Setup Completed!"
echo "========================="
echo "   • User '${DEPLOY_USER}' created with passwordless sudo and Docker access."
echo "   • SSH key for local access to '${DEPLOY_USER}' should be configured (copied or needs manual setup)."
echo "   • New GitHub SSH key for '${DEPLOY_USER}' generated: ${GITHUB_KEY_PATH}.pub (Needs to be added to GitHub)."
echo "   • Central Monitoring Stack (Prometheus, Grafana, Node Exporter, cAdvisor) deployed."
echo "   • UFW firewall enabled with essential ports open."
echo
echo "Next Steps:"
echo "   1. Ensure the public key from ${GITHUB_KEY_PATH}.pub is added to your GitHub account."
echo "   2. Replace <VPS_IP> in URLs above with your actual VPS IP address."
echo "   3. Access Prometheus: http://<VPS_IP>:9090"
echo "   4. Access Grafana: http://<VPS_IP>:3000 (admin/admin)"
echo "   5. Consult the vps-core-setup README.md for how to connect applications to the central monitoring."
echo
echo "To log in as the new user from your local machine (after setting up SSH key):"
echo "   ssh ${DEPLOY_USER}@<VPS_IP>"
echo
echo "To switch to the new user if you are already on the VPS as root/another sudoer:"
echo "   su - ${DEPLOY_USER}"
echo 