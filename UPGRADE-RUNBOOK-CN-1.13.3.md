# Dify 1.x → 1.13.3 升级 Runbook(国内集群)

> 海外集群已升级成功(2026-05),本 runbook 沉淀升级中的关键决策、踩坑点、避坑配置,供国内集群直接复用。
> 详细的逐步操作命令见 `UPGRADE-RUNBOOK-JP-1.13.3.md`,本文聚焦**判断**和**易错点**。

---

## 1. 升级策略与回滚

- **蓝绿**:旧集群不动,新集群跑通后用上游 Nginx 切流
- **回滚**:Nginx 切回旧集群上游 → 旧 K8s 副本立即拉起 → 新集群副本归零
- ⚠️ 蓝绿期间用户在新集群产生的数据(对话/应用/上传),**回滚 = 丢失**。维护窗口需公告

---

## 2. 数据策略

| 资源 | 做法 | 注意 |
|---|---|---|
| **PG (dify)** | 旧停机 → `pg_dump -Fc` → 新 PG `pg_restore` | 独立实例,跟旧库物理隔离 |
| **PG (dify_plugin)** | **单独 dump,不在 dify 库里** | 漏掉这步,新 plugin daemon 起来表是空的 |
| **Redis** | 新集群用全新 Redis | 缓存可丢;但旧停机前确认 Celery 队列 LLEN = 0 |
| **S3** | 共用旧 | 文件 UUID+immutable,新旧元数据各自隔离,无冲突 |
| **Qdrant** | 共用旧 | dataset_id 跟旧 PG 一致,检索能命中;**冒烟测试只用新建 dataset,绝不动生产 dataset** |

```bash
# dify_plugin 库单独迁移(别漏!)
pg_dump -Fc -h 旧PG -U postgres dify_plugin > dify_plugin.dump
createdb -h 新PG -U postgres dify_plugin
pg_restore -h 新PG -U postgres -d dify_plugin dify_plugin.dump
```

---

## 3. Secret 强一致性(最最关键)

| 旧字段(老 chart) | 新字段(1.13 chart) | 必须一致? | 不一致的后果 |
|---|---|---|---|
| `app.secretKey` | `global.appSecretKey` | **🔴 必须** | 旧 DB 加密的 provider api_key / 模型 token 全部解不出来 |
| `app.consoleSecretKey` | (已废除) | N/A | 1.13 chart 无此字段,忽略 |
| `sandbox.apiKey` | `sandbox.auth.apiKey` | 🟡 建议 | api → sandbox 401 |
| `pluginDaemon.serverKey` | `pluginDaemon.auth.serverKey` | 🟡 建议 | api → plugin 401 |
| `pluginDaemon.difyApiKey` | `pluginDaemon.auth.difyApiKey` | 🟡 建议 | 同上 |

**升级前必做**:逐字符核对旧集群 Secret 与新 values-secrets.yaml,`global.appSecretKey` 必须 1:1。

---

## 4. 海外踩过的坑(国内必须提前避开)

### 4.1 plugin daemon 连不上 RDS — SSL 必须开

AWS RDS / 阿里云 RDS 默认强制 SSL,但 plugin daemon 用的 pgx 驱动默认 `sslmode=disable`。

**症状**:plugin daemon 日志报 `pq: SSL is not enabled on the server` 或 `connection refused`。

**修复**:`pluginDaemon.extraEnv` 加:
```yaml
- name: DB_SSL_MODE
  value: "require"
```

> 注意:这只对 plugin daemon 有效;api/worker 用的 SQLAlchemy/psycopg2 有自己的 SSL 配置(`SQLALCHEMY_DATABASE_URI_OPTIONS` 或 PG 连接串里加 `?sslmode=require`)。云 RDS 都要确认。

### 4.2 externalRedis 字段不能省

即使你的 Redis 没用 sentinel、单实例单 DB,chart 模板也**硬要求**这两段:

```yaml
externalRedis:
  enabled: true
  host: "..."
  password: "..."
  useSSL: false
  db:                  # ⚠️ 必须显式声明
    app: 0
    celery: 1
  sentinel:            # ⚠️ 必须显式声明
    enabled: false
```

**漏掉 `db.celery`**:`CELERY_BROKER_URL` 渲染成 `redis://...:6379/<no value>` → worker 启动崩。
**漏掉 `sentinel`**:helm template 直接报 `nil pointer evaluating interface {}.enabled`。

### 4.3 alembic migration 必须单副本

api 多副本同时启动 → 多个进程并发跑 alembic → schema 冲突/损坏。

**解法**:values-dify-prod.yaml 已加【升级模式切换块】,见第 5 节。

---

## 5. 升级模式切换(api 单副本跑 migration)

