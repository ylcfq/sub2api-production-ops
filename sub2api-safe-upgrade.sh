#!/usr/bin/env bash
#
# Safe upgrade/rollback helper for the current Sub2API production stack.
#
# Current server layout this script is written for:
#   Data mount      : /srv (dedicated ext4 disk)
#   Stack directory : /srv/sub2api
#   Compose file    : /srv/sub2api/docker-compose.yml
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
#   bash sub2api-safe-upgrade.sh upgrade 0.1.165
#   bash sub2api-safe-upgrade.sh upgrade-latest
#   bash sub2api-safe-upgrade.sh status
#   bash sub2api-safe-upgrade.sh rollback /srv/sub2api/backups/upgrade-...
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

DATA_MOUNT="${DATA_MOUNT:-/srv}"
EXPECTED_DATA_UUID="${EXPECTED_DATA_UUID:-0bdbc4d2-baf6-4496-8cc0-5097d5fafe23}"
STACK_DIR="${STACK_DIR:-/srv/sub2api}"
COMPOSE_FILE="${COMPOSE_FILE:-${STACK_DIR}/docker-compose.yml}"
APP_SERVICE="${APP_SERVICE:-sub2api}"
APP_CONTAINER="${APP_CONTAINER:-sub2api}"
PG_CONTAINER="${PG_CONTAINER:-sub2api-postgres}"
REDIS_CONTAINER="${REDIS_CONTAINER:-sub2api-redis}"
LOCAL_HEALTH_URL="${LOCAL_HEALTH_URL:-http://127.0.0.1:8080/health}"
PUBLIC_HEALTH_URL="${PUBLIC_HEALTH_URL:-}"
DELETE_SCRIPT_ON_SUCCESS="${DELETE_SCRIPT_ON_SUCCESS:-0}"
ALLOW_SCHEMA_MISMATCH_ROLLBACK="${ALLOW_SCHEMA_MISMATCH_ROLLBACK:-0}"
DEFAULT_TARGET_VERSION="${DEFAULT_TARGET_VERSION:-0.1.165}"
OFFICIAL_LATEST_RELEASE_API="${OFFICIAL_LATEST_RELEASE_API:-https://api.github.com/repos/Wei-Shaw/sub2api/releases/latest}"
OFFICIAL_RELEASE_TAG_API_BASE="${OFFICIAL_RELEASE_TAG_API_BASE:-https://api.github.com/repos/Wei-Shaw/sub2api/releases/tags}"
OFFICIAL_MIGRATIONS_API_BASE="${OFFICIAL_MIGRATIONS_API_BASE:-https://api.github.com/repos/Wei-Shaw/sub2api/contents/backend/migrations}"
OFFICIAL_RAW_BASE="${OFFICIAL_RAW_BASE:-https://raw.githubusercontent.com/Wei-Shaw/sub2api}"
AUTO_CUTOVER_WAIT_SECONDS="${AUTO_CUTOVER_WAIT_SECONDS:-30}"
MIN_FREE_GB="${MIN_FREE_GB:-8}"
HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-60}"
BACKUP_ROOT="${BACKUP_ROOT:-${STACK_DIR}/backups}"
IMAGE_REPOSITORY="weishaw/sub2api"
EXPECTED_IMAGE_SOURCE="https://github.com/Wei-Shaw/sub2api"
SCRIPT_VERSION="2026.07.26-srv1"

BACKUP_DIR=""
ORIGINAL_COMPOSE_BACKUP=""
MIGRATION_BASELINE_FILE=""
MIGRATION_BASELINE_NAMES_FILE=""
TARGET_MIGRATIONS_FILE=""
COMPOSE_EDITED=0
CUTOVER_STARTED=0
FAILURE_HANDLER_RUNNING=0
AUTO_CUTOVER=0
CURRENT_STAGE="初始化"
CURRENT_STEP=0
TOTAL_UPGRADE_STEPS=10
STAGE_STARTED_AT=0
UPGRADE_STARTED_AT=0
CUTOVER_STARTED_AT=0
CUTOVER_DURATION=0
REDIS_CLI_MODE=""
PUBLIC_HEALTH_STATUS="未检查"
PUBLIC_HEALTH_FAILED=0

timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
  printf '[%s] [状态] %s\n' "$(timestamp)" "$*"
}

warn() {
  printf '[%s] [警告] %s\n' "$(timestamp)" "$*" >&2
}

die() {
  printf '[%s] [错误] %s\n' "$(timestamp)" "$*" >&2
  return 1
}

human_bytes() {
  local bytes="${1:-0}"
  awk -v value="${bytes}" '
    function human(x) {
      split("B KiB MiB GiB TiB", units, " ")
      unit = 1
      while (x >= 1024 && unit < 5) {
        x /= 1024
        unit++
      }
      if (unit == 1) {
        return sprintf("%.0f %s", x, units[unit])
      }
      return sprintf("%.2f %s", x, units[unit])
    }
    BEGIN { print human(value + 0) }
  '
}

format_duration() {
  local total="${1:-0}"
  local hours=$((total / 3600))
  local minutes=$(((total % 3600) / 60))
  local seconds=$((total % 60))

  if (( hours > 0 )); then
    printf '%d小时%02d分%02d秒' "${hours}" "${minutes}" "${seconds}"
  elif (( minutes > 0 )); then
    printf '%d分%02d秒' "${minutes}" "${seconds}"
  else
    printf '%d秒' "${seconds}"
  fi
}

stage_start() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  CURRENT_STAGE="$1"
  STAGE_STARTED_AT="${SECONDS}"
  printf '\n'
  printf '================================================================\n'
  printf '[步骤 %d/%d] %s\n' \
    "${CURRENT_STEP}" "${TOTAL_UPGRADE_STEPS}" "${CURRENT_STAGE}"
  printf '================================================================\n'
}

stage_finish() {
  local elapsed=$((SECONDS - STAGE_STARTED_AT))
  log "步骤完成：${CURRENT_STAGE}（耗时 $(format_duration "${elapsed}")）"
}

