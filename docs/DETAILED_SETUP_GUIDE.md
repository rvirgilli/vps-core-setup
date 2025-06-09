# Detailed VPS Setup Guide

This guide provides a more in-depth look at the `vps-setup.sh` script, the centralized monitoring stack, how to connect applications, troubleshooting, and security considerations for the `vps-core-setup` environment.

## 1. Understanding `vps-setup.sh`

This section provides a more in-depth look at the `vps-setup.sh` script and its operations.

### 1.1. Initial Access and Script Retrieval

1.  **(Optional) Clean Known Hosts:** If you've connected to this VPS IP before with a different OS install, remove the old host key from your local machine to prevent SSH errors:
    ```bash
    ssh-keygen -f ~/.ssh/known_hosts -R <YOUR_VPS_IP>
    ```

2.  **SSH into your VPS** as the initial user (e.g., `debian` or `root`):
    ```bash
    ssh debian@<YOUR_VPS_IP> # Or your initial sudo user
    ```

3.  **Clone the Repository:** The recommended way to get the script onto your VPS is by cloning this repository (assuming `git` is pre-installed). Since we are cloning into `/opt`, `sudo` is required for the `git clone` command.
    ```bash
    # Clone the repository into /opt (requires sudo)
    sudo git clone https://github.com/rvirgilli/vps-core-setup.git /opt/vps-core-setup
    ```
    This will place the script at `/opt/vps-core-setup/vps-setup.sh`. The `vps-setup.sh` script itself *must* also be run with `sudo`.

### 1.2. Make the Script Executable and Run

1.  Navigate to where the script is (if you cloned to `/opt`):
    ```bash
    cd /opt/vps-core-setup 
    ```
2.  Make the script executable (requires `sudo` if in `/opt`):
    ```bash
    sudo chmod +x vps-setup.sh
    ```
3.  Run the script (always requires `sudo`):
    ```bash
    sudo ./vps-setup.sh
    ```

### 1.3. Script Execution Steps

The `vps-setup.sh` script will perform the following actions:

1.  **System Updates & Basic Packages:** Updates package lists and installs `git`, `curl`, `ufw`.
2.  **Docker Installation:** Installs the latest Docker engine.
3.  **Docker Compose Plugin Installation:** Installs the Docker Compose plugin (for `docker compose` command).
4.  **`deploy` User Creation:**
    *   Creates a user named `deploy`.
    *   Adds `deploy` to the `docker` and `sudo` groups.
    *   Configures **passwordless `sudo`** for the `deploy` user via `/etc/sudoers.d/deploy`.
5.  **SSH Key for `deploy` User:**
    *   Copies the public SSH key(s) from the user running the script (e.g., `/home/debian/.ssh/authorized_keys` or `/root/.ssh/authorized_keys`) to `/home/deploy/.ssh/authorized_keys`. This allows you to immediately SSH as `deploy` using your existing local SSH key.
6.  **GitHub SSH Key for `deploy` User:**
    *   Generates a new ED25519 SSH key pair for the `deploy` user at `/home/deploy/.ssh/id_github`.
    *   **You will be prompted to copy the public key (`/home/deploy/.ssh/id_github.pub`) and add it to your GitHub account** (Settings -> SSH and GPG keys -> New SSH key). The script will pause until you press ENTER.
    *   Configures `/home/deploy/.ssh/config` to use this key for `github.com`.
    *   Tests SSH authentication to GitHub.
7.  **Central Monitoring Stack Deployment:**
    *   Creates configuration files at `/opt/monitoring/docker-compose.monitoring.yml` and `/opt/monitoring/prometheus_config/prometheus.yml`.
    *   Copies pre-configured Grafana dashboards and provisioning files to `/opt/monitoring/grafana/`.
    *   Starts the following services using Docker Compose. The services are named simply (e.g., `prometheus`), but the containers are given explicit `central_*` names for clarity (e.g., `container_name: central_prometheus`):
        *   `prometheus` (container: `central_prometheus`)
        *   `grafana` (container: `central_grafana`)
        *   `node-exporter` (container: `central_node_exporter`)
        *   `cadvisor` (container: `central_cadvisor`)
    *   These services are connected to a Docker network named `monitoring_network`.
