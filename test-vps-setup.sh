#!/bin/bash
#
# test-vps-setup.sh - Verifies the vps-core-setup and tests dummy app integration.
#
# This script should be run as the 'deploy' user on the VPS after vps-setup.sh
# has successfully completed.
# It assumes it's run from the root of the vps-core-setup repository checkout.

set -euo pipefail # Exit on error, treat unset variables as an error, propagate exit status through pipes

# --- Configuration ---
PROMETHEUS_URL="http://localhost:9090"
GRAFANA_URL="http://localhost:3000"
CENTRAL_PROM_CONFIG_PATH="/opt/monitoring/prometheus_config/prometheus.yml"
CENTRAL_PROM_CONFIG_BACKUP_PATH="/opt/monitoring/prometheus_config/prometheus.yml.test-bak"
DUMMY_APP_DIR="./test_assets/dummy_app" # Relative to the script location (repo root)
DUMMY_APP_COMPOSE_FILE="${DUMMY_APP_DIR}/docker-compose.dummy.yml"
DUMMY_APP_CONTAINER_NAME="dummy_app_container"
DUMMY_APP_METRICS_PORT="8008"
DUMMY_APP_SCRAPE_JOB_NAME="dummy-app-test-job"

REQUIRED_CMDS=("curl" "docker" "jq")

# --- Colors for Output ---
COL_RESET="\033[0m"
COL_GREEN="\033[0;32m"
COL_RED="\033[0;31m"
COL_YELLOW="\033[0;33m"
COL_BLUE="\033[0;34m"

# --- Helper Functions ---
step_count=0
failed_steps=0

print_step() {
    ((step_count++))
    echo -e "\n${COL_BLUE}>>> Step ${step_count}: $1${COL_RESET}"
}

pass_test() {
    echo -e "${COL_GREEN}✅ PASSED: $1${COL_RESET}"
}

fail_test() {
    echo -e "${COL_RED}❌ FAILED: $1${COL_RESET}"
    ((failed_steps++))
}

warn_test() {
    echo -e "${COL_YELLOW}⚠️ WARNING: $1${COL_RESET}"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        fail_test "Required command '$1' not found. Please install it."
        exit 1
    fi
    pass_test "Required command '$1' is available."
}

