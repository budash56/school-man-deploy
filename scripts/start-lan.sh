#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed or is not on PATH." >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is not available. Install Docker Desktop or the Compose plugin." >&2
  exit 1
fi

if [ ! -f ".env" ]; then
  cp .env.example .env
  echo "Created .env from .env.example. Review secrets before using this outside local testing."
fi

ensure_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    return
  fi
  printf '%s=%s\n' "$key" "$value" >> .env
}

set_env_value() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
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
    ' .env > "$tmp_file"
    mv "$tmp_file" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
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

set_env_value "BIND_ADDRESS" "$BIND_ADDRESS"
set_env_value "DB_MIGRATIONS_RUN" "true"
ensure_env_value "SCANNER_BASE_URL" "http://scanner:8010"
ensure_env_value "SCANNER_TIMEOUT_MS" "120000"
ensure_env_value "SCHOOL_SCANNER_OCR_ENGINE" "tesseract"

echo "Building SchoolMan containers..."
docker compose build

echo "Starting SchoolMan..."
docker compose up -d

echo
docker compose ps
echo

if [ -n "${LAN_IP:-}" ]; then
  echo "Open on this machine:      http://localhost:8080"
  echo "Open from another device:  http://${LAN_IP}:8080"
else
  echo "Open on this machine:      http://localhost:8080"
  echo "Could not detect LAN IP automatically. Check your network settings and open http://YOUR_LOCAL_IP:8080 from another device."
fi

echo
echo "If this is the first run, PostgreSQL imports SchoolManBeta.sql while the db container starts."
echo "Watch logs with: docker compose logs -f db"