8.  **UFW (Firewall) Configuration:**
    *   Denies all incoming traffic by default, allows all outgoing.
    *   Allows traffic on the following ports:
        *   `22/tcp` (OpenSSH)
        *   `80/tcp` (HTTP)
        *   `443/tcp` (HTTPS)
        *   `3000/tcp` (Grafana UI)
        *   `9090/tcp` (Prometheus UI)
        *   `8000-8999/tcp` (General application port range)
    *   Enables UFW.

### 1.4. After the Script Finishes

*   You should be able to SSH into the VPS as the `deploy` user: `ssh deploy@<YOUR_VPS_IP>`
*   The `deploy` user can run `docker` commands without `sudo`.
*   The central monitoring stack will be running.

## 2. Updating the Core Monitoring Stack

Over time, this `vps-core-setup` repository may receive updates, such as improved configurations, new Grafana dashboards, or security patches. A dedicated script, `update-vps.sh`, is provided to apply these updates safely.

To update your VPS:
1.  SSH into the VPS as `deploy` or another sudo-enabled user.
2.  Navigate to the cloned repository directory: `cd /opt/vps-core-setup`
3.  Run the update script with `sudo`:
    ```bash
    sudo ./update-vps.sh
    ```
The script will automatically:
1.  Pull the latest changes from the GitHub repository.
2.  Use `rsync` to copy the updated configurations to the live `/opt/monitoring` directory. This is done smartly to preserve files that are not part of the core setup.
3.  Run `docker compose up -d`, which will non-disruptively recreate only the services whose configurations have changed (e.g., Grafana if a new dashboard is added).

## 3. Centralized Monitoring Stack Details

The `vps-setup.sh` script deploys a monitoring stack using Docker Compose, located in `/opt/monitoring/` on the VPS.

### 3.1. Components

*   **Prometheus (`prometheus` service, `central_prometheus` container):**
    *   Collects and stores metrics.
    *   **UI:** `http://<YOUR_VPS_IP>:9090`
    *   **Configuration:** The main configuration is `/opt/monitoring/prometheus_config/prometheus.yml`. This file is set up to automatically load all scrape target configurations from the `/opt/monitoring/prometheus_config/conf.d/` directory.
    *   **Core Targets:** The default targets (Prometheus, Node Exporter, cAdvisor) are defined in `/opt/monitoring/prometheus_config/conf.d/core-targets.yml`.
    *   **Adding Your Apps:** To add a new application to be scraped, you will create a new `.yml` file inside the `conf.d` directory. This is the new recommended practice.
    *   **Data Volume:** Docker named volume `prometheus_data`.
*   **Grafana (`grafana` service, `central_grafana` container):**
    *   For visualizing metrics and creating dashboards.
    *   **UI:** `http://<YOUR_VPS_IP>:3000`
    *   **Default Login:** `admin` / `admin` (change this immediately!)
    *   **Default Dashboards:** The setup automatically provisions dashboards for Node Exporter, cAdvisor, and Prometheus itself, so you can immediately view key host and container metrics.
    *   **Data Volume:** Docker named volume `grafana_data`.
*   **Node Exporter (`node-exporter` service, `central_node_exporter` container):**
    *   Exposes a wide range of host machine metrics (CPU, memory, disk, network, etc.).
    *   Scraped by `prometheus`.
*   **cAdvisor (`cadvisor` service, `central_cadvisor` container):**
    *   Provides container-specific metrics (CPU, memory, network, etc. for each running Docker container).
    *   Scraped by `prometheus`.

### 3.2. Accessing UIs

*   **Prometheus:** `http://<YOUR_VPS_IP>:9090`
*   **Grafana:** `http://<YOUR_VPS_IP>:3000` (Login: `admin`/`admin` - **Change password on first login!**)

### 3.3. Managing Monitoring Services

The monitoring stack is managed by root using Docker Compose commands in the `/opt/monitoring` directory. Note that you must use the **service name** (e.g., `prometheus`), not the container name, in `docker compose` commands.

*   **View logs:**
    ```bash
    # Run as root or with sudo
    cd /opt/monitoring
    docker compose logs -f prometheus
    docker compose logs -f grafana
    # etc.
    ```
*   **Stop services:**
    ```bash
    sudo /bin/bash -c "cd /opt/monitoring && docker compose down"
    ```
*   **Start services:**
    ```bash
    sudo /bin/bash -c "cd /opt/monitoring && docker compose up -d"
    ```
