# Sub2API Production Ops

Production-oriented backup, upgrade, health-check, and application rollback
helper for Docker Compose deployments of
[Wei-Shaw/sub2api](https://github.com/Wei-Shaw/sub2api).

The script is intentionally conservative:

- creates and verifies PostgreSQL, Redis, configuration, and application-data backups;
- pulls a version-pinned Sub2API image;
- requires an interactive low-traffic confirmation before cutover;
- recreates only the Sub2API application container;
- leaves PostgreSQL, Redis, Caddy, persistent volumes, and old images untouched;
- verifies container health and the expected `v0.1.164` migrations;
- automatically restores the old application image when the new local health check fails;
- never performs an automatic database restore.

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

One-command execution:

```bash
PUBLIC_HEALTH_URL='https://your-domain.example/health' \
  bash <(curl -fsSL \
  https://raw.githubusercontent.com/ylcfq/sub2api-production-ops/main/sub2api-safe-upgrade.sh) \
  upgrade 0.1.164
```

The script performs backups first, then pauses and requires:

```text
UPGRADE 0.1.164
```

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

Run upgrades in a maintenance window and confirm that no long-running or
streaming request is active before entering the cutover confirmation.

Do not use `docker compose down -v` or prune the old image until the upgraded
deployment has been fully validated.
