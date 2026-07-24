#!/usr/bin/env bash
#
# Safe upgrade/rollback helper for the current Sub2API production stack.
#
# Current server layout this script is written for:
#   Stack directory : /www/sub2api
#   Compose file    : /www/sub2api/docker-compose.yml
#   App service     : sub2api
#   PostgreSQL      : sub2api-postgres
#   Redis           : sub2api-redis
#   Local health    : http://127.0.0.1:8080/health
#
# The script never runs `docker compose down`, never removes volumes, never
# prunes images, and never restores a database automatically.
#
# Usage:
#   bash sub2api-safe-upgrade.sh preflight
#   bash sub2api-safe-upgrade.sh upgrade 0.1.164
#   bash sub2api-safe-upgrade.sh status
#   bash sub2api-safe-upgrade.sh rollback /www/sub2api/backups/upgrade-...
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STACK_DIR="${STACK_DIR:-/www/sub2api}"
COMPOSE_FILE="${COMPOSE_FILE:-${STACK_DIR}/docker-compose.yml}"
APP_SERVICE="${APP_SERVICE:-sub2api}"
APP_CONTAINER="${APP_CONTAINER:-sub2api}"
PG_CONTAINER="${PG_CONTAINER:-sub2api-postgres}"
REDIS_CONTAINER="${REDIS_CONTAINER:-sub2api-redis}"
LOCAL_HEALTH_URL="${LOCAL_HEALTH_URL:-http://127.0.0.1:8080/health}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-}"
DEFAULT_TARGET_VERSION="${DEFAULT_TARGET_VERSION:-0.1.164}"
MIN_FREE_GB="${MIN_FREE_GB:-5}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-60}"
BACKUP_ROOT="${BACKUP_ROOT:-${STACK_DIR}/backups}"
IMAGE_REPOSITORY="weishaw/sub2api"

BACKUP_DIR=""
ORIGINAL_COMPOSE_BACKUP=""
COMPOSE_EDITED=0
CUTOVER_STARTED=0
FAILURE_HANDLER_RUNNING=0

timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(timestamp)" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(timestamp)" "$*" >&2
  return 1
}

usage() {
  cat <<'USAGE'
Sub2API production upgrade helper

Usage:
  bash sub2api-safe-upgrade.sh preflight
  bash sub2api-safe-upgrade.sh status
  bash sub2api-safe-upgrade.sh upgrade [target-version]
  bash sub2api-safe-upgrade.sh rollback <upgrade-backup-directory>

Examples:
  bash sub2api-safe-upgrade.sh preflight
  bash sub2api-safe-upgrade.sh upgrade 0.1.164
  bash sub2api-safe-upgrade.sh rollback \
    /www/sub2api/backups/upgrade-0.1.162-to-0.1.164-20260724-153000

Safety properties:
  - Backs up Compose, .env, application data, PostgreSQL, and Redis.
  - Verifies the PostgreSQL archive and backup checksums before cutover.
  - Pulls a version-pinned image.
  - Recreates only the Sub2API application container.
  - Leaves PostgreSQL, Redis, Caddy, volumes, and old images untouched.
  - Automatically restores the old application image if the new app is
    locally unhealthy.
  - Does not automatically restore PostgreSQL. Database restoration can
    discard post-upgrade writes and must be an explicit recovery decision.
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root."
  fi
}

require_commands() {
  local missing=()
  local command_name
  for command_name in docker curl awk grep sed tar df sha256sum flock date stat tee; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing+=("${command_name}")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    die "Missing required commands: ${missing[*]}"
  fi
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose plugin is unavailable."
}

acquire_lock() {
  exec 9>/var/lock/sub2api-upgrade.lock
  flock -n 9 || die "Another Sub2API upgrade/rollback process is running."
}

compose() {
  (
    cd "${STACK_DIR}"
    docker compose "$@"
  )
}

