#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
)"

# shellcheck source=../sub2api-safe-upgrade.sh
source "${REPO_ROOT}/sub2api-safe-upgrade.sh"

CURRENT_IMAGE_TEST="weishaw/sub2api:0.1.164"
PUBLIC_HEALTH_URL="https://example.invalid/health"
AUTO_CUTOVER_WAIT_SECONDS=0
TEST_BACKUP_DIR=""

cleanup_test_directory() {
  if [[ -n "${TEST_BACKUP_DIR}" && -d "${TEST_BACKUP_DIR}" ]]; then
    rm -rf -- "${TEST_BACKUP_DIR}"
  fi
}
trap cleanup_test_directory EXIT

require_root() { :; }
require_commands() { :; }
acquire_lock() { :; }
validate_layout() { :; }
validate_runtime_layout() { :; }
verify_image_identity() { :; }
fetch_and_verify_official_release() { :; }
verify_upstream_deployment_contract() { :; }
container_exists() { :; }
container_running() { :; }
container_health() { printf 'healthy\n'; }
check_local_health() { :; }
free_space_gb() { printf '50\n'; }
get_current_image() { printf '%s\n' "${CURRENT_IMAGE_TEST}"; }
get_current_version() {
  printf '%s\n' "${CURRENT_IMAGE_TEST#weishaw/sub2api:}"
}
fetch_latest_official_version() { printf '0.1.165\n'; }
print_status() { :; }
backup_configuration() { :; }
pull_target_image() { :; }
backup_postgresql() { :; }
verify_baseline_against_target_manifest() { :; }
backup_redis() { :; }
confirm_cutover() { :; }
compose() { :; }
wait_for_application_health() { :; }
verify_target_migrations() { :; }
save_container_logs() { :; }
check_public_health() { :; }

create_backup_directory() {
  TEST_BACKUP_DIR="$(mktemp -d)"
  BACKUP_DIR="${TEST_BACKUP_DIR}"
  ORIGINAL_COMPOSE_BACKUP="${BACKUP_DIR}/docker-compose.yml.before-upgrade"
  : > "${ORIGINAL_COMPOSE_BACKUP}"
}

write_and_verify_checksums() {
  printf 'BACKUP_VERIFIED test\n' > "${BACKUP_DIR}/STATUS"
}

replace_compose_image() {
  CURRENT_IMAGE_TEST="weishaw/sub2api:$2"
  COMPOSE_EDITED=1
}

docker() {
  if [[ "${1:-}" == "inspect" ]]; then
    printf '%s\n' "${CURRENT_IMAGE_TEST}"
  fi
}

perform_upgrade latest

[[ "${CURRENT_IMAGE_TEST}" == "weishaw/sub2api:0.1.165" ]]
grep -q 'UPGRADE_SUCCESS' "${BACKUP_DIR}/STATUS"
[[ -f "${REPO_ROOT}/sub2api-safe-upgrade.sh" ]]

printf 'MOCKED_FULL_UPGRADE=PASS\n'
