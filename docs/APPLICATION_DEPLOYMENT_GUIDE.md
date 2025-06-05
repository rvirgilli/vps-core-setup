# Guide for Deploying Applications to a `vps-core-setup` Environment

This guide is for developers who want to deploy their Dockerized applications onto a Virtual Private Server (VPS) that has been provisioned using the `rvirgilli/vps-core-setup` repository.

## 1. Prerequisites: Your VPS Environment

When deploying your application, you can assume the following about the VPS environment:

*   **Operating System:** Debian 12.
*   **User `deploy`:** A non-root user named `deploy` exists with:
    *   Passwordless `sudo` privileges.
    *   Membership in the `docker` group (can run `docker` commands without `sudo`).
    *   SSH access configured (you should have its SSH key or be able to add yours).
    *   An SSH key pair at `/home/deploy/.ssh/id_github` configured for GitHub access.
*   **Docker & Docker Compose:** Docker engine and the Docker Compose plugin (`docker compose`) are installed and operational.
*   **Firewall (UFW):** UFW is active. Standard ports (22, 80, 443, 3000, 9090) and the application range `8000-8999/tcp` are open. If your application needs other ports, you'll need to open them using `sudo ufw allow <port>/tcp`.
*   **Centralized Monitoring:**
    *   A Docker network named `monitoring_network` exists.
    *   A central Prometheus instance (`central_prometheus`) is running and connected to `monitoring_network`, scraping metrics from host (Node Exporter) and containers (cAdvisor).
    *   A central Grafana instance (`central_grafana`) is running for dashboards.
    *   The Prometheus configuration is at `/opt/monitoring/prometheus_config/prometheus.yml` (editable by `deploy` with `sudo`).

## 2. Preparing Your Application for Deployment

### 2.1. Dockerize Your Application

Your application must be Dockerized. This involves creating a `Dockerfile` that defines how to build an image of your application.

*   **Example `Dockerfile` (Conceptual for a Python app):**
    ```dockerfile
    FROM python:3.9-slim

    WORKDIR /app

    # Copy dependency files and install dependencies
    COPY requirements.txt .
    RUN pip install --no-cache-dir -r requirements.txt

    # Copy application code
    COPY . .

    # Define the command to run your application
    CMD ["python", "your_app_main_file.py"]
    ```
*   Ensure your `Dockerfile` is efficient (e.g., use `.dockerignore`, multi-stage builds if applicable).

### 2.2. Application Configuration

*   **Parameterize:** Avoid hardcoding configuration (e.g., API keys, ports) in your application code or Docker image. Use environment variables or configuration files mounted into the container.
*   **Metrics Endpoint (Recommended):** If your application can expose metrics (e.g., request counts, error rates), make them available on an HTTP endpoint (commonly `/metrics`) in a Prometheus-compatible format.

### 2.3. Docker Compose for Your Application

Create a `docker-compose.yaml` file for your application. This simplifies deployment and management.

*   **Key considerations for your `docker-compose.yaml`:**
    *   Define your application service(s).
    *   Connect to the existing `monitoring_network`.
    *   Map necessary ports.
    *   Define and mount any necessary volumes for persistent data.

*   **Example `docker-compose.yaml` for `my-app`:**
    ```yaml
    version: '3.8'

    services:
      my-app-service: # Your application's service name
        build: .  # Assumes Dockerfile is in the same directory
        # Or use a pre-built image:
        # image: your-dockerhub-username/my-app-image:latest
        container_name: my_app_container # Consistent container name for easier targeting
        restart: unless-stopped
        ports:
          - "8080:80" # Example: Expose port 80 of container to port 8080 on host (within 8000-8999 range)
        environment:
          - APP_SETTING_1=value1
          # - METRICS_PORT=8001 # If your app needs to know its metrics port
        volumes:
          - ./my_app_data:/app/data # Example: Mount a local directory for persistent data
          # If you have a configuration file for your app:
          # - ./config/my_app_config.yaml:/app/config.yaml:ro
        networks:
          - default # For app-internal communication if you have multiple services for this app
          - central_monitoring_net

    networks:
      default:
        driver: bridge
      central_monitoring_net: # Definition to connect to the existing network
        name: monitoring_network
        external: true

    volumes:
      my_app_data: {} # Define a named volume if you prefer Docker to manage it
    ```