validate_layout() {
  [[ -d "${STACK_DIR}" ]] || die "Stack directory not found: ${STACK_DIR}"
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  [[ -f "${STACK_DIR}/.env" ]] || die ".env not found: ${STACK_DIR}/.env"
  [[ -d "${STACK_DIR}/data" ]] || die "Application data directory is missing."
  [[ -d "${STACK_DIR}/postgres_data" ]] ||
    die "PostgreSQL data directory is missing."
  [[ -d "${STACK_DIR}/redis_data" ]] ||
    die "Redis data directory is missing."

  compose config -q
  compose config --services | grep -Fxq "${APP_SERVICE}" ||
    die "Compose service not found: ${APP_SERVICE}"
}

container_exists() {
  docker inspect "$1" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

container_health() {
  docker inspect -f \
    '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
    "$1" 2>/dev/null || printf 'missing'
}

get_current_image() {
  local count
  local line
  count="$(
    grep -Ec \
      '^[[:space:]]*image:[[:space:]]*weishaw/sub2api:[^[:space:]#]+' \
      "${COMPOSE_FILE}" || true
  )"
  [[ "${count}" == "1" ]] ||
    die "Expected exactly one pinned weishaw/sub2api image line; found ${count}."

  line="$(
    grep -E \
      '^[[:space:]]*image:[[:space:]]*weishaw/sub2api:[^[:space:]#]+' \
      "${COMPOSE_FILE}"
  )"
  printf '%s\n' "${line}" |
    sed -E 's/^[[:space:]]*image:[[:space:]]*([^[:space:]#]+).*$/\1/'
}

get_current_version() {
  local image
  image="$(get_current_image)"
  printf '%s\n' "${image#${IMAGE_REPOSITORY}:}"
}

validate_version() {
  local version="$1"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Invalid release version: ${version}"
}

free_space_gb() {
  df -Pk "${STACK_DIR}" |
    awk 'NR == 2 { printf "%d\n", $4 / 1024 / 1024 }'
}

check_local_health() {
  curl --fail --silent --show-error \
    --connect-timeout 3 --max-time 10 \
    -o /dev/null "${LOCAL_HEALTH_URL}"
}

check_public_health() {
  [[ -n "${PUBLIC_HEALTH_URL}" ]] || return 2
  curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    -o /dev/null "${PUBLIC_HEALTH_URL}"
}

print_status() {
  local current_image
  current_image="$(get_current_image)"

  log "Compose image: ${current_image}"
  log "Application health: $(container_health "${APP_CONTAINER}")"
  log "PostgreSQL health: $(container_health "${PG_CONTAINER}")"
  log "Redis health: $(container_health "${REDIS_CONTAINER}")"
  log "Free space on ${STACK_DIR}: $(free_space_gb) GB"
  compose ps

  if check_local_health; then
    log "Local health endpoint: OK (${LOCAL_HEALTH_URL})"
  else
    warn "Local health endpoint failed: ${LOCAL_HEALTH_URL}"
  fi

  if [[ -z "${PUBLIC_HEALTH_URL}" ]]; then
    log "Public health endpoint: skipped (set PUBLIC_HEALTH_URL to enable it)"
  elif check_public_health; then
    log "Public health endpoint: OK (${PUBLIC_HEALTH_URL})"
  else
    warn "Public health endpoint failed: ${PUBLIC_HEALTH_URL}"
  fi
}

run_preflight() {
  local free_gb

  require_root
  require_commands
  acquire_lock
  validate_layout

  for container in "${APP_CONTAINER}" "${PG_CONTAINER}" "${REDIS_CONTAINER}"; do
    container_exists "${container}" || die "Container not found: ${container}"
    container_running "${container}" || die "Container is not running: ${container}"
  done

  [[ "$(container_health "${APP_CONTAINER}")" == "healthy" ]] ||
    die "Application container is not healthy."
  [[ "$(container_health "${PG_CONTAINER}")" == "healthy" ]] ||
    die "PostgreSQL container is not healthy."
  [[ "$(container_health "${REDIS_CONTAINER}")" == "healthy" ]] ||
    die "Redis container is not healthy."
  check_local_health || die "Local health endpoint is not healthy."

  free_gb="$(free_space_gb)"
  (( free_gb >= MIN_FREE_GB )) ||
    die "Only ${free_gb} GB free; at least ${MIN_FREE_GB} GB is required."

  log "Read-only preflight passed."
  print_status
}

