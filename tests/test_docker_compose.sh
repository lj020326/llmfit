#!/usr/bin/env bash
set -euo pipefail

# Determine script directory to run docker compose correctly regardless of execution path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

COMPOSE_SERVICE_BACKEND="llmfit-backend"
COMPOSE_SERVICE_FRONTEND="llmfit-frontend"

echo "==> [1/4] Building Docker containers..."
docker compose -f "${COMPOSE_FILE}" build

echo "==> [2/4] Starting stack in background..."
docker compose -f "${COMPOSE_FILE}" up -d

cleanup() {
    echo "==> Cleaning up container stack..."
    docker compose -f "${COMPOSE_FILE}" down --volumes --remove-orphans
}
trap cleanup EXIT

echo "==> [3/4] Waiting for service healthcheck..."
TIMEOUT=30
ELAPSED=0

# shellcheck disable=SC2312
until [[ "$(docker inspect --format='{{.State.Health.Status}}' "${COMPOSE_SERVICE_FRONTEND}" 2>/dev/null)" == "healthy" ]]; do
    if [[ "${ELAPSED}" -ge "${TIMEOUT}" ]]; then
        echo "[ERROR] Timed out waiting for container to become healthy."
        docker compose -f "${COMPOSE_FILE}" logs
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "==> [4/4] Running endpoint verification tests..."

# Test Frontend Health
HTTP_HEALTH=$(docker exec "${COMPOSE_SERVICE_FRONTEND}" curl -s -o /dev/null -w "%{http_code}" http://localhost:8787/health)
if [[ "${HTTP_HEALTH}" -eq 200 ]]; then
    echo "  ✔ GET /health returned 200 OK"
else
    echo "  ✖ GET /health failed with code: ${HTTP_HEALTH}"
    exit 1
fi

# Test System Telemetry API
SYSTEM_HTTP_CODE=$(docker exec "${COMPOSE_SERVICE_BACKEND}" curl -s -o /dev/null -w "%{http_code}" http://localhost:8787/api/v1/system)
SYSTEM_JSON=$(docker exec "${COMPOSE_SERVICE_BACKEND}" curl -s http://localhost:8787/api/v1/system)

if [[ "${SYSTEM_HTTP_CODE}" -eq 200 ]] && [[ -n "${SYSTEM_JSON}" ]]; then
    echo "  ✔ GET /api/v1/system returned 200 OK with telemetry payload"
else
    echo "  ✖ GET /api/v1/system test failed (HTTP ${SYSTEM_HTTP_CODE})"
    echo "Response payload: ${SYSTEM_JSON}"
    exit 1
fi

echo "==> All integration tests passed successfully!"