*   **Restart a specific service (e.g., Prometheus after config change):**
    ```bash
    sudo /bin/bash -c "cd /opt/monitoring && docker compose restart prometheus"
    ```

## 4. Connecting Application Projects to Central Monitoring

For comprehensive instructions on deploying your application and connecting it to the central monitoring stack, please refer to:

➡️ **[`APPLICATION_DEPLOYMENT_GUIDE.md`](./APPLICATION_DEPLOYMENT_GUIDE.md)**

This guide covers:
*   Dockerizing your application.
*   Writing a `docker-compose.yaml` for your application that connects to the `monitoring_network`.
*   Deploying your application code to the VPS.
*   Adding a scrape job for your application by creating a new file in `/opt/monitoring/prometheus_config/conf.d/`.
*   Firewall considerations for your application.

**Brief Summary:**
1.  Ensure your application's Docker container/service connects to the external `monitoring_network`.
2.  Your application should expose metrics in a Prometheus-compatible format (e.g., on `/metrics`).
3.  On the VPS, create a new file, (e.g., `/opt/monitoring/prometheus_config/conf.d/my-app.yml`) with the scrape job for your application.
4.  Reload Prometheus: `curl -X POST http://localhost:9090/-/reload`.
5.  Once Prometheus scrapes your app, you can build dashboards for it in Grafana. Check the default dashboards first, as they may already show useful container-level metrics for your app.

## 5. Troubleshooting

*   **`update-vps.sh` fails:** Ensure you are in the `/opt/vps-core-setup` directory and are running the script with `sudo`.
*   **Script fails to run:** Ensure it's run with `sudo` (`sudo ./vps-setup.sh`).
*   **Docker or Docker Compose not found:** Check for errors during their installation steps in the script output.
*   **`deploy` user cannot run `docker` commands:** Verify `deploy` is in the `docker` group (`groups deploy`). You might need to log out and log back in as `deploy` for group changes to take effect.
*   **Passwordless `sudo` not working for `deploy`:** Check `/etc/sudoers.d/deploy` content and permissions (`sudo cat /etc/sudoers.d/deploy` should show `deploy ALL=(ALL) NOPASSWD:ALL`, `sudo ls -l /etc/sudoers.d/deploy` should show permissions `0440`).
*   **GitHub SSH test fails:**
    *   Ensure you correctly copied the *entire* public key output by the script (`/home/deploy/.ssh/id_github.pub`) to your GitHub account.
    *   Check for typos in `/home/deploy/.ssh/config`.
*   **Monitoring services fail to start:**
    *   Check logs: `sudo docker compose -f /opt/monitoring/docker-compose.monitoring.yml logs`
    *   Check Prometheus config syntax: `sudo docker exec central_prometheus promtool check config /etc/prometheus/prometheus.yml`
    *   Common issues: Port conflicts on the host (e.g., if 9090 or 3000 are already in use by another service not in Docker).
*   **UFW blocking access:** If you can't access Prometheus/Grafana UIs, double-check `sudo ufw status verbose` to ensure ports 3000 and 9090 are allowed.

## 6. Security Considerations

*   **Change Grafana Admin Password:** The default `admin/admin` is insecure. Change it immediately on first login.
*   **SSH Security:**
    *   Consider disabling password authentication for SSH and relying solely on key-based authentication (edit `/etc/ssh/sshd_config`).
    *   Keep your VPS system updated (`sudo apt update && sudo apt upgrade -y`).
*   **Firewall (UFW):** Only open ports that are absolutely necessary. The script opens a common application range (8000-8999); narrow this if possible for your specific needs or manage per-application.
*   **Docker Security:** Be mindful of the images you run. Use official images where possible. `privileged: true` for cAdvisor gives it extensive host access; understand the implications.
*   **Application Secrets:** Do not hardcode sensitive information in application Docker images or configurations. Use Docker secrets or environment variables injected securely at runtime.
*   **Prometheus `web.enable-lifecycle`:** While convenient for reloading config, be aware that the endpoint `/-/reload` is unauthenticated by default if Prometheus is exposed directly to the internet (which it shouldn't be without auth). The `vps-setup.sh` only exposes it to the host (port 9090), so reloading via `curl localhost:9090/-/reload` from the VPS itself is generally safe. 