create_backup_directory() {
  local current_version="$1"
  local target_version="$2"
  local stamp

  stamp="$(date '+%Y%m%d-%H%M%S')"
  BACKUP_DIR="${BACKUP_ROOT}/upgrade-${current_version}-to-${target_version}-${stamp}"
  ORIGINAL_COMPOSE_BACKUP="${BACKUP_DIR}/docker-compose.yml.before-upgrade"

  install -d -m 700 "${BACKUP_ROOT}"
  install -d -m 700 "${BACKUP_DIR}"
  exec > >(tee -a "${BACKUP_DIR}/upgrade.log") 2>&1

  log "Backup directory: ${BACKUP_DIR}"
}

backup_configuration() {
  log "Backing up Compose and application configuration..."

  cp -a "${COMPOSE_FILE}" "${ORIGINAL_COMPOSE_BACKUP}"
  cp -a "${STACK_DIR}/.env" "${BACKUP_DIR}/.env"

  if [[ -f "${STACK_DIR}/data/config.yaml" ]]; then
    cp -a "${STACK_DIR}/data/config.yaml" "${BACKUP_DIR}/config.yaml"
  fi
  if [[ -f "${STACK_DIR}/data/.installed" ]]; then
    cp -a "${STACK_DIR}/data/.installed" "${BACKUP_DIR}/.installed"
  fi

  tar --numeric-owner -czf "${BACKUP_DIR}/app-data.tar.gz" \
    -C "${STACK_DIR}" data

  {
    printf 'created_at=%s\n' "$(timestamp)"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'source_image=%s\n' "$(get_current_image)"
    printf 'docker_version=%s\n' "$(docker version --format '{{.Server.Version}}')"
    printf 'compose_version=%s\n' "$(docker compose version --short)"
    printf 'app_container_health=%s\n' "$(container_health "${APP_CONTAINER}")"
    printf 'postgres_container_health=%s\n' "$(container_health "${PG_CONTAINER}")"
    printf 'redis_container_health=%s\n' "$(container_health "${REDIS_CONTAINER}")"
    printf 'stack_free_gb=%s\n' "$(free_space_gb)"
  } > "${BACKUP_DIR}/metadata.txt"
}

backup_postgresql() {
  local dump_tmp="${BACKUP_DIR}/sub2api.pgdump.partial"
  local dump_final="${BACKUP_DIR}/sub2api.pgdump"

  log "Creating a fresh PostgreSQL custom-format dump..."
  docker exec "${PG_CONTAINER}" sh -lc '
    if command -v nice >/dev/null 2>&1; then
      exec nice -n 10 pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"
    fi
    exec pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"
  ' > "${dump_tmp}"

  [[ -s "${dump_tmp}" ]] || die "PostgreSQL dump is empty."
  mv "${dump_tmp}" "${dump_final}"

  log "Verifying PostgreSQL archive structure..."
  docker exec -i "${PG_CONTAINER}" sh -lc \
    'exec pg_restore -l >/dev/null' < "${dump_final}"

  docker exec "${PG_CONTAINER}" sh -lc \
    'exec pg_dumpall --globals-only -U "$POSTGRES_USER"' \
    > "${BACKUP_DIR}/postgres-globals.sql"
  [[ -s "${BACKUP_DIR}/postgres-globals.sql" ]] ||
    die "PostgreSQL globals backup is empty."

  log "PostgreSQL backup verified: $(stat -c '%s bytes' "${dump_final}")"
}

