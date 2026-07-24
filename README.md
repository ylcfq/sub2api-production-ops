# Sub2API Production Ops

Production-oriented backup, upgrade, health-check, and application rollback
helper for Docker Compose deployments of
[Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api).

The script is intentionally conservative:

- creates and verifies PostgreSQL, Redis, configuration, and application-data backups;
- pulls a version-pinned Sub2API image;
- can discover the latest official non-prerelease GitHub release automatically;
- retains an interactive explicit-version mode for controlled maintenance;
- recreates only the Sub2API application container;
- leaves PostgreSQL, Redis, Caddy, persistent volumes, and old images untouched;
- verifies container health and the expected `v0.1.164` migrations;
- automatically restores the old application image when the new local health check fails;
- never performs an automatic database restore.

## Human-readable live status

Upgrade output is organized as ten explicit operational stages. It reports
real observed values rather than invented percentages, including:

- current and target image versions;
- live container health and HTTP status;
- database size and the PostgreSQL dump's actual bytes written and elapsed time;
- Redis connectivity, BGSAVE state, and resulting RDB size;
- target image platform, size, and digest;
- backup checksums and total backup size;
- automatic cutover countdown;
- application container state while waiting for health;
- each required migration recorded by the database;
- total runtime, cutover-to-healthy duration, final container state, and log paths.

On failure it prints the current stage, script line, exit code, active Compose
image, all three container states, whether cutover had started, the backup
directory, the full log path, and the automatic rollback outcome. Secrets and
environment-variable values are not printed.

## Expected layout

Defaults match this common Docker Compose layout:

```text
/www/sub2api/
├── docker-compose.yml
├── .env
├── data/
├── postgres_data/
├── redis_data/
└── backups/
```

Default container/service names:

```text
sub2api
sub2api-postgres
sub2api-redis
```

All defaults can be overridden with environment variables declared near the
top of the script.

## Inspect before running

Because this is an operational script, review the pinned revision before
using it on a production server:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/ylcfq/sub2api-production-ops/main/sub2api-safe-upgrade.sh \
  -o /root/sub2api-safe-upgrade.sh

less /root/sub2api-safe-upgrade.sh
chmod 700 /root/sub2api-safe-upgrade.sh
```

## Commands

Read-only preflight:

```bash
bash /root/sub2api-safe-upgrade.sh preflight
```

Upgrade to `0.1.164`:

```bash
bash /root/sub2api-safe-upgrade.sh upgrade 0.1.164
```

Automatically discover and install the latest official release without a
keyboard confirmation:

```bash
bash /root/sub2api-safe-upgrade.sh upgrade-latest
```

One-command automatic execution:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/ylcfq/sub2api-production-ops/main/sub2api-safe-upgrade.sh \
  -o /root/sub2api-safe-upgrade.sh \
  && chmod 700 /root/sub2api-safe-upgrade.sh \
  && PUBLIC_HEALTH_URL='https://your-domain.example/health' \
  bash /root/sub2api-safe-upgrade.sh upgrade-latest
```

Automatic mode obtains the release from GitHub's
`Wei-Shaw/sub2api/releases/latest` API, validates the semantic version, creates
and verifies all backups, waits 30 seconds, rechecks local health, and performs
the cutover without prompting.

The explicit-version `upgrade` command still pauses after backup and requires
`UPGRADE <version>`.

Status:

```bash
bash /root/sub2api-safe-upgrade.sh status
```

Application-image rollback:

```bash
bash /root/sub2api-safe-upgrade.sh rollback \
  /www/sub2api/backups/upgrade-0.1.162-to-0.1.164-YYYYMMDD-HHMMSS
```

The rollback command does not restore PostgreSQL. Database restoration can
discard writes made after the backup and must remain an explicit recovery
decision.

## Important

Run upgrades in a maintenance window. Automatic mode cannot prove that no
long-running or streaming request is active, so start it only during a known
low-traffic period.

Do not use `docker compose down -v` or prune the old image until the upgraded
deployment has been fully validated.
