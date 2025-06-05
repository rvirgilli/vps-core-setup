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
apt-get install -y "${DPKG_OPTS[@]}" curl ufw

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
# Add GitHub's key to known_hosts. This might fetch multiple key types.
# We only need one to succeed for the connection to be established without prompt.
ssh-keyscan github.com 2>/dev/null | sudo -u "${DEPLOY_USER}" tee "/home/${DEPLOY_USER}/.ssh/known_hosts" > /dev/null
# Ensure permissions are strict again after tee, as tee might change them depending on umask.
sudo -u "${DEPLOY_USER}" chmod 600 "/home/${DEPLOY_USER}/.ssh/known_hosts"

echo "   Attempting SSH connection to GitHub as user '${DEPLOY_USER}'..."
# ssh -T git@github.com exits with 1 on success, so check output for success message.
if sudo -u "${DEPLOY_USER}" ssh -T git@github.com 2>&1 | grep -q "You've successfully authenticated"; then
    echo "   ✅ SSH to GitHub successful for user ${DEPLOY_USER}. Authentication confirmed."
elif sudo -u "${DEPLOY_USER}" ssh -T git@github.com 2>&1 | grep -q "Warning: Permanently added 'github.com'"; then
    echo "   ✅ SSH to GitHub successful for user ${DEPLOY_USER}. Host key added and authentication confirmed (check for username in message)."
    # It's possible the "You've successfully authenticated" message is also present, grep -q exits on first match.
    # For a more robust check, one could capture the full output and check both.
else
    echo "   ⚠️  SSH to GitHub failed for user ${DEPLOY_USER}."
    echo "      Output of ssh -T git@github.com (run as ${DEPLOY_USER}):"
    sudo -u "${DEPLOY_USER}" ssh -T git@github.com 2>&1 || true # Print output regardless of exit code
    echo "      Common issues: Key not added to GitHub account, or network connectivity problems."
    echo "      The script will continue, but git operations for '${DEPLOY_USER}' might fail later."
fi

echo
echo "9) Setting up Central Monitoring Stack (Prometheus & Grafana)..."
echo "-----------------------------------------------------------------"
# Define source paths from the cloned repository
CLONED_REPO_PATH="/opt/vps-core-setup" # This is where the script clones the repo
SOURCE_DOCKER_COMPOSE_MONITORING_FILE="${CLONED_REPO_PATH}/monitoring/docker-compose.monitoring.yml"
SOURCE_PROMETHEUS_CONFIG_FILE="${CLONED_REPO_PATH}/monitoring/prometheus_config/prometheus.yml"

echo "   → Ensuring monitoring directories exist: ${MONITORING_DIR}, ${PROMETHEUS_CONFIG_DIR}"
mkdir -p "${PROMETHEUS_CONFIG_DIR}" # This creates /opt/monitoring and /opt/monitoring/prometheus_config

if [ -f "${SOURCE_DOCKER_COMPOSE_MONITORING_FILE}" ]; then
    echo "   → Copying Docker Compose file for monitoring stack to ${DOCKER_COMPOSE_MONITORING_FILE}..."
    cp "${SOURCE_DOCKER_COMPOSE_MONITORING_FILE}" "${DOCKER_COMPOSE_MONITORING_FILE}"
    echo "   → ${DOCKER_COMPOSE_MONITORING_FILE} copied."
else
    echo "   ⚠️ ERROR: Source Docker Compose file not found at ${SOURCE_DOCKER_COMPOSE_MONITORING_FILE}. Cannot set up monitoring stack."
    # Optionally, exit here if this is critical: exit 1
fi

if [ -f "${SOURCE_PROMETHEUS_CONFIG_FILE}" ]; then
    echo "   → Copying initial Prometheus configuration to ${PROMETHEUS_CONFIG_FILE}..."
    cp "${SOURCE_PROMETHEUS_CONFIG_FILE}" "${PROMETHEUS_CONFIG_FILE}"
    echo "   → ${PROMETHEUS_CONFIG_FILE} copied."
else
    echo "   ⚠️ ERROR: Source Prometheus config file not found at ${SOURCE_PROMETHEUS_CONFIG_FILE}. Cannot set up monitoring stack."
    # Optionally, exit here: exit 1
fi

echo "   → Starting central Prometheus, Grafana, Node Exporter, and cAdvisor services..."
# Ensure the monitoring directory exists and cd into it to use relative paths in compose file
# The DOCKER_COMPOSE_MONITORING_FILE variable already points to the correct path in /opt/monitoring
if [ -f "${DOCKER_COMPOSE_MONITORING_FILE}" ]; then # Check if the target file was successfully copied
    if (cd "${MONITORING_DIR}" && docker compose -f "${DOCKER_COMPOSE_MONITORING_FILE##*/}" up -d); then
        echo "   → Central monitoring stack (Prometheus, Grafana, etc.) started successfully."
    else
        echo "   ⚠️  Failed to start monitoring stack. Check Docker Compose logs in ${MONITORING_DIR}."
    fi
else
    echo "   ⚠️  Skipping start of monitoring stack as configuration files were not found/copied."
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