redis_cli() {
  local redis_args="$*"
  docker exec "${REDIS_CONTAINER}" sh -lc "
    if [ -n \"\${REDIS_PASSWORD:-}\" ]; then
      exec redis-cli --no-auth-warning -a \"\$REDIS_PASSWORD\" ${redis_args}
    fi
    exec redis-cli ${redis_args}
  "
}

backup_redis() {
  local info
  local completed=0
  local attempt

  log "Requesting a non-blocking Redis BGSAVE..."
  redis_cli BGSAVE >/dev/null

  for attempt in $(seq 1 60); do
    info="$(redis_cli INFO persistence | tr -d '\r')"
    if grep -q '^rdb_bgsave_in_progress:0$' <<<"${info}"; then
      if grep -q '^rdb_last_bgsave_status:ok$' <<<"${info}"; then
        completed=1
        break
      fi
      die "Redis reports that the last BGSAVE failed."
    fi
    sleep 1
  done

  (( completed == 1 )) || die "Redis BGSAVE did not finish within 60 seconds."

  docker cp \
    "${REDIS_CONTAINER}:/data/dump.rdb" \
    "${BACKUP_DIR}/redis-dump.rdb" >/dev/null
  [[ -s "${BACKUP_DIR}/redis-dump.rdb" ]] ||
    die "Redis RDB backup is empty."

  log "Redis backup verified: $(stat -c '%s bytes' "${BACKUP_DIR}/redis-dump.rdb")"
}

write_and_verify_checksums() {
  log "Writing and verifying backup checksums..."
  (
    cd "${BACKUP_DIR}"
    sha256sum \
      docker-compose.yml.before-upgrade \
      .env \
      app-data.tar.gz \
      metadata.txt \
      target-image.txt \
      sub2api.pgdump \
      postgres-globals.sql \
      redis-dump.rdb \
      > SHA256SUMS
    if [[ -f config.yaml ]]; then
      sha256sum config.yaml >> SHA256SUMS
    fi
    if [[ -f .installed ]]; then
      sha256sum .installed >> SHA256SUMS
    fi
    sha256sum -c SHA256SUMS
  )

  printf 'BACKUP_VERIFIED %s\n' "$(timestamp)" > "${BACKUP_DIR}/STATUS"
}

pull_target_image() {
  local target_image="$1"
  local image_platform

  log "Pulling target image without changing the running service: ${target_image}"
  docker pull "${target_image}"
  docker image inspect "${target_image}" >/dev/null

  image_platform="$(
    docker image inspect \
      -f '{{.Os}}/{{.Architecture}}' \
      "${target_image}"
  )"
  [[ "${image_platform}" == "linux/amd64" ]] ||
    die "Unexpected target image platform: ${image_platform}"

  docker image inspect \
    -f 'target_image_id={{.Id}} target_repo_digests={{json .RepoDigests}}' \
    "${target_image}" > "${BACKUP_DIR}/target-image.txt"
  log "Target image is present locally (${image_platform})."
}

confirm_cutover() {
  local current_version="$1"
  local target_version="$2"
  local expected="UPGRADE ${target_version}"
  local answer

  printf '\n'
  printf '%s\n' "Backup verification is complete."
  printf '%s\n' "Current version : ${current_version}"
  printf '%s\n' "Target version  : ${target_version}"
  printf '%s\n' "Backup directory: ${BACKUP_DIR}"
  printf '\n'
  printf '%s\n' "Before continuing, check the Sub2API operations dashboard:"
  printf '%s\n' "  1. QPS/RPM should be 0."
  printf '%s\n' "  2. There should be no active long-running or streaming request."
  printf '%s\n' "  3. Users should have been notified of the maintenance window."
  printf '\n'

  [[ -t 0 ]] ||
    die "Interactive terminal required for the production cutover confirmation."

  read -r -p "Type '${expected}' to continue: " answer
  [[ "${answer}" == "${expected}" ]] ||
    die "Confirmation did not match; no cutover was performed."
}

