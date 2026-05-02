#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODE="${1:-production}"
case "$MODE" in
  production)
    ENV_FILE=".env.production"
    EXAMPLE_ENV_FILE=".env.production.example"
    COMPOSE_FILE_ARGS=(-f docker-compose.yml -f docker-compose.production.yml)
    PROJECT_NAME="school-man-production"
    DEPLOYMENT_NAME="school-man-production"
    FRONT_PORT="8080"
    BACK_PORT="3000"
    TEST_FEATURES="false"
    ;;
  testing)
    ENV_FILE=".env.testing"
    EXAMPLE_ENV_FILE=".env.testing.example"
    COMPOSE_FILE_ARGS=(-f docker-compose.yml -f docker-compose.testing.yml)
    PROJECT_NAME="school-man-testing"
    DEPLOYMENT_NAME="school-man-testing"
    FRONT_PORT="8081"
    BACK_PORT="3001"
    TEST_FEATURES="true"
    ;;
  *)
    echo "Usage: ./scripts/start-lan.sh [production|testing]" >&2
    exit 1
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or is not on PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is not available. Install Docker Desktop or the Compose plugin." >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  cp "$EXAMPLE_ENV_FILE" "$ENV_FILE"
  echo "Created $ENV_FILE from $EXAMPLE_ENV_FILE. Review secrets before using this outside local testing."
fi

ensure_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    return
  fi
  printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
}

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    tmp_file="$(mktemp)"
    awk -v key="$key" -v value="$value" '
      BEGIN { updated = 0 }
      $0 ~ "^" key "=" {
        print key "=" value
        updated = 1
        next
      }
      { print }
      END {
        if (updated == 0) {
          print key "=" value
        }
      }
    ' "$ENV_FILE" > "$tmp_file"
    mv "$tmp_file" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
  fi
}

detect_lan_ip() {
  if command -v ipconfig >/dev/null 2>&1; then
    ipconfig getifaddr en0 2>/dev/null && return
    ipconfig getifaddr en1 2>/dev/null && return
  fi

  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | awk '{print $1}' && return
  fi

  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}' && return
  fi
}

LAN_IP="$(detect_lan_ip || true)"
BIND_ADDRESS="${LAN_IP:-0.0.0.0}"

set_env_value "COMPOSE_PROJECT_NAME" "$PROJECT_NAME"
set_env_value "DEPLOYMENT_NAME" "$DEPLOYMENT_NAME"
set_env_value "BIND_ADDRESS" "$BIND_ADDRESS"
set_env_value "DB_MIGRATIONS_RUN" "true"
set_env_value "FRONT_PORT" "$FRONT_PORT"
set_env_value "BACK_PORT" "$BACK_PORT"
set_env_value "VITE_ENABLE_TEST_FEATURES" "$TEST_FEATURES"
ensure_env_value "SCANNER_BASE_URL" "http://scanner:8010"
ensure_env_value "SCANNER_TIMEOUT_MS" "120000"
ensure_env_value "SCHOOL_SCANNER_OCR_ENGINE" "tesseract"

compose() {
  docker compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" "${COMPOSE_FILE_ARGS[@]}" "$@"
}

echo "Building SchoolMan $MODE containers..."
compose build

echo "Starting SchoolMan $MODE..."
compose up -d

echo
compose ps
echo

if [ -n "${LAN_IP:-}" ]; then
  echo "Open on this machine:      http://localhost:${FRONT_PORT}"
  echo "Open from another device:  http://${LAN_IP}:${FRONT_PORT}"
else
  echo "Open on this machine:      http://localhost:${FRONT_PORT}"
  echo "Could not detect LAN IP automatically. Check your network settings and open http://YOUR_LOCAL_IP:${FRONT_PORT} from another device."
fi

echo
echo "If this is the first run, PostgreSQL imports SchoolManBeta.sql while the db container starts."
echo "Watch logs with: docker compose --env-file ${ENV_FILE} -p ${PROJECT_NAME} ${COMPOSE_FILE_ARGS[*]} logs -f db"