usage() {
  cat <<'USAGE'
Sub2API production upgrade helper

Usage:
  bash sub2api-safe-upgrade.sh preflight
  bash sub2api-safe-upgrade.sh status
  bash sub2api-safe-upgrade.sh upgrade [target-version]
  bash sub2api-safe-upgrade.sh upgrade-latest
  bash sub2api-safe-upgrade.sh rollback <upgrade-backup-directory>

Examples:
  bash sub2api-safe-upgrade.sh preflight
  bash sub2api-safe-upgrade.sh upgrade 0.1.165
  bash sub2api-safe-upgrade.sh upgrade-latest
  bash sub2api-safe-upgrade.sh rollback \
    /srv/sub2api/backups/upgrade-0.1.164-to-0.1.165-20260726-153000

Safety properties:
  - Backs up Compose, .env, application data, PostgreSQL, and Redis.
  - Verifies the PostgreSQL archive and backup checksums before cutover.
  - Requires the dedicated /srv data disk and Docker mount guard.
  - `upgrade-latest` obtains the latest official non-prerelease GitHub release.
  - Compares the target release's official migration manifest with the database.
  - Pulls a version-pinned image.
  - Verifies the image's source/version labels and linux/amd64 platform.
  - Recreates only the Sub2API application container.
  - Leaves PostgreSQL, Redis, Caddy, volumes, and old images untouched.
  - Removes only an incomplete PostgreSQL .partial file after failure/success.
  - Keeps this script by default. Set DELETE_SCRIPT_ON_SUCCESS=1 to delete
    only /root/sub2api-safe-upgrade.sh after a fully successful upgrade.
  - Never deletes verified backups or old Docker images automatically.
  - Automatically restores the old application image only when the database
    migration set is unchanged. It refuses an unsafe image-only rollback after
    forward-only migrations have changed the schema.
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
  for command_name in \
    docker curl awk grep sed tar df du sha256sum flock date stat tee seq \
    readlink rm findmnt mountpoint systemctl sort comm cmp install cp mv \
    tail tr sleep hostname diff; do
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

validate_data_mount() {
  local mount_uuid
  local mount_fstype
  local mount_options
  local stack_mount_target
  local docker_requires

  [[ "${DATA_MOUNT}" == /* ]] ||
    die "DATA_MOUNT must be an absolute path: ${DATA_MOUNT}"
  [[ "${STACK_DIR}" == "${DATA_MOUNT}/"* ]] ||
    die "STACK_DIR must be below ${DATA_MOUNT}: ${STACK_DIR}"
  mountpoint -q "${DATA_MOUNT}" ||
    die "${DATA_MOUNT} is not a mounted filesystem; refusing to use a system-disk fallback directory."

  stack_mount_target="$(findmnt -n -T "${STACK_DIR}" -o TARGET)"
  [[ "${stack_mount_target}" == "${DATA_MOUNT}" ]] ||
    die "${STACK_DIR} is backed by ${stack_mount_target:-unknown}, expected ${DATA_MOUNT}."

  mount_uuid="$(findmnt -n -T "${DATA_MOUNT}" -o UUID)"
  mount_fstype="$(findmnt -n -T "${DATA_MOUNT}" -o FSTYPE)"
  mount_options="$(findmnt -n -T "${DATA_MOUNT}" -o OPTIONS)"

  [[ "${mount_uuid}" == "${EXPECTED_DATA_UUID}" ]] ||
    die "Unexpected ${DATA_MOUNT} UUID: ${mount_uuid:-unknown}; expected ${EXPECTED_DATA_UUID}."
  [[ "${mount_fstype}" == "ext4" ]] ||
    die "Unexpected ${DATA_MOUNT} filesystem: ${mount_fstype:-unknown}; expected ext4."
  [[ ",${mount_options}," == *,rw,* ]] ||
    die "${DATA_MOUNT} is not mounted read-write."

  docker_requires="$(systemctl show docker.service -p RequiresMountsFor --value)"
  grep -Eq "(^|[[:space:]])${DATA_MOUNT}([[:space:]]|$)" <<<"${docker_requires}" ||
    die "docker.service does not declare RequiresMountsFor=${DATA_MOUNT}."
  systemctl cat docker.service |
    grep -Fxq "AssertPathIsMountPoint=${DATA_MOUNT}" ||
    die "docker.service does not assert that ${DATA_MOUNT} is a mount point."

  log "数据盘保护通过：${DATA_MOUNT} (${mount_fstype}, UUID=${mount_uuid}, rw)，Docker 挂载依赖有效。"
}

validate_layout() {
  validate_data_mount
  [[ -d "${STACK_DIR}" ]] || die "Stack directory not found: ${STACK_DIR}"
  [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
  [[ -f "${STACK_DIR}/.env" ]] || die ".env not found: ${STACK_DIR}/.env"
  [[ -d "${STACK_DIR}/data" ]] || die "Application data directory is missing."
  [[ -d "${STACK_DIR}/postgres_data" ]] ||
    die "PostgreSQL data directory is missing."
  [[ -d "${STACK_DIR}/redis_data" ]] ||
    die "Redis data directory is missing."
  [[ "$(stat -c '%a' "${STACK_DIR}/.env")" == "600" ]] ||
    die "${STACK_DIR}/.env must have mode 600."

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

container_mount_source() {
  local container_name="$1"
  local destination="$2"

  docker inspect -f \
    "{{range .Mounts}}{{if eq .Destination \"${destination}\"}}{{.Source}}{{end}}{{end}}" \
    "${container_name}"
}

validate_runtime_layout() {
  local app_mount
  local pg_mount
  local redis_mount
  local app_binding
  local pg_bindings
  local redis_bindings
  local compose_image
  local runtime_image

  app_mount="$(container_mount_source "${APP_CONTAINER}" "/app/data")"
  pg_mount="$(container_mount_source "${PG_CONTAINER}" "/var/lib/postgresql/data")"
  redis_mount="$(container_mount_source "${REDIS_CONTAINER}" "/data")"

  [[ "$(readlink -f -- "${app_mount}")" == "$(readlink -f -- "${STACK_DIR}/data")" ]] ||
    die "Application data mount mismatch: ${app_mount:-missing}"
  [[ "$(readlink -f -- "${pg_mount}")" == "$(readlink -f -- "${STACK_DIR}/postgres_data")" ]] ||
    die "PostgreSQL data mount mismatch: ${pg_mount:-missing}"
  [[ "$(readlink -f -- "${redis_mount}")" == "$(readlink -f -- "${STACK_DIR}/redis_data")" ]] ||
    die "Redis data mount mismatch: ${redis_mount:-missing}"

  app_binding="$(docker port "${APP_CONTAINER}" 8080/tcp 2>/dev/null || true)"
  [[ "${app_binding}" == "127.0.0.1:8080" ]] ||
    die "Application port must be bound only to 127.0.0.1:8080; found ${app_binding:-no binding}."
  pg_bindings="$(docker port "${PG_CONTAINER}" 2>/dev/null || true)"
  redis_bindings="$(docker port "${REDIS_CONTAINER}" 2>/dev/null || true)"
  [[ -z "${pg_bindings}" ]] ||
    die "PostgreSQL unexpectedly publishes a host port: ${pg_bindings}"
  [[ -z "${redis_bindings}" ]] ||
    die "Redis unexpectedly publishes a host port: ${redis_bindings}"

  compose_image="$(get_current_image)"
  runtime_image="$(docker inspect -f '{{.Config.Image}}' "${APP_CONTAINER}")"
  [[ "${runtime_image}" == "${compose_image}" ]] ||
    die "Running application image ${runtime_image} differs from Compose ${compose_image}."

  log "运行布局核对通过：三项持久化目录均位于 ${STACK_DIR}，仅应用端口绑定 127.0.0.1:8080。"
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

verify_image_identity() {
  local image="$1"
  local expected_version="$2"
  local image_platform
  local image_source
  local image_version

  docker image inspect "${image}" >/dev/null
  image_platform="$(
    docker image inspect -f '{{.Os}}/{{.Architecture}}' "${image}"
  )"
  image_source="$(
    docker image inspect \
      -f '{{index .Config.Labels "org.opencontainers.image.source"}}' \
      "${image}"
  )"
  image_version="$(
    docker image inspect \
      -f '{{index .Config.Labels "org.opencontainers.image.version"}}' \
      "${image}"
  )"

  [[ "${image_platform}" == "linux/amd64" ]] ||
    die "Unexpected image platform for ${image}: ${image_platform}"
  [[ "${image_source}" == "${EXPECTED_IMAGE_SOURCE}" ]] ||
    die "Unexpected image source label for ${image}: ${image_source:-missing}"
  [[ "${image_version}" == "${expected_version}" ]] ||
    die "Unexpected image version label for ${image}: ${image_version:-missing}"
}

get_current_version() {
  local image
  image="$(get_current_image)"
  printf '%s\n' "${image#"${IMAGE_REPOSITORY}":}"
}

version_is_newer() {
  local current="$1"
  local target="$2"
  local highest

  highest="$(
    printf '%s\n%s\n' "${current}" "${target}" |
      sort -V |
      tail -n 1
  )"
  [[ "${highest}" == "${target}" && "${current}" != "${target}" ]]
}

validate_version() {
  local version="$1"
  [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Invalid release version: ${version}"
}

validate_cleanup_settings() {
  [[ "${DELETE_SCRIPT_ON_SUCCESS}" == "0" ||
    "${DELETE_SCRIPT_ON_SUCCESS}" == "1" ]] ||
    die "DELETE_SCRIPT_ON_SUCCESS must be 0 or 1."
  [[ "${ALLOW_SCHEMA_MISMATCH_ROLLBACK}" == "0" ||
    "${ALLOW_SCHEMA_MISMATCH_ROLLBACK}" == "1" ]] ||
    die "ALLOW_SCHEMA_MISMATCH_ROLLBACK must be 0 or 1."
}

fetch_latest_official_version() {
  local release_json
  local tag_name
  local version

  log "正在查询 Wei-Shaw/sub2api 官方最新正式版..." >&2
  release_json="$(
    curl --fail --silent --show-error --location \
      --retry 3 --retry-delay 2 \
      --connect-timeout 5 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "${OFFICIAL_LATEST_RELEASE_API}"
  )"

  tag_name="$(
    printf '%s\n' "${release_json}" |
      grep -m1 '"tag_name"' |
      sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  )"
  [[ -n "${tag_name}" ]] ||
    die "GitHub latest-release response does not contain tag_name."

  version="${tag_name#v}"
  validate_version "${version}"
  log "官方最新正式版：${tag_name}" >&2
  printf '%s\n' "${version}"
}

fetch_and_verify_official_release() {
  local target_version="$1"
  local release_file="${BACKUP_DIR}/target-release.json"
  local api_url="${OFFICIAL_RELEASE_TAG_API_BASE}/v${target_version}"
  local tag_name

  log "正在确认 v${target_version} 是 Wei-Shaw/sub2api 官方正式 Release..."
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 \
    --connect-timeout 5 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${api_url}" > "${release_file}"

  tag_name="$(
    grep -m1 '"tag_name"' "${release_file}" |
      sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
  )"
  [[ "${tag_name}" == "v${target_version}" ]] ||
    die "Official release tag mismatch: expected v${target_version}, got ${tag_name:-missing}."
  grep -Eq '"draft"[[:space:]]*:[[:space:]]*false' "${release_file}" ||
    die "v${target_version} is a draft release; refusing production upgrade."
  grep -Eq '"prerelease"[[:space:]]*:[[:space:]]*false' "${release_file}" ||
    die "v${target_version} is a prerelease; refusing production upgrade."
  log "官方 Release 校验通过：${tag_name}（非草稿、非预发布）。"
}

fetch_target_migration_manifest() {
  local target_version="$1"
  local response
  local api_url="${OFFICIAL_MIGRATIONS_API_BASE}?ref=v${target_version}"
  local migration_count

  [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]] ||
    die "Backup directory is not initialized."
  TARGET_MIGRATIONS_FILE="${BACKUP_DIR}/target-migrations.txt"

  log "正在读取官方 v${target_version} 数据库迁移清单..."
  response="$(
    curl --fail --silent --show-error --location \
      --retry 3 --retry-delay 2 \
      --connect-timeout 5 --max-time 30 \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "${api_url}"
  )"
  printf '%s\n' "${response}" |
    grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+\.sql"' |
    sed -E 's/^"name"[[:space:]]*:[[:space:]]*"([^"]+)"$/\1/' |
    LC_ALL=C sort -u > "${TARGET_MIGRATIONS_FILE}"

  migration_count="$(
    awk 'NF {count++} END {print count + 0}' "${TARGET_MIGRATIONS_FILE}"
  )"
  (( migration_count > 0 )) ||
    die "Official v${target_version} migration manifest is empty."
  log "官方目标迁移清单已固定并保存：${migration_count} 个 SQL 文件。"
}

verify_upstream_deployment_contract() {
  local current_version="$1"
  local target_version="$2"
  local current_compose="${BACKUP_DIR}/official-compose.current.yml"
  local target_compose="${BACKUP_DIR}/official-compose.target.yml"
  local current_env="${BACKUP_DIR}/official-env.current.example"
  local target_env="${BACKUP_DIR}/official-env.target.example"
  local changed=0

  log "正在比较官方 v${current_version} 与 v${target_version} 的 Compose/.env 部署契约..."
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 30 \
    "${OFFICIAL_RAW_BASE}/v${current_version}/deploy/docker-compose.local.yml" \
    > "${current_compose}"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 30 \
    "${OFFICIAL_RAW_BASE}/v${target_version}/deploy/docker-compose.local.yml" \
    > "${target_compose}"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 30 \
    "${OFFICIAL_RAW_BASE}/v${current_version}/deploy/.env.example" \
    > "${current_env}"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 30 \
    "${OFFICIAL_RAW_BASE}/v${target_version}/deploy/.env.example" \
    > "${target_env}"

  if ! cmp -s "${current_compose}" "${target_compose}"; then
    diff -u "${current_compose}" "${target_compose}" \
      > "${BACKUP_DIR}/official-compose.diff" || true
    warn "官方 docker-compose.local.yml 在两个版本之间发生变化。"
    changed=1
  fi
  if ! cmp -s "${current_env}" "${target_env}"; then
    diff -u "${current_env}" "${target_env}" \
      > "${BACKUP_DIR}/official-env.diff" || true
    warn "官方 .env.example 在两个版本之间发生变化。"
    changed=1
  fi
  (( changed == 0 )) ||
    die "Upstream deployment contract changed; automatic image-only upgrade is unsafe and requires manual review."

  log "官方部署契约未变化；允许只替换 Sub2API 应用镜像。"
}

free_space_gb() {
  df -Pk "${STACK_DIR}" |
    awk 'NR == 2 { printf "%d\n", $4 / 1024 / 1024 }'
}

local_health_code() {
  local code
  code="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 3 --max-time 10 \
      "${LOCAL_HEALTH_URL}" 2>/dev/null || true
  )"
  if [[ -z "${code}" || "${code}" == "000" ]]; then
    printf '连接失败\n'
  else
    printf '%s\n' "${code}"
  fi
}

health_body_is_ok() {
  local url="$1"
  local body

  body="$(
    curl --fail --silent --show-error --location \
      --connect-timeout 3 --max-time 10 \
      "${url}" 2>/dev/null || true
  )"
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' <<<"${body}"
}

check_local_health() {
  [[ "$(local_health_code)" == "200" ]] &&
    health_body_is_ok "${LOCAL_HEALTH_URL}"
}

public_health_code() {
  local code
  [[ -n "${PUBLIC_HEALTH_URL}" ]] || {
    printf '未设置\n'
    return 0
  }
  code="$(
    curl --silent --location --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 5 --max-time 15 \
      "${PUBLIC_HEALTH_URL}" 2>/dev/null || true
  )"
  if [[ -z "${code}" || "${code}" == "000" ]]; then
    printf '连接失败\n'
  else
    printf '%s\n' "${code}"
  fi
}

check_public_health() {
  [[ -n "${PUBLIC_HEALTH_URL}" ]] || return 2
  [[ "$(public_health_code)" == "200" ]] &&
    health_body_is_ok "${PUBLIC_HEALTH_URL}"
}

print_status() {
  local current_image
  local local_code
  local public_code
  current_image="$(get_current_image)"

  log "Compose 当前镜像：${current_image}"
  log "应用容器状态：$(container_health "${APP_CONTAINER}")"
  log "PostgreSQL 状态：$(container_health "${PG_CONTAINER}")"
  log "Redis 状态：$(container_health "${REDIS_CONTAINER}")"
  log "${STACK_DIR} 可用空间：$(free_space_gb) GiB"
  compose ps

  local_code="$(local_health_code)"
  if [[ "${local_code}" == "200" ]] &&
    health_body_is_ok "${LOCAL_HEALTH_URL}"; then
    log "本地健康检查：HTTP ${local_code} 且 status=ok (${LOCAL_HEALTH_URL})"
  else
    warn "本地健康检查失败：HTTP=${local_code} 或响应不是 status=ok (${LOCAL_HEALTH_URL})"
  fi

  if [[ -z "${PUBLIC_HEALTH_URL}" ]]; then
    log "公网健康检查：已跳过（未设置 PUBLIC_HEALTH_URL）"
  else
    public_code="$(public_health_code)"
    if [[ "${public_code}" == "200" ]] &&
      health_body_is_ok "${PUBLIC_HEALTH_URL}"; then
      log "公网健康检查：HTTP ${public_code} 且 status=ok (${PUBLIC_HEALTH_URL})"
    else
      warn "公网健康检查失败：HTTP=${public_code} 或响应不是 status=ok (${PUBLIC_HEALTH_URL})"
    fi
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
  validate_runtime_layout
  verify_image_identity "$(get_current_image)" "$(get_current_version)"

  [[ "$(container_health "${APP_CONTAINER}")" == "healthy" ]] ||
    die "Application container is not healthy."
  [[ "$(container_health "${PG_CONTAINER}")" == "healthy" ]] ||
    die "PostgreSQL container is not healthy."
  [[ "$(container_health "${REDIS_CONTAINER}")" == "healthy" ]] ||
    die "Redis container is not healthy."
  check_local_health || die "Local health endpoint is not healthy."
  if [[ -n "${PUBLIC_HEALTH_URL}" ]]; then
    check_public_health || die "Public health endpoint is not healthy."
  fi

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
  MIGRATION_BASELINE_FILE="${BACKUP_DIR}/schema-migrations.before.tsv"
  MIGRATION_BASELINE_NAMES_FILE="${BACKUP_DIR}/schema-migrations.before.txt"
  TARGET_MIGRATIONS_FILE="${BACKUP_DIR}/target-migrations.txt"

  install -d -m 700 "${BACKUP_ROOT}"
  install -d -m 700 "${BACKUP_DIR}"
  exec > >(tee -a "${BACKUP_DIR}/upgrade.log") 2>&1

  log "本次备份目录：${BACKUP_DIR}"
}

backup_configuration() {
  local archive_size
  local archive_tmp="${BACKUP_DIR}/app-data.tar.gz.partial"
  local archive_final="${BACKUP_DIR}/app-data.tar.gz"

  log "正在复制 Compose、.env 和应用配置..."

  cp -a "${COMPOSE_FILE}" "${ORIGINAL_COMPOSE_BACKUP}"
  cp -a "${STACK_DIR}/.env" "${BACKUP_DIR}/.env"
  cp -a /etc/fstab "${BACKUP_DIR}/fstab"
  if [[ -f /etc/systemd/system/docker.service.d/10-requires-srv.conf ]]; then
    cp -a \
      /etc/systemd/system/docker.service.d/10-requires-srv.conf \
      "${BACKUP_DIR}/docker-10-requires-srv.conf"
  fi
  if [[ -f /etc/caddy/Caddyfile ]]; then
    cp -a /etc/caddy/Caddyfile "${BACKUP_DIR}/Caddyfile"
  fi

  if [[ -f "${STACK_DIR}/data/config.yaml" ]]; then
    cp -a "${STACK_DIR}/data/config.yaml" "${BACKUP_DIR}/config.yaml"
  fi
  if [[ -f "${STACK_DIR}/data/.installed" ]]; then
    cp -a "${STACK_DIR}/data/.installed" "${BACKUP_DIR}/.installed"
  fi

  log "正在归档应用数据；运行中的 data/logs/* 已排除（日志不是恢复数据）。"
  tar --numeric-owner \
    --exclude='data/logs/*' \
    -czf "${archive_tmp}" \
    -C "${STACK_DIR}" data
  [[ -s "${archive_tmp}" ]] || die "Application data archive is empty."
  tar -tzf "${archive_tmp}" >/dev/null
  mv "${archive_tmp}" "${archive_final}"
  archive_size="$(stat -c '%s' "${archive_final}")"
  log "应用数据归档完成并通过结构校验：$(human_bytes "${archive_size}")"

  {
    printf 'created_at=%s\n' "$(timestamp)"
    printf 'hostname=%s\n' "$(hostname)"
    printf 'data_mount=%s\n' "${DATA_MOUNT}"
    printf 'data_mount_uuid=%s\n' "$(findmnt -n -T "${DATA_MOUNT}" -o UUID)"
    printf 'data_mount_source=%s\n' "$(findmnt -n -T "${DATA_MOUNT}" -o SOURCE)"
    printf 'data_mount_fstype=%s\n' "$(findmnt -n -T "${DATA_MOUNT}" -o FSTYPE)"
    printf 'stack_dir=%s\n' "${STACK_DIR}"
    printf 'source_image=%s\n' "$(get_current_image)"
    printf 'docker_version=%s\n' "$(docker version --format '{{.Server.Version}}')"
    printf 'compose_version=%s\n' "$(docker compose version --short)"
    printf 'app_container_health=%s\n' "$(container_health "${APP_CONTAINER}")"
    printf 'postgres_container_health=%s\n' "$(container_health "${PG_CONTAINER}")"
    printf 'redis_container_health=%s\n' "$(container_health "${REDIS_CONTAINER}")"
    printf 'stack_free_gb=%s\n' "$(free_space_gb)"
    printf 'app_data_excluded=%s\n' 'data/logs/*'
  } > "${BACKUP_DIR}/metadata.txt"
  compose config --images > "${BACKUP_DIR}/compose-images.before.txt"
  log "配置与应用数据备份完成。"
}

backup_postgresql() {
  local dump_tmp="${BACKUP_DIR}/sub2api.pgdump.partial"
  local dump_final="${BACKUP_DIR}/sub2api.pgdump"
  local db_size
  local dump_pid
  local dump_rc
  local written_bytes=0
  local started_at="${SECONDS}"
  local last_report="${SECONDS}"

  db_size="$(
    docker exec "${PG_CONTAINER}" sh -lc \
      'psql -X -qAt -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT pg_size_pretty(pg_database_size(current_database()));"'
  )"
  log "数据库当前大小：${db_size}"
  log "正在创建 PostgreSQL 自定义格式备份；下面显示的是实际已写入大小，不是估算百分比。"
  docker exec "${PG_CONTAINER}" sh -lc '
    if command -v nice >/dev/null 2>&1; then
      exec nice -n 10 pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"
    fi
    exec pg_dump -Fc -U "$POSTGRES_USER" -d "$POSTGRES_DB"
  ' > "${dump_tmp}" &
  dump_pid=$!

  while kill -0 "${dump_pid}" >/dev/null 2>&1; do
    sleep 2
    if (( SECONDS - last_report >= 5 )); then
      if [[ -f "${dump_tmp}" ]]; then
        written_bytes="$(stat -c '%s' "${dump_tmp}")"
      fi
      log "PostgreSQL 备份进行中：已写入 $(human_bytes "${written_bytes}")，已耗时 $(format_duration "$((SECONDS - started_at))")"
      last_report="${SECONDS}"
    fi
  done

  if wait "${dump_pid}"; then
    dump_rc=0
  else
    dump_rc=$?
  fi
  (( dump_rc == 0 )) ||
    die "pg_dump 失败，退出码 ${dump_rc}；未进入容器切换阶段。"

  [[ -s "${dump_tmp}" ]] || die "PostgreSQL dump is empty."
  mv "${dump_tmp}" "${dump_final}"

  log "正在用 pg_restore 校验备份目录结构..."
  docker exec -i "${PG_CONTAINER}" sh -lc \
    'exec pg_restore -l >/dev/null' < "${dump_final}"

  docker exec "${PG_CONTAINER}" sh -lc \
    'exec pg_dumpall --globals-only -U "$POSTGRES_USER"' \
    > "${BACKUP_DIR}/postgres-globals.sql"
  [[ -s "${BACKUP_DIR}/postgres-globals.sql" ]] ||
    die "PostgreSQL globals backup is empty."

  query_schema_migrations > "${MIGRATION_BASELINE_FILE}"
  [[ -s "${MIGRATION_BASELINE_FILE}" ]] ||
    die "Database migration baseline is empty."
  awk -F '|' 'NF {print $1}' "${MIGRATION_BASELINE_FILE}" |
    LC_ALL=C sort -u > "${MIGRATION_BASELINE_NAMES_FILE}"

  written_bytes="$(stat -c '%s' "${dump_final}")"
  log "PostgreSQL 备份校验通过：$(human_bytes "${written_bytes}")，总耗时 $(format_duration "$((SECONDS - started_at))")"
  log "迁移基线已保存：$(awk 'NF {count++} END {print count + 0}' "${MIGRATION_BASELINE_NAMES_FILE}") 条。"
}

verify_baseline_against_target_manifest() {
  local missing_from_target="${BACKUP_DIR}/baseline-missing-from-target.txt"
  local baseline_count
  local target_count

  [[ -s "${MIGRATION_BASELINE_NAMES_FILE}" ]] ||
    die "Migration baseline names file is missing."
  [[ -s "${TARGET_MIGRATIONS_FILE}" ]] ||
    die "Official target migration manifest is missing."

  LC_ALL=C comm -23 \
    "${MIGRATION_BASELINE_NAMES_FILE}" \
    "${TARGET_MIGRATIONS_FILE}" > "${missing_from_target}"
  if [[ -s "${missing_from_target}" ]]; then
    warn "目标版本缺少当前数据库已经应用的迁移："
    sed 's/^/  [目标缺失] /' "${missing_from_target}" >&2
    die "Target release migration set is not a forward-compatible superset; refusing upgrade."
  fi
  rm -f -- "${missing_from_target}"

  baseline_count="$(
    awk 'NF {count++} END {print count + 0}' "${MIGRATION_BASELINE_NAMES_FILE}"
  )"
  target_count="$(
    awk 'NF {count++} END {print count + 0}' "${TARGET_MIGRATIONS_FILE}"
  )"
  (( target_count >= baseline_count )) ||
    die "Target migration count ${target_count} is below baseline ${baseline_count}."
  log "升级方向核对通过：数据库基线 ${baseline_count} 条，v${1} 官方目标 ${target_count} 条。"
}

redis_cli() {
  if [[ -z "${REDIS_CLI_MODE}" ]]; then
    if docker exec "${REDIS_CONTAINER}" \
      env -u REDISCLI_AUTH redis-cli PING >/dev/null 2>&1; then
      REDIS_CLI_MODE="no-auth"
    else
      REDIS_CLI_MODE="container-auth"
    fi
  fi

  if [[ "${REDIS_CLI_MODE}" == "no-auth" ]]; then
    docker exec "${REDIS_CONTAINER}" \
      env -u REDISCLI_AUTH redis-cli "$@"
    return
  fi

  # Password-protected Redis containers commonly expose REDISCLI_AUTH. Let
  # redis-cli consume that environment variable without printing the password.
  docker exec "${REDIS_CONTAINER}" redis-cli "$@"
}

backup_redis() {
  local info
  local completed=0
  local attempt
  local bgsave_response
  local current_save_time
  local container_rdb_sha
  local backup_rdb_sha

  redis_cli PING >/dev/null
  if [[ "${REDIS_CLI_MODE}" == "no-auth" ]]; then
    log "Redis 连接状态：PONG（服务端未启用密码，已忽略容器内错误认证变量）"
  else
    log "Redis 连接状态：PONG（使用容器认证环境）"
  fi

  log "正在请求非阻塞 Redis BGSAVE..."
  bgsave_response="$(redis_cli BGSAVE | tr -d '\r')"
  log "Redis 返回：${bgsave_response}"

  for attempt in $(seq 1 60); do
    info="$(redis_cli INFO persistence | tr -d '\r')"
    if grep -q '^rdb_bgsave_in_progress:0$' <<<"${info}"; then
      if grep -q '^rdb_last_bgsave_status:ok$' <<<"${info}"; then
        completed=1
        break
      fi
      die "Redis reports that the last BGSAVE failed."
    fi
    if (( attempt == 1 || attempt % 5 == 0 )); then
      current_save_time="$(
        awk -F: '/^rdb_current_bgsave_time_sec:/ {print $2}' <<<"${info}"
      )"
      log "Redis BGSAVE 进行中：服务端计时 ${current_save_time:-未知} 秒"
    fi
    sleep 1
  done

  (( completed == 1 )) || die "Redis BGSAVE did not finish within 60 seconds."

  docker exec "${REDIS_CONTAINER}" sh -lc \
    'command -v redis-check-rdb >/dev/null && redis-check-rdb /data/dump.rdb >/dev/null'
  container_rdb_sha="$(
    docker exec "${REDIS_CONTAINER}" sh -lc \
      'sha256sum /data/dump.rdb | awk "{print \$1}"'
  )"
  docker cp \
    "${REDIS_CONTAINER}:/data/dump.rdb" \
    "${BACKUP_DIR}/redis-dump.rdb" >/dev/null
  [[ -s "${BACKUP_DIR}/redis-dump.rdb" ]] ||
    die "Redis RDB backup is empty."
  backup_rdb_sha="$(
    sha256sum "${BACKUP_DIR}/redis-dump.rdb" |
      awk '{print $1}'
  )"
  [[ "${backup_rdb_sha}" == "${container_rdb_sha}" ]] ||
    die "Redis RDB checksum changed while copying the snapshot."

  log "Redis RDB 备份通过结构与 SHA-256 校验：$(human_bytes "$(stat -c '%s' "${BACKUP_DIR}/redis-dump.rdb")")"
}

write_and_verify_checksums() {
  local total_bytes

  log "正在生成并逐项验证 SHA-256 校验值..."
  (
    cd "${BACKUP_DIR}"
    sha256sum \
      docker-compose.yml.before-upgrade \
      .env \
      app-data.tar.gz \
      compose-images.before.txt \
      fstab \
      metadata.txt \
      target-release.json \
      target-image.txt \
      target-migrations.txt \
      official-compose.current.yml \
      official-compose.target.yml \
      official-env.current.example \
      official-env.target.example \
      schema-migrations.before.tsv \
      schema-migrations.before.txt \
      sub2api.pgdump \
      postgres-globals.sql \
      redis-dump.rdb \
      > SHA256SUMS
    if [[ -f docker-10-requires-srv.conf ]]; then
      sha256sum docker-10-requires-srv.conf >> SHA256SUMS
    fi
    if [[ -f Caddyfile ]]; then
      sha256sum Caddyfile >> SHA256SUMS
    fi
    if [[ -f config.yaml ]]; then
      sha256sum config.yaml >> SHA256SUMS
    fi
    if [[ -f .installed ]]; then
      sha256sum .installed >> SHA256SUMS
    fi
    sha256sum -c SHA256SUMS
  )

  printf 'BACKUP_VERIFIED %s\n' "$(timestamp)" > "${BACKUP_DIR}/STATUS"
  total_bytes="$(du -sb "${BACKUP_DIR}" | awk '{print $1}')"
  log "全部备份校验通过：目录总大小 $(human_bytes "${total_bytes}")"
  log "可恢复备份目录：${BACKUP_DIR}"
}

pull_target_image() {
  local target_image="$1"
  local target_version="$2"
  local current_version="$3"
  local image_platform
  local image_size
  local image_digest

  log "正在拉取目标镜像（此步骤不会触碰当前运行容器）：${target_image}"
  fetch_and_verify_official_release "${target_version}"
  verify_upstream_deployment_contract "${current_version}" "${target_version}"
  docker pull "${target_image}"
  verify_image_identity "${target_image}" "${target_version}"
  fetch_target_migration_manifest "${target_version}"

  image_platform="$(
    docker image inspect \
      -f '{{.Os}}/{{.Architecture}}' \
      "${target_image}"
  )"
  [[ "${image_platform}" == "linux/amd64" ]] ||
    die "Unexpected target image platform: ${image_platform}"
  image_size="$(docker image inspect -f '{{.Size}}' "${target_image}")"
  image_digest="$(
    docker image inspect -f '{{join .RepoDigests ", "}}' "${target_image}"
  )"

  docker image inspect \
    -f 'target_image_id={{.Id}} target_repo_digests={{json .RepoDigests}} source={{index .Config.Labels "org.opencontainers.image.source"}} version={{index .Config.Labels "org.opencontainers.image.version"}} revision={{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "${target_image}" > "${BACKUP_DIR}/target-image.txt"
  log "目标镜像校验完成：官方来源、版本标签、平台 ${image_platform}，大小 $(human_bytes "${image_size}")"
  log "目标镜像摘要：${image_digest:-未提供}"
}

confirm_cutover() {
  local current_version="$1"
  local target_version="$2"
  local expected="UPGRADE ${target_version}"
  local answer
  local remaining
  local wait_step

  if (( AUTO_CUTOVER == 1 )); then
    [[ "${AUTO_CUTOVER_WAIT_SECONDS}" =~ ^[0-9]+$ ]] ||
      die "AUTO_CUTOVER_WAIT_SECONDS must be a non-negative integer."
    log "已启用全自动模式，不需要键盘确认。"
    remaining="${AUTO_CUTOVER_WAIT_SECONDS}"
    while (( remaining > 0 )); do
      log "切换前安全等待：剩余 ${remaining} 秒；当前业务仍由旧容器正常提供。"
      wait_step=5
      if (( remaining < wait_step )); then
        wait_step="${remaining}"
      fi
      sleep "${wait_step}"
      remaining=$((remaining - wait_step))
    done
    [[ "$(container_health "${APP_CONTAINER}")" == "healthy" ]] ||
      die "Application became unhealthy during the automatic cutover wait."
    check_local_health ||
      die "Local health endpoint failed during the automatic cutover wait."
    if [[ -n "${PUBLIC_HEALTH_URL}" ]]; then
      check_public_health ||
        die "Public health endpoint failed during the automatic cutover wait."
    fi
    log "切换前二次检查通过：旧应用 healthy，已配置的健康接口均为 HTTP 200/status=ok。"
    return 0
  fi

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

  log "正在修改 Compose 中唯一的应用镜像标签：${current_version} -> ${target_version}"
  sed -i -E \
    "s|^([[:space:]]*image:[[:space:]]*)${IMAGE_REPOSITORY}:${current_version_re}([[:space:]]*(#.*)?)\$|\\1${target_image}\\2|" \
    "${COMPOSE_FILE}"
  COMPOSE_EDITED=1

  [[ "$(get_current_image)" == "${target_image}" ]] ||
    die "Image tag replacement did not produce the expected result."
  compose config -q
  log "Compose 语法验证通过，待运行镜像：${target_image}"
}

wait_for_application_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_SECONDS))
  local state
  local http_code
  local started_at="${SECONDS}"
  local last_report=-10

  while (( SECONDS < deadline )); do
    state="$(container_health "${APP_CONTAINER}")"
    http_code="$(
      curl --silent --output /dev/null --write-out '%{http_code}' \
        --connect-timeout 2 --max-time 3 \
        "${LOCAL_HEALTH_URL}" 2>/dev/null || true
    )"
    if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
      http_code="连接失败"
    fi
    if [[ "${state}" == "unhealthy" || "${state}" == "exited" || "${state}" == "dead" ]]; then
      warn "应用容器进入失败状态：container=${state}，health HTTP=${http_code}"
      return 1
    fi

    if [[ "${state}" == "healthy" &&
      "${http_code}" == "200" ]] &&
      health_body_is_ok "${LOCAL_HEALTH_URL}"; then
      log "新应用已就绪：container=healthy，health HTTP=200 且 status=ok，等待耗时 $(format_duration "$((SECONDS - started_at))")"
      return 0
    fi
    if (( SECONDS - last_report >= 4 )); then
      log "等待新应用启动：container=${state}，health HTTP=${http_code}，已等待 $(format_duration "$((SECONDS - started_at))")"
      last_report="${SECONDS}"
    fi
    sleep 2
  done

  warn "等待 ${HEALTH_TIMEOUT_SECONDS} 秒后应用仍未健康。"
  return 1
}

query_schema_migrations() {
  docker exec "${PG_CONTAINER}" sh -lc \
    'exec psql -X -qAt -F "|" -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT filename, checksum FROM schema_migrations;"' |
    LC_ALL=C sort -t '|' -k1,1
}

migration_baseline_unchanged() {
  [[ -s "${MIGRATION_BASELINE_FILE}" ]] || return 1
  cmp -s "${MIGRATION_BASELINE_FILE}" <(query_schema_migrations)
}

verify_target_migrations() {
  local after_file="${BACKUP_DIR}/schema-migrations.after.tsv"
  local after_names="${BACKUP_DIR}/schema-migrations.after.txt"
  local missing_file="${BACKUP_DIR}/schema-migrations.missing.txt"
  local extra_file="${BACKUP_DIR}/schema-migrations.extra.txt"
  local changed_baseline_file="${BACKUP_DIR}/schema-migrations.baseline-changed.txt"
  local new_file="${BACKUP_DIR}/schema-migrations.new.txt"
  local expected_count
  local actual_count
  local new_count

  query_schema_migrations > "${after_file}"
  [[ -s "${after_file}" ]] || die "Post-upgrade migration table is empty."
  awk -F '|' 'NF {print $1}' "${after_file}" |
    LC_ALL=C sort -u > "${after_names}"

  LC_ALL=C comm -23 \
    "${TARGET_MIGRATIONS_FILE}" \
    "${after_names}" > "${missing_file}"
  LC_ALL=C comm -13 \
    "${TARGET_MIGRATIONS_FILE}" \
    "${after_names}" > "${extra_file}"
  LC_ALL=C comm -23 \
    "${MIGRATION_BASELINE_FILE}" \
    "${after_file}" > "${changed_baseline_file}"

  if [[ -s "${missing_file}" || -s "${extra_file}" ||
    -s "${changed_baseline_file}" ]]; then
    [[ ! -s "${missing_file}" ]] || {
      warn "数据库缺少目标版本迁移："
      sed 's/^/  [缺失] /' "${missing_file}" >&2
    }
    [[ ! -s "${extra_file}" ]] || {
      warn "数据库存在目标版本清单之外的迁移："
      sed 's/^/  [额外] /' "${extra_file}" >&2
    }
    [[ ! -s "${changed_baseline_file}" ]] || {
      warn "升级前迁移记录或校验和发生变化："
      sed 's/^/  [变化] /' "${changed_baseline_file}" >&2
    }
    die "Post-upgrade database migration manifest verification failed."
  fi

  rm -f -- "${missing_file}" "${extra_file}" "${changed_baseline_file}"
  LC_ALL=C comm -13 \
    "${MIGRATION_BASELINE_NAMES_FILE}" \
    "${after_names}" > "${new_file}"

  expected_count="$(
    awk 'NF {count++} END {print count + 0}' "${TARGET_MIGRATIONS_FILE}"
  )"
  actual_count="$(
    awk 'NF {count++} END {print count + 0}' "${after_names}"
  )"
  new_count="$(
    awk 'NF {count++} END {print count + 0}' "${new_file}"
  )"

  log "数据库迁移清单核对通过：官方目标 ${expected_count} 条，数据库 ${actual_count} 条，本次新增 ${new_count} 条。"
  if (( new_count > 0 )); then
    sed 's/^/  [本次新增] /' "${new_file}"
  else
    log "本次版本没有新增数据库迁移。"
  fi
  (
    cd "${BACKUP_DIR}"
    sha256sum \
      schema-migrations.after.tsv \
      schema-migrations.after.txt \
      schema-migrations.new.txt \
      > POST-UPGRADE-SHA256SUMS
    sha256sum -c POST-UPGRADE-SHA256SUMS >/dev/null
  )
}

save_container_logs() {
  local destination="$1"
  docker logs --since 10m "${APP_CONTAINER}" > "${destination}" 2>&1 || true
}

cleanup_partial_backup() {
  local partial_file
  local partial_files=()

  [[ -n "${BACKUP_DIR}" && -d "${BACKUP_DIR}" ]] || return 0
  partial_files=(
    "${BACKUP_DIR}/app-data.tar.gz.partial"
    "${BACKUP_DIR}/sub2api.pgdump.partial"
  )

  for partial_file in "${partial_files[@]}"; do
    [[ -e "${partial_file}" ]] || continue

    if [[ -f "${partial_file}" && ! -L "${partial_file}" ]]; then
      if rm -f -- "${partial_file}"; then
        log "已清理无效的临时备份：${partial_file}"
      else
        warn "无法清理临时备份：${partial_file}"
      fi
    else
      warn "发现非普通临时文件，出于安全考虑未删除：${partial_file}"
    fi
  done
}

delete_script_after_success() {
  local expected_path="/root/sub2api-safe-upgrade.sh"
  local script_path

  if [[ "${DELETE_SCRIPT_ON_SUCCESS}" != "1" ]]; then
    log "升级脚本已保留：${BASH_SOURCE[0]}（便于 status/rollback；文件本身占用很小）"
    return 0
  fi

  if (( PUBLIC_HEALTH_FAILED == 1 )); then
    warn "公网健康检查存在告警，升级脚本将保留，不执行自动删除。"
    return 0
  fi

  script_path="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  if [[ "${script_path}" != "${expected_path}" ||
    ! -f "${script_path}" ||
    -L "${script_path}" ]]; then
    warn "自动删除仅允许普通文件 ${expected_path}；当前路径为 ${script_path:-未知}，已跳过。"
    return 0
  fi

  if rm -f -- "${script_path}"; then
    log "升级已完整成功，安装脚本已按要求自动删除：${script_path}"
  else
    warn "升级已成功，但安装脚本自动删除失败：${script_path}"
  fi
}

restore_old_application() {
  local reason="$1"

  (( FAILURE_HANDLER_RUNNING == 0 )) || return 0
  FAILURE_HANDLER_RUNNING=1
  trap - ERR INT TERM
  set +e

  warn "开始自动回退应用镜像，原因：${reason}"

  if [[ -n "${BACKUP_DIR}" ]]; then
    save_container_logs "${BACKUP_DIR}/failed-target-container.log"
  fi

  if (( CUTOVER_STARTED == 1 )) && ! migration_baseline_unchanged; then
    warn "数据库迁移集合已变化或无法核对；根据 Sub2API 的前向迁移规则，拒绝自动启动旧应用镜像。"
    warn "目标 Compose 保持不变，PostgreSQL/Redis 未停止；请查看失败日志后决定修复目标版本还是显式恢复数据库。"
    if [[ -n "${BACKUP_DIR}" ]]; then
      printf 'AUTO_ROLLBACK_SKIPPED_SCHEMA_CHANGED %s\n' "$(timestamp)" \
        >> "${BACKUP_DIR}/STATUS"
    fi
    return 1
  fi

  if [[ -n "${ORIGINAL_COMPOSE_BACKUP}" && -f "${ORIGINAL_COMPOSE_BACKUP}" ]]; then
    cp -a "${ORIGINAL_COMPOSE_BACKUP}" "${COMPOSE_FILE}"
    COMPOSE_EDITED=0

    if compose config -q; then
      warn "原 Compose 已恢复，正在重新创建旧应用容器..."
      compose up -d --no-deps --force-recreate --pull never "${APP_SERVICE}"
      if wait_for_application_health; then
        warn "自动回退成功：旧应用镜像已恢复并通过健康检查。"
        if [[ -n "${BACKUP_DIR}" ]]; then
          printf 'AUTO_ROLLBACK_COMPLETED %s\n' "$(timestamp)" \
            >> "${BACKUP_DIR}/STATUS"
        fi
      else
        warn "自动回退已执行，但旧应用仍未通过健康检查。"
      fi
    else
      warn "自动回退失败：原 Compose 文件未通过语法验证。"
    fi
  else
    warn "自动回退无法执行：找不到原 Compose 备份。"
  fi
}

handle_error() {
  local rc="$1"
  local line="$2"
  local current_image="未知"
  local app_state="未知"
  local pg_state="未知"
  local redis_state="未知"

  trap - ERR INT TERM
  set +e
  current_image="$(get_current_image 2>/dev/null || printf '未知')"
  app_state="$(container_health "${APP_CONTAINER}")"
  pg_state="$(container_health "${PG_CONTAINER}")"
  redis_state="$(container_health "${REDIS_CONTAINER}")"

  printf '\n' >&2
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
  warn "升级失败"
  warn "失败阶段：${CURRENT_STAGE}"
  warn "脚本位置：第 ${line} 行；退出码：${rc}"
  warn "当前 Compose 镜像：${current_image}"
  warn "实时容器状态：应用=${app_state}，PostgreSQL=${pg_state}，Redis=${redis_state}"
  if [[ -n "${BACKUP_DIR}" ]]; then
    warn "备份目录：${BACKUP_DIR}"
    warn "完整过程日志：${BACKUP_DIR}/upgrade.log"
  fi

  if (( CUTOVER_STARTED == 0 && COMPOSE_EDITED == 0 )); then
    warn "失败发生在切换前：应用容器未停止，线上业务仍由原容器提供。"
  elif (( CUTOVER_STARTED == 0 && COMPOSE_EDITED == 1 )); then
    warn "Compose 已修改但尚未停容器；将恢复原 Compose。"
  else
    warn "已进入容器切换阶段；现在先核对迁移集合，再决定是否允许自动应用回退。"
  fi

  if (( COMPOSE_EDITED == 1 || CUTOVER_STARTED == 1 )); then
    restore_old_application "upgrade failure"
  fi
  cleanup_partial_backup
  if [[ -n "${BACKUP_DIR}" ]]; then
    printf 'UPGRADE_FAILED %s stage=%q line=%s exit=%s\n' \
      "$(timestamp)" "${CURRENT_STAGE}" "${line}" "${rc}" >> "${BACKUP_DIR}/STATUS"
  fi
  printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n' >&2
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

  UPGRADE_STARTED_AT="${SECONDS}"
  CURRENT_STEP=0
  log "Sub2API 安全升级脚本版本：${SCRIPT_VERSION}"
  require_root
  require_commands
  acquire_lock
  validate_layout
  validate_cleanup_settings

  if [[ "${target_version}" == "latest" ]]; then
    target_version="$(fetch_latest_official_version)"
  fi
  validate_version "${target_version}"

  current_image="$(get_current_image)"
  current_version="$(get_current_version)"
  validate_version "${current_version}"
  target_image="${IMAGE_REPOSITORY}:${target_version}"

  if [[ "${current_version}" == "${target_version}" ]]; then
    for container in "${APP_CONTAINER}" "${PG_CONTAINER}" "${REDIS_CONTAINER}"; do
      container_exists "${container}" || die "Container not found: ${container}"
      container_running "${container}" || die "Container is not running: ${container}"
      [[ "$(container_health "${container}")" == "healthy" ]] ||
        die "Container is not healthy: ${container}"
    done
    validate_runtime_layout
    verify_image_identity "${current_image}" "${current_version}"
    check_local_health || die "Local health endpoint failed."
    if [[ -n "${PUBLIC_HEALTH_URL}" ]]; then
      check_public_health || die "Public health endpoint failed."
    fi
    log "当前 Compose 已经是官方最新版本 ${target_image}，无需升级。"
    print_status
    return 0
  fi
  version_is_newer "${current_version}" "${target_version}" ||
    die "Refusing non-forward upgrade: current=${current_version}, target=${target_version}."

  stage_start "只读预检当前生产环境"
  for container in "${APP_CONTAINER}" "${PG_CONTAINER}" "${REDIS_CONTAINER}"; do
    container_exists "${container}" || die "Container not found: ${container}"
    container_running "${container}" || die "Container is not running: ${container}"
  done
  validate_runtime_layout
  verify_image_identity "${current_image}" "${current_version}"
  [[ "$(container_health "${APP_CONTAINER}")" == "healthy" ]] ||
    die "Application container is not healthy before upgrade."
  [[ "$(container_health "${PG_CONTAINER}")" == "healthy" ]] ||
    die "PostgreSQL container is not healthy before upgrade."
  [[ "$(container_health "${REDIS_CONTAINER}")" == "healthy" ]] ||
    die "Redis container is not healthy before upgrade."
  check_local_health || die "Local health endpoint failed before upgrade."
  if [[ -n "${PUBLIC_HEALTH_URL}" ]]; then
    check_public_health || die "Public health endpoint failed before upgrade."
  fi

  if (( $(free_space_gb) < MIN_FREE_GB )); then
    die "Insufficient free space for image pull and fresh backups."
  fi
  log "预检结果：当前 ${current_image}，目标 ${target_image}"
  print_status
  stage_finish

  create_backup_directory "${current_version}" "${target_version}"
  trap 'handle_error $? $LINENO' ERR
  trap 'handle_signal INT' INT
  trap 'handle_signal TERM' TERM

  log "升级任务：${current_image} -> ${target_image}"

  stage_start "备份 Compose、配置和应用数据"
  backup_configuration
  stage_finish

  stage_start "拉取并校验目标 Docker 镜像"
  pull_target_image "${target_image}" "${target_version}" "${current_version}"
  stage_finish

  stage_start "创建并验证 PostgreSQL 备份"
  backup_postgresql
  verify_baseline_against_target_manifest "${target_version}"
  stage_finish

  stage_start "创建并验证 Redis 备份"
  backup_redis
  stage_finish

  stage_start "生成并核对全部备份校验值"
  write_and_verify_checksums
  stage_finish

  stage_start "切换前等待与二次健康检查"
  confirm_cutover "${current_version}" "${target_version}"
  stage_finish

  stage_start "修改 Compose 并切换应用容器"
  replace_compose_image "${current_version}" "${target_version}"

  CUTOVER_STARTED=1
  CUTOVER_STARTED_AT="${SECONDS}"
  log "开始停止旧应用容器；PostgreSQL、Redis、Caddy 不会停止。"
  log "Docker 停止超时上限：${STOP_TIMEOUT_SECONDS} 秒"
  compose stop -t "${STOP_TIMEOUT_SECONDS}" "${APP_SERVICE}"
  log "旧应用容器已停止，实时状态：$(container_health "${APP_CONTAINER}")"

  log "正在使用 ${target_image} 创建新应用容器..."
  compose up -d --no-deps --force-recreate --pull never "${APP_SERVICE}"
  log "新容器已创建，当前 Docker 状态：$(container_health "${APP_CONTAINER}")"
  stage_finish

  stage_start "等待新版本健康并验证数据库迁移"
  wait_for_application_health
  CUTOVER_DURATION=$((SECONDS - CUTOVER_STARTED_AT))

  [[ "$(docker inspect -f '{{.Config.Image}}' "${APP_CONTAINER}")" == "${target_image}" ]] ||
    die "Running container does not use ${target_image}."
  verify_image_identity "${target_image}" "${target_version}"
  log "运行镜像核对通过：${target_image}"

  verify_target_migrations
  validate_runtime_layout
  save_container_logs "${BACKUP_DIR}/post-upgrade-container.log"
  log "新容器最近日志已保存：${BACKUP_DIR}/post-upgrade-container.log"
  compose ps
  log "容器切换至健康状态耗时：$(format_duration "${CUTOVER_DURATION}")"
  stage_finish

  stage_start "检查公网入口并输出最终结果"
  if [[ -z "${PUBLIC_HEALTH_URL}" ]]; then
    PUBLIC_HEALTH_STATUS="已跳过"
    PUBLIC_HEALTH_FAILED=0
    log "公网健康检查已跳过：未设置 PUBLIC_HEALTH_URL。"
  elif check_public_health; then
    PUBLIC_HEALTH_STATUS="HTTP 200 / status=ok"
    PUBLIC_HEALTH_FAILED=0
    log "公网健康检查通过：HTTP 200 且 status=ok (${PUBLIC_HEALTH_URL})"
  else
    PUBLIC_HEALTH_STATUS="失败"
    PUBLIC_HEALTH_FAILED=1
    warn "本地应用健康，但公网健康检查失败；请检查 Caddy/DNS。"
  fi
  stage_finish

  printf 'UPGRADE_SUCCESS %s target=%s\n' \
    "$(timestamp)" "${target_version}" >> "${BACKUP_DIR}/STATUS"
  COMPOSE_EDITED=0
  CUTOVER_STARTED=0
  trap - ERR INT TERM

  printf '\n'
  printf '################################################################\n'
  if (( PUBLIC_HEALTH_FAILED == 1 )); then
    printf '# 升级完成（公网检查存在告警）\n'
  else
    printf '# 升级成功\n'
  fi
  printf '################################################################\n'
  log "版本：${current_version} -> ${target_version}"
  log "总耗时：$(format_duration "$((SECONDS - UPGRADE_STARTED_AT))")"
  log "容器切换至健康状态：$(format_duration "${CUTOVER_DURATION}")"
  log "最终状态：应用=$(container_health "${APP_CONTAINER}")，PostgreSQL=$(container_health "${PG_CONTAINER}")，Redis=$(container_health "${REDIS_CONTAINER}")"
  log "公网健康检查：${PUBLIC_HEALTH_STATUS}"
  log "备份目录：${BACKUP_DIR}"
  log "请保留旧镜像和此备份，确认稳定前不要运行 docker image prune。"
  cleanup_partial_backup
  delete_script_after_success
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
  local saved_migration_baseline
  local stamp

  require_root
  require_commands
  acquire_lock
  validate_layout
  validate_cleanup_settings

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

  saved_migration_baseline="${source_backup}/schema-migrations.before.tsv"
  if [[ ! -s "${saved_migration_baseline}" ]]; then
    [[ "${ALLOW_SCHEMA_MISMATCH_ROLLBACK}" == "1" ]] ||
      die "Backup has no migration baseline; refusing image rollback. Set ALLOW_SCHEMA_MISMATCH_ROLLBACK=1 only after manual schema compatibility review."
    warn "备份缺少迁移基线；已根据显式 ALLOW_SCHEMA_MISMATCH_ROLLBACK=1 继续。"
  elif ! cmp -s "${saved_migration_baseline}" <(query_schema_migrations); then
    [[ "${ALLOW_SCHEMA_MISMATCH_ROLLBACK}" == "1" ]] ||
      die "Database migration set differs from the rollback backup; refusing an unsafe image-only rollback."
    warn "数据库迁移集合与旧镜像备份不同；已根据显式 ALLOW_SCHEMA_MISMATCH_ROLLBACK=1 继续。"
  else
    log "数据库迁移集合与回退备份一致，允许应用镜像回退。"
  fi

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
  compose up -d --no-deps --force-recreate --pull never "${APP_SERVICE}"

  if ! wait_for_application_health; then
    warn "Old application image is unhealthy; restoring the pre-rollback Compose file."
    save_container_logs "${rollback_record_dir}/failed-rollback-container.log"
    cp -a \
      "${rollback_record_dir}/docker-compose.yml.before-rollback" \
      "${COMPOSE_FILE}"
    compose config -q
    compose up -d --no-deps --force-recreate --pull never "${APP_SERVICE}"
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
      validate_runtime_layout
      verify_image_identity "$(get_current_image)" "$(get_current_version)"
      print_status
      ;;
    upgrade)
      perform_upgrade "${1:-${DEFAULT_TARGET_VERSION}}"
      ;;
    upgrade-latest)
      AUTO_CUTOVER=1
      perform_upgrade latest
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