replace_compose_image() {
  local current_version="$1"
  local target_version="$2"
  local current_version_re
  local target_image="${IMAGE_REPOSITORY}:${target_version}"

  current_version_re="${current_version//./\\.}"

  log "Updating only the Sub2API image tag in docker-compose.yml..."
  sed -i -E \
    "s#^([[:space:]]*image:[[:space:]]*)${IMAGE_REPOSITORY}:${current_version_re}([[:space:]]*(#.*)?)\$#\\1${target_image}\\2#" \
    "${COMPOSE_FILE}"
  COMPOSE_EDITED=1

  [[ "$(get_current_image)" == "${target_image}" ]] ||
    die "Image tag replacement did not produce the expected result."
  compose config -q
  log "Compose validation passed with ${target_image}."
}

wait_for_application_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  local state

  while (( SECONDS < deadline )); do
    state="$(container_health "${APP_CONTAINER}")"
    if [[ "${state}" == "unhealthy" || "${state}" == "exited" || "${state}" == "dead" ]]; then
      warn "Application container state: ${state}"
      return 1
    fi

    if [[ "${state}" == "healthy" ]] && check_local_health; then
      log "Application is healthy."
      return 0
    fi
    sleep 2
  done

  warn "Application did not become healthy within ${HEALTH_TIMEOUT_SECONDS} seconds."
  return 1
}

verify_target_migrations() {
  local migration_count

  migration_count="$(
    docker exec -i "${PG_CONTAINER}" sh -lc \
      'exec psql -X -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
      <<'SQL'
SELECT count(*)
FROM schema_migrations
WHERE filename IN (
  '172_composite_model_routes.sql',
  '185_group_reasoning_effort_policy.sql',
  '186_alipay_mobile_precreate_deep_link.sql',
  '186_group_auth_cache_image_generation.sql'
);
SQL
  )"
  migration_count="$(tr -d '[:space:]' <<<"${migration_count}")"
  [[ "${migration_count}" == "4" ]] ||
    die "Expected 4 target migrations, but database reports ${migration_count:-none}."
  log "All four v0.1.164 database migrations are recorded."
}

save_container_logs() {
  local destination="$1"
  docker logs --since 10m "${APP_CONTAINER}" > "${destination}" 2>&1 || true
}

restore_old_application() {
  local reason="$1"

  (( FAILURE_HANDLER_RUNNING == 0 )) || return 0
  FAILURE_HANDLER_RUNNING=1
  trap - ERR INT TERM
  set +e

  warn "Starting automatic application rollback: ${reason}"

  if [[ -n "${BACKUP_DIR}" ]]; then
    save_container_logs "${BACKUP_DIR}/failed-target-container.log"
  fi

  if [[ -n "${ORIGINAL_COMPOSE_BACKUP}" && -f "${ORIGINAL_COMPOSE_BACKUP}" ]]; then
    cp -a "${ORIGINAL_COMPOSE_BACKUP}" "${COMPOSE_FILE}"
    COMPOSE_EDITED=0

    if compose config -q; then
      compose up -d --no-deps --force-recreate "${APP_SERVICE}"
      if wait_for_application_health; then
        warn "Old application image has been restored and is healthy."
        if [[ -n "${BACKUP_DIR}" ]]; then
          printf 'AUTO_ROLLBACK_COMPLETED %s\n' "$(timestamp)" \
            >> "${BACKUP_DIR}/STATUS"
        fi
      else
        warn "Automatic rollback was attempted, but the old app is not healthy."
      fi
    else
      warn "Original Compose file failed validation during rollback."
    fi
  else
    warn "Original Compose backup is unavailable; automatic rollback was not possible."
  fi
}

handle_error() {
  local rc="$1"
  local line="$2"

  trap - ERR INT TERM
  warn "Upgrade command failed at script line ${line} (exit ${rc})."
  if (( COMPOSE_EDITED == 1 || CUTOVER_STARTED == 1 )); then
    restore_old_application "upgrade failure"
  fi
  if [[ -n "${BACKUP_DIR}" ]]; then
    printf 'UPGRADE_FAILED %s line=%s exit=%s\n' \
      "$(timestamp)" "${line}" "${rc}" >> "${BACKUP_DIR}/STATUS"
  fi
  exit "${rc}"
}