## 3. Deploying Your Application

1.  **SSH into the VPS as `deploy`:**
    ```bash
    ssh deploy@<YOUR_VPS_IP>
    ```

2.  **Get Your Application Code:**
    The `deploy` user has GitHub SSH keys set up. The most common method is to `git clone` your repository:
    ```bash
    cd /home/deploy # Or a preferred directory like /home/deploy/apps
    git clone git@github.com:<your_username>/<your_repo_name>.git
    cd <your_repo_name>
    ```

3.  **Prepare Configuration (if any):**
    If your application requires a configuration file that isn't part of the repository (e.g., production secrets), create it now on the VPS and ensure your `docker-compose.yaml` mounts it correctly.
    *Example: For `lob-collector`, you would create `config.production.yaml`.*

4.  **Build and Run with Docker Compose:**
    From your application's directory (where your `docker-compose.yaml` is):
    ```bash
    # Build the image (if your compose file uses `build: .`)
    docker compose build

    # Start the application in detached mode
    docker compose up -d
    ```

5.  **Verify Application:**
    *   Check logs: `docker compose logs -f` (or `docker compose logs -f my-app-service`)
    *   Test application functionality (e.g., `curl http://localhost:8080` if you mapped a port).

## 4. Integrating with Centralized Prometheus

If your application exposes metrics on a Prometheus-compatible endpoint (e.g., `my-app-service` on port `8001` at `/metrics`):

1.  **Edit Central Prometheus Configuration (as `deploy` with `sudo`):**
    ```bash
    sudo nano /opt/monitoring/prometheus_config/prometheus.yml
    ```

2.  **Add a Scrape Job:** Append a new job under `scrape_configs`:
    ```yaml
    # ... (existing scrape_configs) ...

    - job_name: 'my-app-service' # Or a more descriptive name for your app
      static_configs:
        # Target: <service_name_in_docker_compose>:<metrics_port_inside_container>
        # The service name is resolvable because both Prometheus and your app are on 'monitoring_network'
        - targets: ['my-app-service:8001'] # Assuming your app metrics are on port 8001
    ```
    *   **Target:** Use the service name defined in your application's `docker-compose.yaml` (e.g., `my-app-service`). Prometheus can resolve this name because it's on the same `monitoring_network`.

3.  **Save the file.**

4.  **Reload Central Prometheus Configuration:**
    ```bash
    curl -X POST http://localhost:9090/-/reload
    ```
    (Or restart: `sudo /bin/bash -c "cd /opt/monitoring && docker compose restart central_prometheus"`)

5.  **Verify in Prometheus UI:**
    *   Go to `http://<YOUR_VPS_IP>:9090` -> Status -> Targets.
    *   Your new job should appear and eventually show as `UP`.
    *   You can now query your application's metrics in Prometheus and build dashboards in Grafana (`http://<YOUR_VPS_IP>:3000`). Refer to the main `vps-core-setup/README.md` for Grafana basics.

## 5. Firewall Adjustments

*   The `vps-core-setup` opens ports `8000-8999/tcp`. If your application's host-mapped port (e.g., `8080` in the example `docker-compose.yaml`) falls within this range, it should be accessible externally.
*   If your application needs to expose a port **outside** this range, or needs UDP ports, you (as the `deploy` user) must add a UFW rule:
    ```bash
    sudo ufw allow <your_port>/tcp  # Or <your_port>/udp
    # Example: sudo ufw allow 7000/tcp
    ```

## 6. Application Lifecycle Management (as `deploy` user)

From your application's directory on the VPS:

*   **View logs:** `docker compose logs -f` or `docker compose logs -f <service_name>`
*   **Stop application:** `docker compose down`
*   **Stop and remove volumes (use with caution):** `docker compose down -v`
*   **Start application:** `docker compose up -d`
*   **Pull latest image and restart (if image is from a registry):** `docker compose pull && docker compose up -d --remove-orphans`
*   **Rebuild image and restart (if image is built locally):** `docker compose build && docker compose up -d --remove-orphans`

---

This guide should provide a solid starting point for deploying your applications. Always refer to your application's specific documentation and the main `vps-core-setup/README.md` for more details on the VPS environment itself. 