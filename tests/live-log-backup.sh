#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
)"

# shellcheck source=../sub2api-safe-upgrade.sh
source "${REPO_ROOT}/sub2api-safe-upgrade.sh"

TEST_ROOT="$(mktemp -d)"
WRITER_PID=""

cleanup_test_directory() {
  if [[ -n "${WRITER_PID}" ]]; then
    kill "${WRITER_PID}" >/dev/null 2>&1 || true
    wait "${WRITER_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test_directory EXIT

STACK_DIR="${TEST_ROOT}/stack"
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
BACKUP_DIR="${TEST_ROOT}/backup"
ORIGINAL_COMPOSE_BACKUP="${BACKUP_DIR}/docker-compose.yml.before-upgrade"

mkdir -p "${STACK_DIR}/data/logs" "${STACK_DIR}/data/pages" "${BACKUP_DIR}"
printf 'services: {}\n' > "${COMPOSE_FILE}"
printf 'TEST_ONLY=1\n' > "${STACK_DIR}/.env"
printf 'example: true\n' > "${STACK_DIR}/data/config.yaml"
printf 'installed\n' > "${STACK_DIR}/data/.installed"
printf '{}\n' > "${STACK_DIR}/data/model_pricing.json"

(
  while true; do
    printf 'live log line %s\n' "${RANDOM}" \
      >> "${STACK_DIR}/data/logs/sub2api.log"
    sleep 0.01
  done
) &
WRITER_PID=$!

get_current_image() { printf 'weishaw/sub2api:0.1.164\n'; }
container_health() { printf 'healthy\n'; }
free_space_gb() { printf '50\n'; }
findmnt() {
  case "${*: -1}" in
    UUID)
      printf 'test-uuid\n'
      ;;
    SOURCE)
      printf '/dev/test\n'
      ;;
    FSTYPE)
      printf 'ext4\n'
      ;;
  esac
}
docker() {
  case "${1:-}" in
    version)
      printf '29.4.2\n'
      ;;
    compose)
      printf 'v5.1.3\n'
      ;;
  esac
}

backup_configuration

[[ -s "${BACKUP_DIR}/app-data.tar.gz" ]]
[[ ! -e "${BACKUP_DIR}/app-data.tar.gz.partial" ]]
tar -tzf "${BACKUP_DIR}/app-data.tar.gz" >/dev/null
tar -tzf "${BACKUP_DIR}/app-data.tar.gz" \
  > "${BACKUP_DIR}/app-data.contents"
grep -Fxq 'data/logs/' "${BACKUP_DIR}/app-data.contents"
if grep -Fq \
  'data/logs/sub2api.log' \
  "${BACKUP_DIR}/app-data.contents"; then
  printf 'Live log was unexpectedly included in the archive.\n' >&2
  exit 1
fi

: > "${BACKUP_DIR}/app-data.tar.gz.partial"
: > "${BACKUP_DIR}/sub2api.pgdump.partial"
cleanup_partial_backup
[[ ! -e "${BACKUP_DIR}/app-data.tar.gz.partial" ]]
[[ ! -e "${BACKUP_DIR}/sub2api.pgdump.partial" ]]
[[ -s "${BACKUP_DIR}/app-data.tar.gz" ]]

printf 'LIVE_LOG_BACKUP_TEST=PASS\n'