`values-dify-prod.yaml` 的 `api:` section 已埋好两段:

```yaml
# 【升级模式】api 单副本 + HPA 关闭(用完反注释)
# replicas: 1
# autoscaling:
#   enabled: false

# 【正常运行】小集群 2 副本 + HPA(min 2 / max 3)
replicas: 2
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 3
  ...
```

**用法**:
- **升级前**:把【正常运行】整段加 `#`,把【升级模式】整段去掉 `#` → `helm upgrade`
- **等 migration 完成**:`kubectl logs deploy/dify-api | grep -iE "migration|alembic"` 出现 `Migration completed` + pod `Ready 1/1`
- **升级后**:反过来切回【正常运行】→ 再 `helm upgrade` 一次

worker / plugin-daemon / beat 都有 `check-api` initContainer(因为 chart 默认 `api.migration: true`),api 没 ready 它们就一直等,**不会乱起**。

---

## 6. 连通性测试(T-1 天必跑)

详细命令见 `UPGRADE-RUNBOOK-JP-1.13.3.md`,核心 4 项:

| 资源 | 临时 pod 镜像 | 验证 |
|---|---|---|
| PG (新) | `postgres:15-alpine` | `psql` 连通 + 表数 ≈ 旧库 + `dify_plugin` 库存在 + `max_connections ≥ 400` |
| Redis (新) | `redis:7-alpine` | PING + AUTH + DB 0/1 都能 dbsize |
| S3 (旧共用) | `minio/mc` | 列 bucket + PUT/GET/DEL 测试对象 |
| Qdrant (旧共用) | `curlimages/curl` | 列 collections 数 ≈ 旧 datasets 数 + 测试 collection CRUD |

**任何一项失败,立即停止升级**。

---

## 7. 升级 checklist(精简版)

```markdown
T-1 天
- [ ] PG 备份脚本就位 + 演练
- [ ] 新集群部署但 replicas=0
- [ ] Secret 逐字符核对(尤其 global.appSecretKey)
- [ ] externalRedis.db / .sentinel 都显式声明
- [ ] pluginDaemon.extraEnv 已加 DB_SSL_MODE=require(如 RDS 开 SSL)
- [ ] 跑 4 项连通性测试,全绿
- [ ] Nginx 上游切换配置就位
- [ ] DNS TTL 已降到 60s
- [ ] 公告维护窗口

T-0(停机窗口)
- [ ] Nginx 把旧上游下线(返 503)
- [ ] redis-cli LLEN 所有 dify Celery 队列 = 0
- [ ] 旧 k8s api/worker/beat → 0
- [ ] pg_dump dify + dify_plugin
- [ ] pg_restore 到新 PG
- [ ] 校对表数 / 关键表行数对账
- [ ] values-dify-prod.yaml 切到【升级模式】
- [ ] helm upgrade
- [ ] api 日志:Migration completed + Ready 1/1
- [ ] values-dify-prod.yaml 切回【正常运行】
- [ ] helm upgrade 第二次

冒烟(全部用新建测试租户/dataset)
- [ ] Console 登录 → 模型供应商列表能拉出 → 调用 LLM 成功(验证 appSecretKey)
- [ ] 简单对话:blocking + streaming 各跑一次
- [ ] 跑一个用了 plugin 的工作流(验证 plugin 双 key + DB_SSL_MODE)
- [ ] 新建测试 dataset → 上传 1MB pdf → 等索引完成 → 检索(验证 S3 + Qdrant + worker)
- [ ] kubectl logs 全 pod grep -iE "401|403|InvalidToken|SSL" = 空

切流
- [ ] 金丝雀 5% → 监控 5min Grafana
- [ ] 全量 → 监控 30min(延迟/错误率/队列堆积)

收尾
- [ ] 清理冒烟产生的测试 dataset/Qdrant collection/S3 文件
- [ ] 旧集群 pod 保留 7 天(PVC + Secret 一并)
```

---

## 8. 回滚预案(任意阶段失败立即执行)

1. **Nginx 切回旧上游**(秒级生效)
2. 旧 K8s `kubectl scale` 回原副本数
3. 新集群 `helm uninstall` 或 `--replicas=0`(PVC + Secret 留着事后排查)
4. 公告"已回滚至维护开始时间点的数据状态"

---

## 9. 备查:相关文档

- `UPGRADE-RUNBOOK-JP-1.13.3.md` — 海外集群完整升级 runbook(含每一步命令)
- `SECRETS-MANAGEMENT.md` — Secret 管理与生成
- `CONFIG-STRUCTURE-REVIEW.md` — values 文件结构说明
- `values-secrets.yaml.example` — secret 字段模板
