#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(
  cd "$(dirname "${BASH_SOURCE[0]}")/.."
  pwd
)"

# shellcheck source=../sub2api-safe-upgrade.sh
source "${REPO_ROOT}/sub2api-safe-upgrade.sh"

TEST_ROOT="$(mktemp -d)"
cleanup_test_directory() {
  [[ "${TEST_ROOT}" == /tmp/tmp.* && -d "${TEST_ROOT}" ]] || return 0
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test_directory EXIT

BACKUP_DIR="${TEST_ROOT}"
fetch_and_verify_official_release "0.1.165"
verify_upstream_deployment_contract "0.1.164" "0.1.165"
fetch_target_migration_manifest "0.1.165"

[[ -s "${BACKUP_DIR}/target-release.json" ]]
[[ -s "${BACKUP_DIR}/official-compose.current.yml" ]]
[[ -s "${BACKUP_DIR}/official-compose.target.yml" ]]
[[ -s "${BACKUP_DIR}/official-env.current.example" ]]
[[ -s "${BACKUP_DIR}/official-env.target.example" ]]
[[ "$(wc -l < "${TARGET_MIGRATIONS_FILE}")" == "236" ]]

printf 'OFFICIAL_METADATA_TEST=PASS migrations=236\n'