cleanup_and_exit() {
    print_step "Performing final cleanup (if necessary)..."

    echo "   Stopping dummy application (if running)..."
    if [ -f "${DUMMY_APP_COMPOSE_FILE}" ] && (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" ps -q); then
      (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" down -v)
      pass_test "Dummy application stack stopped and volumes removed."
    else
      echo "   Dummy application not running or compose file not found."
    fi

    if [ -f "${CENTRAL_PROM_CONFIG_BACKUP_PATH}" ]; then
        echo "   Restoring original Prometheus configuration from ${CENTRAL_PROM_CONFIG_BACKUP_PATH}..."
        sudo mv "${CENTRAL_PROM_CONFIG_BACKUP_PATH}" "${CENTRAL_PROM_CONFIG_PATH}"
        echo "   Reloading Prometheus configuration after restore..."
        if sudo curl -s -X POST "${PROMETHEUS_URL}/-/reload"; then
            pass_test "Prometheus configuration restored and reloaded."
        else
            warn_test "Failed to reload Prometheus after restoring config. Please check Prometheus manually."
        fi
    else
        echo "   No Prometheus backup file found at ${CENTRAL_PROM_CONFIG_BACKUP_PATH} to restore."
    fi

    if [ ${failed_steps} -gt 0 ]; then
        echo -e "\n${COL_RED}========================================="
        echo -e "    TEST SUITE COMPLETED WITH ERRORS    "
        echo -e "=========================================${COL_RESET}"
        echo -e "${COL_RED}Number of failed steps: ${failed_steps}${COL_RESET}"
    else
        echo -e "\n${COL_GREEN}========================================="
        echo -e "     TEST SUITE COMPLETED SUCCESSFULLY     "
        echo -e "=========================================${COL_RESET}"
    fi
    exit ${failed_steps}
}

# Trap SIGINT and SIGTERM to run cleanup function
trap cleanup_and_exit SIGINT SIGTERM

# --- Main Test Script --- #

print_step "Checking prerequisites..."
for cmd in "${REQUIRED_CMDS[@]}"; do
    check_command "$cmd"
done
if ! sudo -n true 2>/dev/null; then
    warn_test "User $(whoami) may need to enter password for sudo commands."
fi


print_step "Phase 1: Checking Core Monitoring Services Status..."
CORE_SERVICES=("central_prometheus" "central_grafana" "central_node_exporter" "central_cadvisor")
for service in "${CORE_SERVICES[@]}"; do
    if sudo docker ps -q --filter "name=^/${service}$" | grep -q .; then
        pass_test "Core service container '$service' is running."
    else
        fail_test "Core service container '$service' is NOT running."
    fi
done

# Check Prometheus UI Access
if curl -s -o /dev/null -w "%{http_code}" "${PROMETHEUS_URL}" | grep -q "200"; then
    pass_test "Prometheus UI (${PROMETHEUS_URL}) is accessible (HTTP 200)."
else
    fail_test "Prometheus UI (${PROMETHEUS_URL}) is NOT accessible."
fi

# Check Grafana UI Access
if curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_URL}" | grep -q "200"; then
    pass_test "Grafana UI (${GRAFANA_URL}) is accessible (HTTP 200)."
else
    fail_test "Grafana UI (${GRAFANA_URL}) is NOT accessible."
fi

if [ ${failed_steps} -gt 0 ]; then
    echo -e "${COL_RED}Critical core services check failed. Aborting further tests.${COL_RESET}"
    cleanup_and_exit
fi


print_step "Phase 2: Deploying Dummy Application (from ${DUMMY_APP_DIR})..."
if [ ! -d "${DUMMY_APP_DIR}" ]; then
    fail_test "Dummy application directory ${DUMMY_APP_DIR} not found."
    cleanup_and_exit
fi
if [ ! -f "${DUMMY_APP_COMPOSE_FILE}" ]; then
    fail_test "Dummy application compose file ${DUMMY_APP_COMPOSE_FILE} not found."
    cleanup_and_exit
fi

echo "   Building and starting dummy application..."
(cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" up -d --build --remove-orphans)
if [ $? -eq 0 ]; then
    pass_test "Dummy application \`docker compose up\` command executed successfully."
else
    fail_test "Dummy application \`docker compose up\` command failed."
    (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" logs)
    cleanup_and_exit
fi

echo "   Waiting for dummy application (${DUMMY_APP_CONTAINER_NAME}) to become healthy..."
HEALTH_STATUS_CMD="sudo docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' ${DUMMY_APP_CONTAINER_NAME}"
TIMEOUT_SECONDS=120 # 2 minutes
INTERVAL_SECONDS=5
ELAPSED_SECONDS=0
HEALTHY=false

while [ ${ELAPSED_SECONDS} -lt ${TIMEOUT_SECONDS} ]; do
    STATUS=$(eval "${HEALTH_STATUS_CMD}" 2>/dev/null || echo "inspect_error")
    if [ "${STATUS}" == "healthy" ]; then
        HEALTHY=true
        break
    fi
    if [ "${STATUS}" == "unhealthy" ]; then
        fail_test "Dummy application (${DUMMY_APP_CONTAINER_NAME}) reported as unhealthy."
        (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" logs)
        cleanup_and_exit
    fi
    if [ "${STATUS}" == "no healthcheck" ]; then
        warn_test "Dummy application (${DUMMY_APP_CONTAINER_NAME}) does not have a healthcheck configured in Docker. Assuming it started okay after a brief pause."
        sleep 15 # Give some time if no healthcheck
        HEALTHY=true # Assume healthy for test to proceed
        break
    fi
    sleep ${INTERVAL_SECONDS}
    ELAPSED_SECONDS=$((ELAPSED_SECONDS + INTERVAL_SECONDS))
    echo "   ... waiting (${ELAPSED_SECONDS}s / ${TIMEOUT_SECONDS}s), status: ${STATUS}"
done

if [ "${HEALTHY}" = true ]; then
    pass_test "Dummy application (${DUMMY_APP_CONTAINER_NAME}) is ready."
else
    fail_test "Dummy application (${DUMMY_APP_CONTAINER_NAME}) did not become healthy within ${TIMEOUT_SECONDS} seconds. Last status: ${STATUS}"
    (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" logs)
    cleanup_and_exit
fi


print_step "Phase 3: Configuring Central Prometheus to Scrape Dummy Application..."
# Backup Prometheus config
echo "   Backing up ${CENTRAL_PROM_CONFIG_PATH} to ${CENTRAL_PROM_CONFIG_BACKUP_PATH}..."
sudo cp "${CENTRAL_PROM_CONFIG_PATH}" "${CENTRAL_PROM_CONFIG_BACKUP_PATH}"
if [ $? -ne 0 ]; then
    fail_test "Failed to backup Prometheus configuration."
    cleanup_and_exit
fi
pass_test "Prometheus configuration backed up."

# Add scrape job for dummy app
SCRAPE_CONFIG_BLOCK="\n  - job_name: '${DUMMY_APP_SCRAPE_JOB_NAME}'\n    static_configs:\n      - targets: ['${DUMMY_APP_CONTAINER_NAME}:${DUMMY_APP_METRICS_PORT}']"

echo "   Adding scrape configuration for dummy app to ${CENTRAL_PROM_CONFIG_PATH}..."
echo -e "${SCRAPE_CONFIG_BLOCK}" | sudo tee -a "${CENTRAL_PROM_CONFIG_PATH}" > /dev/null
pass_test "Scrape configuration for dummy app added."

# Reload Prometheus
echo "   Reloading Prometheus configuration..."
RELOAD_OUTPUT=$(sudo curl -s -X POST "${PROMETHEUS_URL}/-/reload" -w "%{http_code}")
HTTP_CODE=${RELOAD_OUTPUT: -3}
if [ "${HTTP_CODE}" == "200" ]; then
    pass_test "Prometheus reloaded successfully (HTTP 200)."
else
    fail_test "Failed to reload Prometheus. HTTP code: ${HTTP_CODE}. Output: ${RELOAD_OUTPUT::-3}"
    cleanup_and_exit
fi


print_step "Phase 4: Verifying Prometheus Scraping of Dummy Application..."
# Give Prometheus time to scrape. Default scrape interval is 15s, let's wait a bit more.
SCRAPE_WAIT_SECONDS=35
echo "   Waiting ${SCRAPE_WAIT_SECONDS} seconds for Prometheus to scrape the new target..."
sleep ${SCRAPE_WAIT_SECONDS}

# Check target health
echo "   Checking dummy app target health in Prometheus..."
TARGET_HEALTH_URL="${PROMETHEUS_URL}/api/v1/targets?state=active"
TARGET_HEALTH=$(curl -s "${TARGET_HEALTH_URL}" | jq -r --arg job "${DUMMY_APP_SCRAPE_JOB_NAME}" '.data.activeTargets[] | select(.scrapePool == $job) | .health' 2>/dev/null)

if [ "${TARGET_HEALTH}" == "up" ]; then
    pass_test "Dummy app target ('${DUMMY_APP_SCRAPE_JOB_NAME}') is 'up' in Prometheus."
else
    fail_test "Dummy app target ('${DUMMY_APP_SCRAPE_JOB_NAME}') is NOT 'up' in Prometheus. Last reported health: '${TARGET_HEALTH:-Not Found}'."
    echo "   Debug: Check ${PROMETHEUS_URL}/targets"
    # Attempt to show scrape errors if any
    curl -s "${PROMETHEUS_URL}/api/v1/targets?state=active" | jq --arg job "${DUMMY_APP_SCRAPE_JOB_NAME}" '.data.activeTargets[] | select(.scrapePool == $job)' || echo "jq parse error or target not found"
fi

# Check specific metric value
echo "   Querying for metric 'dummy_app_static_value' from dummy app..."
METRIC_QUERY_URL="${PROMETHEUS_URL}/api/v1/query?query=dummy_app_static_value{\"${DUMMY_APP_SCRAPE_JOB_NAME}\"}"
METRIC_VALUE=$(curl -s "${METRIC_QUERY_URL}" | jq -r '.data.result[0].value[1]' 2>/dev/null)

if [ "${METRIC_VALUE}" == "42" ]; then
    pass_test "Metric 'dummy_app_static_value' successfully scraped with expected value (42)."
else
    fail_test "Metric 'dummy_app_static_value' not found or has incorrect value. Expected: 42, Got: '${METRIC_VALUE:-Not Found}'."
    echo "   Debug: Query URL: ${METRIC_QUERY_URL}"
    curl -s "${METRIC_QUERY_URL}" | jq '.' || echo "jq parse error or metric not found"
fi


# --- Trigger Cleanup --- #
# This will also report the final status
cleanup_and_exit 