handle_signal() {
  local signal_name="$1"

  trap - ERR INT TERM
  warn "Received ${signal_name}."
  if (( COMPOSE_EDITED == 1 || CUTOVER_STARTED == 1 )); then
    restore_old_application "interrupted by ${signal_name}"
  fi
  exit 130
}

perform_upgrade() {
  local target_version="${1:-${DEFAULT_TARGET_VERSION}}"
  local current_version
  local current_image
  local target_image

  require_root
  require_commands
  acquire_lock
  validate_layout
  validate_version "${target_version}"

  current_image="$(get_current_image)"
  current_version="$(get_current_version)"
  validate_version "${current_version}"
  target_image="${IMAGE_REPOSITORY}:${target_version}"

  if [[ "${current_version}" == "${target_version}" ]]; then
    log "Compose is already pinned to ${target_image}; nothing to upgrade."
    print_status
    return 0
  fi

  for container in "${APP_CONTAINER}" "${PG_CONTAINER}" "${REDIS_CONTAINER}"; do
    container_exists "${container}" || die "Container not found: ${container}"
    container_running "${container}" || die "Container is not running: ${container}"
  done
  [[ "$(container_health "${APP_CONTAINER}")" == "healthy" ]] ||
    die "Application container is not healthy before upgrade."
  [[ "$(container_health "${PG_CONTAINER}")" == "healthy" ]] ||
    die "PostgreSQL container is not healthy before upgrade."
  [[ "$(container_health "${REDIS_CONTAINER}")" == "healthy" ]] ||
    die "Redis container is not healthy before upgrade."
  check_local_health || die "Local health endpoint failed before upgrade."

  if (( $(free_space_gb) < MIN_FREE_GB )); then
    die "Insufficient free space for image pull and fresh backups."
  fi

  create_backup_directory "${current_version}" "${target_version}"
  trap 'handle_error $? $LINENO' ERR
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM

  log "Upgrade preparation: ${current_image} -> ${target_image}"
  backup_configuration
  pull_target_image "${target_image}"
  backup_postgresql
  backup_redis
  write_and_verify_checksums
  confirm_cutover "${current_version}" "${target_version}"

  replace_compose_image "${current_version}" "${target_version}"

  CUTOVER_STARTED=1
  log "Stopping only the application container with a ${STOP_TIMEOUT_SECONDS}s Docker timeout..."
  compose stop -t "${STOP_TIMEOUT_SECONDS}" "${APP_SERVICE}"

  log "Creating only the new application container; PostgreSQL and Redis remain running..."
  compose up -d --no-deps --force-recreate "${APP_SERVICE}"

  wait_for_application_health

  [[ "$(docker inspect -f '{{.Config.Image}}' "${APP_CONTAINER}")" == "${target_image}" ]] ||
    die "Running container does not use ${target_image}."

  verify_target_migrations
  save_container_logs "${BACKUP_DIR}/post-upgrade-container.log"
  compose ps

  if [[ -z "${PUBLIC_HEALTH_URL}" ]]; then
    log "Public health check skipped because PUBLIC_HEALTH_URL is unset."
  elif check_public_health; then
    log "Public health endpoint is healthy."
  else
    warn "Local app is healthy, but public health check failed. Inspect Caddy/DNS."
  fi

  printf 'UPGRADE_SUCCESS %s target=%s\n' \
    "$(timestamp)" "${target_version}" >> "${BACKUP_DIR}/STATUS"
  COMPOSE_EDITED=0
  CUTOVER_STARTED=0
  trap - ERR INT TERM

  log "Upgrade completed successfully: ${current_version} -> ${target_version}"
  log "Keep this backup and both Docker images until production is fully validated:"
  log "  ${BACKUP_DIR}"
  log "Do not run docker image prune yet."
}

