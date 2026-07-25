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
  rm -rf -- "${TEST_ROOT}"
}
trap cleanup_test_directory EXIT

BACKUP_DIR="${TEST_ROOT}"
MIGRATION_BASELINE_FILE="${BACKUP_DIR}/schema-migrations.before.tsv"
MIGRATION_BASELINE_NAMES_FILE="${BACKUP_DIR}/schema-migrations.before.txt"
TARGET_MIGRATIONS_FILE="${BACKUP_DIR}/target-migrations.txt"

cat > "${MIGRATION_BASELINE_FILE}" <<'EOF'
001_initial.sql|sha-old-1
002_accounts.sql|sha-old-2
EOF
cat > "${MIGRATION_BASELINE_NAMES_FILE}" <<'EOF'
001_initial.sql
002_accounts.sql
EOF
cat > "${TARGET_MIGRATIONS_FILE}" <<'EOF'
001_initial.sql
002_accounts.sql
003_live.sql
EOF

query_schema_migrations() {
  cat <<'EOF'
001_initial.sql|sha-old-1
002_accounts.sql|sha-old-2
003_live.sql|sha-new-3
EOF
}

verify_baseline_against_target_manifest "test"
verify_target_migrations

grep -Fxq '003_live.sql' "${BACKUP_DIR}/schema-migrations.new.txt"
grep -Fxq '001_initial.sql|sha-old-1' \
  "${BACKUP_DIR}/schema-migrations.after.tsv"
(
  cd "${BACKUP_DIR}"
  sha256sum -c POST-UPGRADE-SHA256SUMS >/dev/null
)

printf 'MIGRATION_MANIFEST_TEST=PASS\n'
