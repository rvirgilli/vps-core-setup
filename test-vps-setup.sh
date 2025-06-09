#!/bin/bash
#
# test-vps-setup.sh - Verifies the vps-core-setup and tests dummy app integration.
#
# This script should be run as the 'deploy' user on the VPS after vps-setup.sh
# has successfully completed.
# It assumes it's run from the root of the vps-core-setup repository checkout.

set -euo pipefail # Exit on error, treat unset variables as an error, propagate exit status through pipes

# --- Configuration ---
PROMETHEUS_URL="http://127.0.0.1:9090"
GRAFANA_URL="http://127.0.0.1:3000"
CENTRAL_PROM_CONF_DIR="/opt/monitoring/prometheus_config/conf.d"
DUMMY_APP_PROM_CONFIG_FILE="${CENTRAL_PROM_CONF_DIR}/dummy-app-test.yml"
DUMMY_APP_DIR="./test_assets/dummy_app"
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
    step_count=$((step_count + 1))
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

    # Stop dummy application if running
    echo "   Stopping dummy application (if running)..."
    if [ -f "${DUMMY_APP_COMPOSE_FILE}" ] && (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" ps -q) > /dev/null 2>&1; then
        (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" down -v)
        pass_test "Dummy application stack stopped and volumes removed."
    else
        echo "   Dummy application not running."
    fi

    # Remove the dummy app's prometheus config file if it exists
    if [ -f "${DUMMY_APP_PROM_CONFIG_FILE}" ]; then
        echo "   Removing dummy app Prometheus configuration..."
        sudo rm -f "${DUMMY_APP_PROM_CONFIG_FILE}"
        echo "   Reloading Prometheus configuration..."
        if sudo curl -s -X POST "${PROMETHEUS_URL}/-/reload" > /dev/null 2>&1; then
            pass_test "Prometheus configuration reloaded after removing test file."
        else
            warn_test "Failed to reload Prometheus after removing test file. Please check manually."
        fi
    fi

    # Print final status
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

# Set up cleanup trap for SIGINT and SIGTERM
trap cleanup_and_exit SIGINT SIGTERM

# --- Main Test Script ---

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

# Check Prometheus UI access (accept 200 OK or 302 redirect)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${PROMETHEUS_URL}")
if [ "${HTTP_CODE}" -eq 200 ] || [ "${HTTP_CODE}" -eq 302 ]; then
    pass_test "Prometheus UI (${PROMETHEUS_URL}) is accessible (HTTP ${HTTP_CODE})."
else
    fail_test "Prometheus UI (${PROMETHEUS_URL}) is NOT accessible. HTTP code: ${HTTP_CODE}"
fi

# Check Grafana UI access (accept 200 OK or 302 redirect)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GRAFANA_URL}")
if [ "${HTTP_CODE}" -eq 200 ] || [ "${HTTP_CODE}" -eq 302 ]; then
    pass_test "Grafana UI (${GRAFANA_URL}) is accessible (HTTP ${HTTP_CODE})."
else
    fail_test "Grafana UI (${GRAFANA_URL}) is NOT accessible. HTTP code: ${HTTP_CODE}"
fi

# Exit early if core services aren't working
if [ ${failed_steps} -gt 0 ]; then
    echo -e "${COL_RED}Critical core services check failed. Aborting further tests.${COL_RESET}"
    cleanup_and_exit
fi

print_step "Phase 2: Deploying Dummy Application..."
# Validate required files exist
if [ ! -d "${DUMMY_APP_DIR}" ]; then
    fail_test "Dummy application directory ${DUMMY_APP_DIR} not found."
    cleanup_and_exit
fi
if [ ! -f "${DUMMY_APP_COMPOSE_FILE}" ]; then
    fail_test "Dummy application compose file ${DUMMY_APP_COMPOSE_FILE} not found."
    cleanup_and_exit
fi

# Deploy dummy application
echo "   Building and starting dummy application..."
if (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" up -d --build --remove-orphans); then
    pass_test "Dummy application deployed successfully."
else
    fail_test "Dummy application deployment failed."
    (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" logs)
    cleanup_and_exit
fi

# Wait for application to become healthy
echo "   Waiting for dummy application to become healthy..."
TIMEOUT_SECONDS=120
INTERVAL_SECONDS=5
ELAPSED_SECONDS=0
HEALTHY=false

while [ ${ELAPSED_SECONDS} -lt ${TIMEOUT_SECONDS} ]; do
    STATUS=$(sudo docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' ${DUMMY_APP_CONTAINER_NAME} 2>/dev/null || echo "inspect_error")
    
    case "${STATUS}" in
        "healthy")
            HEALTHY=true
            break
            ;;
        "unhealthy")
            fail_test "Dummy application reported as unhealthy."
            (cd "${DUMMY_APP_DIR}" && sudo docker compose -f "${DUMMY_APP_COMPOSE_FILE##*/}" logs)
            cleanup_and_exit
            ;;
        "no healthcheck")
            warn_test "No healthcheck configured. Assuming healthy after brief pause."
            sleep 15
            HEALTHY=true
            break
            ;;
    esac
    
    sleep ${INTERVAL_SECONDS}
    ELAPSED_SECONDS=$((ELAPSED_SECONDS + INTERVAL_SECONDS))
    echo "   ... waiting (${ELAPSED_SECONDS}s/${TIMEOUT_SECONDS}s), status: ${STATUS}"
done

if [ "${HEALTHY}" = true ]; then
    pass_test "Dummy application is ready."
else
    fail_test "Dummy application did not become healthy within ${TIMEOUT_SECONDS} seconds."
    cleanup_and_exit
fi

print_step "Phase 3: Configuring Prometheus to Scrape Dummy Application..."
# Create a dedicated scrape config file for the dummy app
echo "   Creating Prometheus scrape configuration file for dummy app..."
SCRAPE_CONFIG="- job_name: '${DUMMY_APP_SCRAPE_JOB_NAME}'\n  static_configs:\n    - targets: ['${DUMMY_APP_CONTAINER_NAME}:${DUMMY_APP_METRICS_PORT}']"

# Use a here-document with sudo tee to create the file as root
sudo tee "${DUMMY_APP_PROM_CONFIG_FILE}" > /dev/null << EOF
- job_name: '${DUMMY_APP_SCRAPE_JOB_NAME}'
  static_configs:
    - targets: ['${DUMMY_APP_CONTAINER_NAME}:${DUMMY_APP_METRICS_PORT}']
EOF

if [ -f "${DUMMY_APP_PROM_CONFIG_FILE}" ]; then
    pass_test "Scrape configuration file created at ${DUMMY_APP_PROM_CONFIG_FILE}."
else
    fail_test "Failed to create scrape configuration file."
    cleanup_and_exit
fi

# Reload Prometheus configuration
echo "   Reloading Prometheus configuration..."
RELOAD_OUTPUT=$(sudo curl -s -X POST "${PROMETHEUS_URL}/-/reload" -w "%{http_code}")
HTTP_CODE=${RELOAD_OUTPUT: -3}
if [ "${HTTP_CODE}" == "200" ]; then
    pass_test "Prometheus reloaded successfully."
else
    fail_test "Failed to reload Prometheus. HTTP code: ${HTTP_CODE}"
    cleanup_and_exit
fi

print_step "Phase 4: Verifying Prometheus Scraping..."
# Wait for Prometheus to scrape the new target
SCRAPE_WAIT_SECONDS=35
echo "   Waiting ${SCRAPE_WAIT_SECONDS} seconds for Prometheus to scrape the target..."
sleep ${SCRAPE_WAIT_SECONDS}

# Check target health in Prometheus
echo "   Verifying target health in Prometheus..."
TARGET_HEALTH=$(curl -s "${PROMETHEUS_URL}/api/v1/targets?state=active" | jq -r --arg job "${DUMMY_APP_SCRAPE_JOB_NAME}" '.data.activeTargets[] | select(.scrapePool == $job) | .health' 2>/dev/null)

if [ "${TARGET_HEALTH}" == "up" ]; then
    pass_test "Dummy app target is 'up' in Prometheus."
else
    fail_test "Dummy app target is not 'up'. Status: '${TARGET_HEALTH:-Not Found}'"
    echo "   Debug: Check ${PROMETHEUS_URL}/targets for more details."
fi

# Verify specific metric can be queried
echo "   Querying for test metric 'dummy_app_static_value'..."
METRIC_VALUE=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=dummy_app_static_value" | jq -r '.data.result[0].value[1]' 2>/dev/null)

if [ "${METRIC_VALUE}" == "42" ]; then
    pass_test "Metric 'dummy_app_static_value' successfully scraped with expected value (42)."
else
    fail_test "Metric query failed. Expected: 42, Got: '${METRIC_VALUE:-Not Found}'"
    echo "   Debug: Query URL: ${PROMETHEUS_URL}/api/v1/query?query=dummy_app_static_value"
fi

# Trigger cleanup and show final results
cleanup_and_exit 