# Sub2API Production Ops

这是针对当前生产服务器定制的 Sub2API Docker Compose 安全升级脚本。

它不是通用“一键更新器”，默认值与当前新机严格绑定：

```text
数据盘挂载点      /srv
数据盘文件系统    ext4
项目目录          /srv/sub2api
Compose           /srv/sub2api/docker-compose.yml
应用容器          sub2api
PostgreSQL        sub2api-postgres
Redis             sub2api-redis
本地健康接口      http://127.0.0.1:8080/health
公网健康接口      https://blsup.xyz/health（执行时传入）
```

当前生产版本为 `0.1.164`，截至 2026-07-26 的官方最新正式版为
[`v0.1.165`](https://github.com/Wei-Shaw/sub2api/releases/tag/v0.1.165)。
`upgrade-latest` 会在执行时重新查询官方最新正式版，不把“最新版本”写死。

## 为什么采用这种更新方式

Sub2API 官方推荐需要方便备份和迁移的生产部署使用本地目录版
`docker-compose.local.yml`，即 `./data`、`./postgres_data` 和
`./redis_data`。当前 `/srv/sub2api` 正是这种结构。官方的普通更新命令是
`docker compose pull` 再 `docker compose up -d`，数据库迁移由新应用启动时
自动执行；官方同时明确说明数据库迁移是前向迁移，回退需要数据库备份或
人工补偿 SQL。

本脚本在这个基础上增加生产保护：

- 只更新 `sub2api` 应用服务，不停止 PostgreSQL、Redis 或 Caddy。
- 镜像固定到明确版本，绝不使用 `latest` 标签。
- 使用 Docker Compose 官方建议的 `up -d --no-deps` 方式只重建变化的服务。
- 切换前生成并验证 PostgreSQL、Redis、Compose、`.env` 和应用数据备份。
- 不运行 `docker compose down`、`down -v`、`docker image prune` 或数据库自动恢复。

参考：

- [Sub2API 官方部署说明](https://github.com/Wei-Shaw/sub2api/blob/main/deploy/README.md)
- [Sub2API 官方本地目录 Compose](https://github.com/Wei-Shaw/sub2api/blob/main/deploy/docker-compose.local.yml)
- [Docker Compose 生产更新说明](https://docs.docker.com/compose/how-tos/production/)
- [Docker Compose `up` 文档](https://docs.docker.com/reference/cli/docker/compose/up/)
- [PostgreSQL `pg_dump` 文档](https://www.postgresql.org/docs/current/app-pgdump.html)

## 新机专用保护

脚本在任何备份或切换前都会确认：

- `/srv` 是真正的数据盘挂载点，不是系统盘上的同名空目录。
- UUID 与当前 60 GB 数据盘一致，文件系统为 ext4 且可写。
- Docker 存在 `RequiresMountsFor=/srv` 和
  `AssertPathIsMountPoint=/srv` 防误写保护。
- 项目确实位于 `/srv/sub2api`，`.env` 权限为 `600`。
- 应用、PostgreSQL、Redis 三项持久化绑定目录均指向
  `/srv/sub2api` 下的对应目录。
- 应用只发布 `127.0.0.1:8080`；PostgreSQL 和 Redis 不发布宿主机端口。
- 三个容器运行且健康，镜像与 Compose 一致。
- 当前镜像来自官方仓库、版本标签匹配且平台为 `linux/amd64`。
- `/srv` 至少保留 8 GiB 可用空间。
- 本地健康接口必须同时满足 HTTP 200 和 `{"status":"ok"}`。

任一条件不符，脚本会在切换前停止。

## 官方版本与部署契约核对

对目标版本，脚本会：

1. 通过 Wei-Shaw/sub2api GitHub Release API 确认目标是非草稿、非预发布的
   官方正式版。
2. 拉取版本固定的 `weishaw/sub2api:<version>` 镜像并核对 OCI 来源、
   版本标签和 `linux/amd64` 平台。
3. 下载官方目标版本的完整 SQL 迁移文件名清单。
4. 比较当前版与目标版官方 `docker-compose.local.yml` 和 `.env.example`。

如果官方 Compose 或环境变量模板发生变化，脚本会拒绝自动执行“只换镜像”
升级，并保留差异文件供人工审查。`0.1.164 -> 0.1.165` 的这两个官方文件
完全相同，因此本次允许只更新应用镜像。

## 备份与验证

升级目录位于：

```text
/srv/sub2api/backups/upgrade-<旧版本>-to-<新版本>-<时间>/
```

切换前会保存：

- 当前 Compose、`.env`、应用数据（排除持续写入的 `data/logs/*`）。
- `/etc/fstab`、Docker `/srv` 挂载保护、Caddyfile（存在时）。
- PostgreSQL 自定义格式逻辑备份和 globals。
- Redis BGSAVE 后的 RDB。
- 当前数据库 `schema_migrations` 文件名与 checksum 基线。
- 目标官方 Release JSON、镜像身份、迁移清单和部署契约文件。
- 所有备份文件的 SHA-256。

PostgreSQL 备份通过 `pg_restore -l` 验证；Redis RDB 通过
`redis-check-rdb` 和复制前后 SHA-256 验证。

这些是服务器内的升级回滚备份，不等于异地灾备。正式灾备仍应复制到另一台
服务器、对象存储或本地电脑。

## 数据库迁移与回退边界

切换后，脚本要求数据库中的迁移记录与目标版本官方 SQL 清单完全一致，并确认
升级前已经存在的 checksum 没有变化。

- 如果新应用失败且数据库迁移集合没有变化，脚本可自动恢复旧 Compose 和旧镜像。
- 如果新应用已经执行了新的前向迁移，脚本拒绝危险的“只换回旧镜像”自动回退。
- 脚本永不自动恢复 PostgreSQL，因为备份之后仍可能产生正常业务写入，自动恢复
  可能丢数据。
- 手工 `rollback` 也会检查迁移基线；数据库结构不同默认拒绝执行。

## 使用方式

先下载脚本，并使用固定提交 SHA 与 SHA-256 校验。README 中不写死提交号；
每次发布后应使用该次提交对应的固定 Raw URL 和校验值。

只读预检：

```bash
PUBLIC_HEALTH_URL='https://blsup.xyz/health' \
bash /root/sub2api-safe-upgrade.sh preflight
```

自动查询并升级至官方最新正式版：

```bash
DELETE_SCRIPT_ON_SUCCESS=1 \
PUBLIC_HEALTH_URL='https://blsup.xyz/health' \
bash /root/sub2api-safe-upgrade.sh upgrade-latest
```

固定版本、人工确认后切换：

```bash
PUBLIC_HEALTH_URL='https://blsup.xyz/health' \
bash /root/sub2api-safe-upgrade.sh upgrade 0.1.165
```

查看状态：

```bash
PUBLIC_HEALTH_URL='https://blsup.xyz/health' \
bash /root/sub2api-safe-upgrade.sh status
```

应用镜像回退（仅当迁移基线兼容）：

```bash
bash /root/sub2api-safe-upgrade.sh rollback \
  /srv/sub2api/backups/upgrade-0.1.164-to-0.1.165-YYYYMMDD-HHMMSS
```

## 维护窗口

`upgrade-latest` 会先完成全部备份和校验，再等待 30 秒并二次检查健康状态，
最后才停止和重建应用容器。PostgreSQL、Redis、Caddy 始终运行，但切换期间
现有长连接或流式请求仍可能中断。

建议在低流量时段执行。确认稳定前保留旧镜像和升级备份，不要运行镜像清理。
