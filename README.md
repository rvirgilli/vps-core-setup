# vps-core-setup

This repository provides scripts and configurations to bootstrap a fresh Debian 12 VPS for hosting Dockerized applications. It sets up a `deploy` user, installs Docker, Docker Compose, configures UFW (firewall), and deploys a centralized monitoring stack (Prometheus, Grafana, Node Exporter, cAdvisor).

Its main goal is to standardize VPS configuration and separate infrastructure setup from application deployment.

## 1. Prerequisites

*   A fresh Debian 12 VPS.
*   Access to the VPS as `root` or a user with `sudo` privileges (e.g., the default `debian` user on many cloud providers).
*   An SSH key pair on your local machine to access the VPS.
*   `git` should be pre-installed on the VPS.

## 2. Quickstart

These steps assume you are logged into your fresh Debian 12 VPS as the `debian` user (or another non-root user with sudo privileges), and that all prerequisites are met.

1.  **SSH into your VPS:**
    ```bash
    ssh debian@<YOUR_VPS_IP>
    ```
2.  **Clone the repository and run the setup script:**
    ```bash
    sudo apt-get update 
    sudo git clone https://github.com/rvirgilli/vps-core-setup.git /opt/vps-core-setup
    cd /opt/vps-core-setup
    sudo chmod +x vps-setup.sh
    sudo ./vps-setup.sh
    ```
3.  **Follow Prompts:** The script will pause to ask you to add the `deploy` user's new SSH key to GitHub.
4.  **Automated Testing:** The setup script automatically runs comprehensive tests at the end to validate the entire setup. If all tests pass, you'll see a green success message and your VPS is ready for production use!
5.  **Post-Setup:**
    *   Access Prometheus: `http://<YOUR_VPS_IP>:9090`
    *   Access Grafana: `http://<YOUR_VPS_IP>:3000` (Login: `admin`/`admin` - change password immediately!). Includes pre-configured dashboards for Node Exporter, cAdvisor, and Prometheus.
    *   SSH as the new `deploy` user: `ssh deploy@<YOUR_VPS_IP>`

For detailed explanations, see the full documentation linked below.

## 3. Updating the Core Setup

To update your VPS with the latest changes from this repository (e.g., new dashboards, updated configurations), SSH into your VPS, navigate to the repository directory, and run the `update-vps.sh` script.

```bash
ssh deploy@<YOUR_VPS_IP>
cd /opt/vps-core-setup
sudo ./update-vps.sh
```
The script will pull the latest changes, copy them to the live monitoring directory, and restart the affected services. It's designed to be safe to run on a live system.

## 4. Documentation

For more detailed information, please refer to the following guides in the `docs/` directory:

*   **➡️ [`docs/DETAILED_SETUP_GUIDE.md`](./docs/DETAILED_SETUP_GUIDE.md):**
    *   In-depth explanation of the `vps-setup.sh` and `update-vps.sh` scripts.
    *   Details about the centralized monitoring stack (Prometheus, Grafana, etc.).
    *   Troubleshooting common setup issues.
    *   Security considerations.

*   **➡️ [`docs/APPLICATION_DEPLOYMENT_GUIDE.md`](./docs/APPLICATION_DEPLOYMENT_GUIDE.md):**
    *   Comprehensive guide for developers on deploying their Dockerized applications to a VPS provisioned with this setup.
    *   Covers application Dockerization, `docker-compose.yaml` setup, connecting to the central monitoring, and application lifecycle management.

## 5. Repository Contents

*   **`README.md`**: This file (Prerequisites, Quickstart, and links to further documentation).
*   **`vps-setup.sh`**: The main setup script to be run on the VPS. Includes integrated testing at the end.
*   **`update-vps.sh`**: A script to safely update the monitoring stack with the latest changes from the repository.
*   **`test-vps-setup.sh`**: Comprehensive test script that validates the entire setup (automatically called by `vps-setup.sh`).
*   **`monitoring/`**: Contains the canonical Docker Compose and Prometheus configuration files for the central monitoring stack, which are copied by `vps-setup.sh` to `/opt/monitoring/` on the VPS.
    *   `monitoring/docker-compose.monitoring.yml`
    *   `monitoring/prometheus_config/prometheus.yml`: Main Prometheus config.
    *   `monitoring/prometheus_config/conf.d/`: Directory for "drop-in" scrape configurations for core services and user applications.
    *   `monitoring/grafana/`: Contains provisioning configuration and JSON files for default dashboards (Node Exporter, cAdvisor, etc.).
*   **`test_assets/`**: Contains test applications and configurations used by the test script.
    *   `test_assets/dummy_app/`: Simple Flask application with Prometheus metrics for testing.
*   **`docs/`**: Contains detailed documentation.
    *   `docs/DETAILED_SETUP_GUIDE.md`: In-depth information about the setup script, monitoring, troubleshooting, and security.
    *   `docs/APPLICATION_DEPLOYMENT_GUIDE.md`: Guide for application developers.

---

This `vps-core-setup` aims to provide a solid foundation. Adapt and enhance it based on your specific project requirements and security policies.