confirm_rollback() {
  local backup_dir="$1"
  local answer

  printf '\n'
  printf '%s\n' "This performs an APPLICATION IMAGE rollback only."
  printf '%s\n' "It does not restore PostgreSQL or Redis."
  printf '%s\n' "Source backup: ${backup_dir}"
  printf '%s\n' "Confirm there are no active long-running requests."
  printf '\n'

  [[ -t 0 ]] || die "Interactive terminal required for rollback."
  read -r -p "Type 'ROLLBACK' to continue: " answer
  [[ "${answer}" == "ROLLBACK" ]] ||
    die "Rollback confirmation did not match."
}

perform_manual_rollback() {
  local source_backup="${1:-}"
  local saved_compose
  local rollback_record_dir
  local source_image
  local stamp

  require_root
  require_commands
  acquire_lock
  validate_layout

  [[ -n "${source_backup}" ]] ||
    die "Specify the upgrade backup directory to roll back from."
  [[ -d "${source_backup}" ]] || die "Backup directory not found: ${source_backup}"
  saved_compose="${source_backup}/docker-compose.yml.before-upgrade"
  [[ -f "${saved_compose}" ]] ||
    die "Original Compose backup not found: ${saved_compose}"

  source_image="$(
    grep -E \
      '^[[:space:]]*image:[[:space:]]*weishaw/sub2api:[^[:space:]#]+' \
      "${saved_compose}" |
      sed -E 's/^[[:space:]]*image:[[:space:]]*([^[:space:]#]+).*$/\1/'
  )"
  [[ "${source_image}" == "${IMAGE_REPOSITORY}:"* ]] ||
    die "Backup does not contain a recognized Sub2API image."

  confirm_rollback "${source_backup}"
  docker pull "${source_image}"

  stamp="$(date '+%Y%m%d-%H%M%S')"
  rollback_record_dir="${BACKUP_ROOT}/application-rollback-${stamp}"
  install -d -m 700 "${rollback_record_dir}"
  cp -a "${COMPOSE_FILE}" "${rollback_record_dir}/docker-compose.yml.before-rollback"
  cp -a "${saved_compose}" "${COMPOSE_FILE}"

  if ! compose config -q; then
    cp -a \
      "${rollback_record_dir}/docker-compose.yml.before-rollback" \
      "${COMPOSE_FILE}"
    die "Saved Compose file is invalid; current Compose file was restored."
  fi

  log "Stopping only the application container..."
  compose stop -t "${STOP_TIMEOUT_SECONDS}" "${APP_SERVICE}"
  compose up -d --no-deps --force-recreate "${APP_SERVICE}"

  if ! wait_for_application_health; then
    warn "Old application image is unhealthy; restoring the pre-rollback Compose file."
    save_container_logs "${rollback_record_dir}/failed-rollback-container.log"
    cp -a \
      "${rollback_record_dir}/docker-compose.yml.before-rollback" \
      "${COMPOSE_FILE}"
    compose config -q
    compose up -d --no-deps --force-recreate "${APP_SERVICE}"
    wait_for_application_health ||
      die "Both rollback and recovery application images are unhealthy."
    die "Rollback failed; the pre-rollback application image was restored."
  fi

  save_container_logs "${rollback_record_dir}/rollback-container.log"
  printf 'APPLICATION_ROLLBACK_SUCCESS %s source=%s\n' \
    "$(timestamp)" "${source_image}" > "${rollback_record_dir}/STATUS"
  compose ps

  log "Application rollback completed: ${source_image}"
  log "Database migrations were intentionally left in place."
}

main() {
  local action="${1:-help}"
  shift || true

  case "${action}" in
    preflight)
      run_preflight
      ;;
    status)
      require_root
      require_commands
      acquire_lock
      validate_layout
      print_status
      ;;
    upgrade)
      perform_upgrade "${1:-${DEFAULT_TARGET_VERSION}}"
      ;;
    rollback)
      perform_manual_rollback "${1:-}"
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      die "Unknown action: ${action}"
      ;;
  esac
}

main "$@"
