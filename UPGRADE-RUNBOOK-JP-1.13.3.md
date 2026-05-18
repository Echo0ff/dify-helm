# 海外集群 Dify 1.10.1 → 1.13.3 蓝绿升级操作手册

> 适用范围：海外精品集群（3.19.168.125, AWS, 3 × 4C/8G）
> 当前版本：`1.10.1-fix.1`（分支 `hwjp`）
> 目标版本：`1.13.3`（分支 `hwjp-1.13.3`）
> 升级方式：**蓝绿升级**（Blue=旧集群 dify ns / Green=新集群 dify-green ns）
> 预计窗口：**90 分钟**（含 30 分钟回滚缓冲）
> 升级负责人：__________ ｜ 审核人：__________ ｜ 执行日期：__________

---

## 0. 升级背景

| 项 | 1.10.1 | 1.13.3 |
| --- | --- | --- |
| Chart appVersion | 1.10.1 | 1.13.3 |
| Streaming workflow 执行位置 | API Pod | **Worker Pod**（Redis 队列代理） |
| SSE 事件总线 | API 内部 | **Redis Streams** （PUBSUB） |
| 插件运行时 | plugin-daemon 0.4.x | **plugin-daemon 0.5.3-local**（启动需 5-8 分钟编译） |
| Sandbox | 0.2.12 | **0.2.14** |
| 关键新能力 | - | Human Input Node（人工审核节点）/ Hologres 向量库 |

⚠️ **架构变化重点**：海外集群 blocking:streaming ≈ 10:1，91% 流量仍走 API，所以 API 仍是性能关键路径，不需要大幅扩 Worker。

---

## 1. 升级前准备（提前 1~3 天）

### 1.1 代码仓库就绪检查

```bash
cd /path/to/dify-helm

# 拉取最新代码
git fetch origin

# 切到目标分支
git checkout hwjp-1.13.3
git pull --ff-only origin hwjp-1.13.3 || true

# 关键确认
grep "appVersion" charts/dify/Chart.yaml          # 应为 "1.13.3"
grep -E "tag: \"1.13.3\"|0.2.14|0.5.3-local" values-dify.yaml  # 应有 4 条命中
```

预期：
- `appVersion: "1.13.3"`
- `api/web tag: "1.13.3"`、`sandbox tag: "0.2.14"`、`pluginDaemon tag: 0.5.3-local`

### 1.2 准备 Green 环境的 secrets 文件

复制现有 `values-secrets.yaml` 为 `values-secrets-green.yaml`，**只改这些字段**：

```yaml
externalPostgres:
  enabled: true
  address: "<RDS-克隆实例-endpoint>"          # ← 改：克隆出的 RDS
  port: 5432
  username: "postgres"
  password: "<同生产>"
  dbName: "dify"

externalRedis:
  enabled: true
  host: "<新建-Redis-host>"                    # ← 改：新建的 Redis
  port: 6379
  password: "<新 Redis 密码>"

externalQdrant:
  enabled: true
  endpoint: "http://<qdrant-host>:6333"        # ← 共用：与 Blue 同一个 Qdrant
  apiKey: "<api-key>"
  timeout: 20

externalS3:
  enabled: true
  bucket: "<同生产>"                            # ← 共用：同一个 S3 桶
  endpoint: "https://s3.<region>.amazonaws.com"
  accessKey: "<同生产>"
  secretKey: "<同生产>"
  region: "<region>"
```

> 重要：`appSecretKey` / `internalApiKey` 必须与 Blue 集群完全一致，否则 Blue 集群已加密的数据（应用配置、token 等）无法解密。

### 1.3 基础设施克隆/新建（由 DBA 配合）

| 资源 | 操作 | 责任人 | 完成 |
| --- | --- | --- | --- |
| AWS RDS（生产） | 控制台克隆为 `dify-green-rds`，与生产同区域 | DBA | ☐ |
| AWS ElastiCache（Redis） | 新建独立实例 `dify-green-redis`，参数同生产 | DBA | ☐ |
| Qdrant | **共用，不克隆**（回滚后 Green 写入的向量是孤儿，无害） | - | ☐ |
| S3 | **共用，不克隆**（同上） | - | ☐ |

> 数据库克隆完成后做一次连通性测试：
> ```bash
> kubectl run -n default --rm -it pg-test --image=postgres:15 --restart=Never -- \
>   psql "postgresql://postgres:***@<green-rds-endpoint>:5432/dify" -c "SELECT version_num FROM alembic_version;"
> ```

### 1.4 DNS TTL 降低（升级前 24 小时）

```bash
# 假设入口域名是 dify.example.com
# 在 DNS 提供商（如 Route53）将 TTL 调到 60s（原 300s 或 3600s）
# 目的：切流量时变更快速生效
```

### 1.5 升级前压测预热（可选，提前 1 天）

在 Green 环境创建后先做一次干跑压测，提前发现问题：
```bash
# 见 §5 压力测试章节
```

### 1.6 检查清单

- ☐ `hwjp-1.13.3` 分支 helm template 渲染无错（`helm template dify ./charts/dify -f values-dify.yaml -f values-secrets.yaml -f values-dify-prod.yaml > /tmp/check.yaml`）
- ☐ RDS 克隆实例已就绪、连通性测试通过
- ☐ 新 Redis 实例已就绪、连通性测试通过
- ☐ Qdrant 当前状态健康（`curl http://<qdrant-host>:6333/healthz`）
- ☐ DNS TTL 已降到 60s
- ☐ Blue 集群当前快照已记录（`kubectl get pods -n dify -o wide > /tmp/blue-state.txt`）
- ☐ 关键插件清单已确认（OpenAI / Gemini / 各类工具插件）
- ☐ 维护公告已发布（如需要）

---

## 2. Phase 0：Blue 集群只读化（T+0 ~ T+5min）

> 目的：冻结 Blue 集群数据写入，避免与 Green migration 同时写库导致数据漂移。
> 注意：海外集群日请求量 1w+，1w/86400 ≈ 0.12 RPS，停机影响小，可以直接降副本到 0；若不允许停机则跳过此步骤，依赖 RDS 克隆点的一致性。

```bash
export BLUE_NS=dify
export BLUE_RELEASE=dify
export KUBECTL_CONTEXT=<aws-cluster-context>

kubectl config use-context $KUBECTL_CONTEXT

# 选项 A：完全停机（推荐，海外流量小）
helm upgrade $BLUE_RELEASE ./charts/dify -n $BLUE_NS \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  --set api.replicas=0 \
  --set api.autoscaling.enabled=false \
  --set worker.replicas=0 \
  --set beat.enabled=false \
  --set web.replicas=0 \
  --set sandbox.replicas=0 \
  --set pluginDaemon.replicas=0 \
  --timeout 10m --wait

# 验证：所有 Pod 都已下线
kubectl get pods -n $BLUE_NS
# 期望：返回 "No resources found in dify namespace." 或全部 Terminating
```

⚠️ **此时不能 helm uninstall Blue release，回滚要用！**

---

## 3. Phase 1：Migration（T+5 ~ T+15min）

> 在 Green namespace 用单副本 API 启动，仅做数据库 migration（alembic upgrade）。

### 3.1 创建 Green namespace 并启动 migration

```bash
export GREEN_NS=dify-green
export GREEN_RELEASE=dify

kubectl create namespace $GREEN_NS --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install $GREEN_RELEASE ./charts/dify -n $GREEN_NS --create-namespace \
  -f values-dify.yaml \
  -f values-secrets-green.yaml \
  -f values-dify-prod.yaml \
  --set api.replicas=1 \
  --set api.autoscaling.enabled=false \
  --set worker.replicas=0 \
  --set beat.enabled=false \
  --set web.replicas=0 \
  --set sandbox.replicas=0 \
  --set pluginDaemon.replicas=0 \
  --timeout 20m --wait
```

### 3.2 等待 migration 完成

```bash
# 看 API Pod 启动日志，确认 migration 完成
kubectl logs -n $GREEN_NS deploy/$GREEN_RELEASE-api -f | grep -E "alembic|migration|Running|Listening"

# 关键日志：
#   "Running migration ..." → 正在执行
#   "Running command: gunicorn ..." → migration 已完成，gunicorn 已起
```

### 3.3 验证数据库版本

```bash
# 从 K8s 内执行，绕过外网防火墙
kubectl run -n $GREEN_NS --rm -it pg-check --image=postgres:15 --restart=Never -- \
  psql "postgresql://postgres:<password>@<green-rds-endpoint>:5432/dify" \
  -c "SELECT version_num FROM alembic_version;"
```

预期：返回一个 1.13.3 对应的 alembic 版本号（非 1.10.1 的版本号）。
具体版本号可通过 `kubectl exec` 进 API Pod 查 `cd /app/api && alembic heads`。

### 3.4 Migration 失败处理

如果 migration 失败：
1. 截图保存日志 `kubectl logs -n $GREEN_NS deploy/$GREEN_RELEASE-api > /tmp/migration-fail-$(date +%Y%m%d%H%M).log`
2. **不要继续**，直接进入回滚流程（§8）

---

## 4. Phase 2：Green 全量启动（T+15 ~ T+25min）

```bash
helm upgrade $GREEN_RELEASE ./charts/dify -n $GREEN_NS \
  -f values-dify.yaml \
  -f values-secrets-green.yaml \
  -f values-dify-prod.yaml \
  --timeout 30m --wait
```

> ⚠️ `plugin-daemon` 启动需要 5~8 分钟编译插件，`--timeout 30m` 是保险时间。

### 4.1 等待所有 Pod Ready

```bash
watch -n 5 'kubectl get pods -n dify-green'

# 期望最终所有 pod 都是 1/1 Running
#   dify-api-xxx                  1/1   Running
#   dify-api-yyy                  1/1   Running
#   dify-worker-xxx               1/1   Running
#   dify-beat-xxx                 1/1   Running
#   dify-web-xxx                  1/1   Running
#   dify-sandbox-xxx              1/1   Running
#   dify-sandbox-yyy              1/1   Running
#   dify-proxy-xxx                1/1   Running
#   dify-ssrf-proxy-xxx           1/1   Running
#   dify-plugin-daemon-xxx        1/1   Running（最慢，~5-8 分钟）
#   dify-plugin-daemon-yyy        1/1   Running
```

### 4.2 关键启动检查

```bash
# 1. plugin-daemon 编译完成
kubectl logs -n dify-green deploy/dify-plugin-daemon --tail=200 | grep -iE "ready|listening|started|error"

# 2. API 日志无 5xx / panic
kubectl logs -n dify-green deploy/dify-api --tail=300 | grep -iE "error|exception|traceback" | head -20

# 3. Worker 已订阅正确的 Celery 队列
kubectl logs -n dify-green deploy/dify-worker --tail=200 | grep -iE "queue|celery|starting"
# 期望日志包含：workflow_based_app_execution, dataset_summary, api_token

# 4. Redis Streams 已就绪（1.13.x 新增）
kubectl exec -n dify-green deploy/dify-api -- env | grep PUBSUB
# 期望：PUBSUB_REDIS_CHANNEL_TYPE=streams
```

---

## 5. Phase 3：冒烟测试（T+25 ~ T+45min）

### 5.1 准备测试入口

Green 集群暂时还没接管 DNS，通过 port-forward 或临时 LB 访问：

```bash
# 方法 A：本地 port-forward 测试
kubectl port-forward -n dify-green svc/dify-proxy 8080:80
# 访问 http://localhost:8080

# 方法 B：临时 NodePort（如允许）
kubectl patch svc -n dify-green dify-proxy -p '{"spec":{"type":"NodePort"}}'
kubectl get svc -n dify-green dify-proxy
# 通过任一 worker 节点的 NodePort 访问
```

### 5.2 基础功能验证（P0，**必须通过**）

| 项 | 验证步骤 | 通过标准 | 结果 |
| --- | --- | --- | --- |
| Console 登录 | 用现有账号登录 | 成功进入 | ☐ |
| 应用列表 | 进入应用列表页 | 历史应用都在，数量与 Blue 一致 | ☐ |
| OpenAI 调用 | 任意应用发送一条消息 | 模型正常返回（**P0**，失败立即回滚） | ☐ |
| Gemini 调用 | 切到 Gemini 模型发送消息 | 模型正常返回（**P0**） | ☐ |
| Embedding | 上传一份 PDF 到知识库 | 索引完成，召回正常 | ☐ |
| 代码节点 | 工作流里执行一段 Python | 返回正确结果 | ☐ |
| 文件上传 | 上传图片到对话 | 上传成功，能正常显示 | ☐ |
| Streaming workflow | 跑一个 streaming 模式工作流 | SSE 正常推流（不会卡住） | ☐ |
| Blocking workflow | 跑一个 blocking 模式工作流 | 正常返回结果 | ☐ |

> ⚠️ **任何一项 P0 失败 → 立即跳到 §8 回滚**

### 5.3 1.13.x 新功能验证（可选，但建议）

- ☐ Human Input Node：在工作流里插入一个人工审核节点，验证暂停 + 继续执行
- ☐ SSE 事件总线：开浏览器 DevTools，确认 streaming 响应通过 Redis Streams 推送（不再是 API 内存）

### 5.4 插件兼容性验证

```bash
# 进入 Console → 工作区设置 → 模型供应商
# 确认所有已配置的模型供应商图标显示正常，且能调用

# 命令行检查：plugin-daemon 错误日志
kubectl logs -n dify-green deploy/dify-plugin-daemon --tail=500 | grep -iE "error|exception|traceback" | head -20

# 30 分钟内持续监控
kubectl logs -f -n dify-green deploy/dify-plugin-daemon | grep -iE "error|exception"
```

常见插件兼容性问题：
- 插件 manifest 格式变化 → 表现为插件加载失败
- 插件 API 接口变化 → 表现为调用时 500
- 插件依赖包冲突 → plugin-daemon 启动报错

### 5.5 Worker 队列验证

```bash
kubectl logs -n dify-green deploy/dify-worker --tail=300 | grep "queues"

# 必须包含：
#   workflow_based_app_execution, dataset_summary, api_token
```

---

## 6. Phase 4：压力测试（T+45 ~ T+60min）

### 6.1 准备测试工作流

在 Green Console 创建 2 个测试工作流（如已有可复用）并发布为 API：

- **工作流 A（blocking）**：开始 → LLM 节点（prompt: "answer 1+1 in one word"） → 结束
- **工作流 B（streaming）**：同上，response_mode=streaming

记下两个 API Key：`app-blocking-xxx`、`app-streaming-xxx`

### 6.2 Blocking 压测（10 并发，5 分钟）

```bash
# 安装 hey（如未装）
brew install hey

# 通过 port-forward 或临时 LB 拿到 Green 入口
export GREEN_EP=http://localhost:8080   # 或 http://<node-ip>:<nodeport>

hey -n 2000 -c 10 -t 120 \
  -m POST \
  -H "Authorization: Bearer app-blocking-xxx" \
  -H "Content-Type: application/json" \
  -d '{"inputs":{"query":"answer 1+1 in one word"},"response_mode":"blocking","user":"loadtest"}' \
  $GREEN_EP/v1/workflows/run \
  | tee /tmp/loadtest-blocking-$(date +%Y%m%d%H%M).log
```

### 6.3 Streaming 压测（2 并发，5 分钟）

```bash
cat > /tmp/streaming-test.sh <<'EOF'
#!/bin/bash
ENDPOINT="$1"
API_KEY="$2"
CONCURRENCY=${3:-2}
DURATION=${4:-300}
end_time=$((SECONDS + DURATION))
success=0; fail=0
run_one() {
  while [ $SECONDS -lt $end_time ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 120 \
      -X POST "${ENDPOINT}/v1/workflows/run" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"inputs":{"query":"hello"},"response_mode":"streaming","user":"loadtest-'$$'"}')
    [ "$code" = "200" ] && ((success++)) || { ((fail++)); echo "FAIL: HTTP $code"; }
    sleep 1
  done
}
for i in $(seq 1 $CONCURRENCY); do run_one & done
wait
echo "Done. success=$success fail=$fail"
EOF
chmod +x /tmp/streaming-test.sh
/tmp/streaming-test.sh $GREEN_EP app-streaming-xxx 2 300 \
  | tee /tmp/loadtest-streaming-$(date +%Y%m%d%H%M).log
```

### 6.4 压测期间监控

```bash
# 终端 1：Pod 资源
watch -n 2 'kubectl top pods -n dify-green --sort-by=cpu'

# 终端 2：DB 连接数
kubectl run -n default --rm -it pg-mon --image=postgres:15 --restart=Never -- \
  psql "postgresql://postgres:***@<green-rds-endpoint>:5432/dify" \
  -c "SELECT count(*), state FROM pg_stat_activity WHERE datname='dify' GROUP BY state;"

# 终端 3：错误日志
kubectl logs -f -n dify-green deploy/dify-api --tail=20 | grep -iE "error|5xx|QueuePool"
```

### 6.5 压测通过标准（海外集群）

| 指标 | 通过标准 | 实测 | 通过 |
| --- | --- | --- | --- |
| Blocking 错误率 | < 1% | __ % | ☐ |
| Blocking P95 延迟 | < 15s（含 LLM RT） | __ s | ☐ |
| Blocking P99 延迟 | < 30s | __ s | ☐ |
| Streaming 错误率 | < 1% | __ % | ☐ |
| Streaming 首 token | < 8s | __ s | ☐ |
| API Pod CPU 峰值 | < 80% | __ % | ☐ |
| Worker Pod CPU 峰值 | < 70% | __ % | ☐ |
| DB 连接数峰值 | < 280（RDS 400 的 70%） | __ | ☐ |
| QueuePool limit reached | **不应出现** | - | ☐ |
| OOMKilled | **不应出现** | - | ☐ |
| CrashLoopBackOff | **不应出现** | - | ☐ |
| plugin-daemon 报错 | **不应出现** | - | ☐ |

> 不达标处理：
> - 错误率高 → 查 API 日志，确认是否是 LLM 厂商限流（如是则降低并发重测）
> - DB 连接逼近上限 → 调小 `SQLALCHEMY_POOL_SIZE` / `MAX_OVERFLOW`，重新 helm upgrade
> - OOMKilled → 调大 limits，重新 helm upgrade

---

## 7. Phase 5：切流量（T+60 ~ T+70min）

### 7.1 切流前最终确认

| 确认项 | 状态 |
| --- | --- |
| P0 模型（OpenAI / Gemini）调用通过 | ☐ |
| Embedding + 知识库召回通过 | ☐ |
| 代码节点（Sandbox）通过 | ☐ |
| Blocking 压测达标 | ☐ |
| Streaming 压测达标 | ☐ |
| 无 DB 连接池报错 | ☐ |
| 无 plugin 兼容性报错 | ☐ |
| 30 分钟稳态运行无异常 | ☐ |
| 切流量执行人 + 确认人都在线 | ☐ |

### 7.2 暴露 Green Service

Green namespace 的 `dify-proxy` 需要先暴露为 LB / Ingress：

```bash
# 选项 A：Green 沿用 Blue 的 LoadBalancer（推荐）
# 通过修改 LB Target 将流量指向 dify-green/dify-proxy
# 具体看你们用 AWS ALB Ingress / NLB / 还是 Service type=LoadBalancer

# 选项 B：Service type=LoadBalancer 申请新 LB（会拿到新 EIP，DNS 切换更慢）
kubectl patch svc -n dify-green dify-proxy -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc -n dify-green dify-proxy -w
# 等 EXTERNAL-IP 出现
```

### 7.3 DNS 切换

```bash
# 假设域名 dify.example.com，Blue EIP=A.A.A.A，Green EIP=B.B.B.B
# 在 DNS 控制台（Route53/Cloudflare/...）将 A 记录改为 B.B.B.B
# TTL 60s 意味着最迟 60s 后所有客户端解析到新地址

# 验证
for i in 1 2 3 4 5; do dig +short dify.example.com; sleep 5; done
```

### 7.4 切流后立即观察（15 分钟）

```bash
# 终端 1：错误日志实时滚动
kubectl logs -f -n dify-green deploy/dify-api --tail=20 \
  | grep --line-buffered -iE "error|5xx|exception|traceback"

# 终端 2：Worker 日志
kubectl logs -f -n dify-green deploy/dify-worker --tail=20 \
  | grep --line-buffered -iE "error|exception"

# 终端 3：plugin-daemon 日志
kubectl logs -f -n dify-green deploy/dify-plugin-daemon --tail=20 \
  | grep --line-buffered -iE "error|exception"

# 终端 4：Pod 资源
watch -n 5 'kubectl top pods -n dify-green'
```

15 分钟内观察指标：

- ☐ 真实用户请求错误率 < 0.5%
- ☐ P95 延迟 < 8s（与 Blue 相当或更好）
- ☐ 无 Pod 重启
- ☐ DB 连接数稳定 < 200

---

## 8. 回滚预案（任何阶段失败都可用）

> 设计原则：Blue 集群从未被修改，回滚 = 切流回 Blue + 拉起 Blue 副本。

### 8.1 触发条件

满足以下任一条件**立即回滚**：

- Migration 失败（§3.4）
- P0 模型调用失败（§5.2）
- 切流后 5 分钟内错误率 > 5%
- 切流后出现持续 P99 > 60s
- 任何数据丢失迹象

### 8.2 回滚步骤（目标：5 分钟内完成）

```bash
# 1. DNS 切回 Blue（如果已切了）
#    将 A 记录改回 A.A.A.A（Blue EIP），TTL 60s

# 2. 拉起 Blue 集群副本
export BLUE_NS=dify
export BLUE_RELEASE=dify

helm upgrade $BLUE_RELEASE ./charts/dify -n $BLUE_NS \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  --timeout 15m --wait

# 3. 验证 Blue 集群恢复
kubectl get pods -n $BLUE_NS
# 期望所有 Pod 都 Running

# 4. （可选）保留 Green 集群供事后调查
#    不要立刻删除 Green，留 24 小时分析日志
```

### 8.3 数据一致性确认

- ✅ **RDS**：Blue 用的是原生产 RDS，Green 用的是克隆 RDS，互不影响 → 回滚后 Blue 数据完整
- ✅ **Redis**：Blue 用原 Redis，Green 用新 Redis → 回滚后 Blue Redis 未被污染
- ⚠️ **S3**：共用 → Green 期间用户上传的文件会保留在 S3，回滚后这些文件在 Blue 看不到（孤儿文件，无害但占空间）
- ⚠️ **Qdrant**：共用 → Green 期间新建的向量集合会保留，回滚后在 Blue 看不到（孤儿，无害）

---

## 9. 升级后清理（T+24h 稳定后）

### 9.1 清理 Blue 集群（确认 Green 稳定 24 小时后再执行）

```bash
# 软删除：先把 Blue 副本缩到 0，保留配置
helm upgrade $BLUE_RELEASE ./charts/dify -n $BLUE_NS \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  --set api.replicas=0 \
  --set api.autoscaling.enabled=false \
  --set worker.replicas=0 \
  --set beat.enabled=false \
  --set web.replicas=0 \
  --set sandbox.replicas=0 \
  --set pluginDaemon.replicas=0 \
  --timeout 10m --wait

# 等 1 周后彻底卸载
# helm uninstall $BLUE_RELEASE -n $BLUE_NS
# kubectl delete namespace $BLUE_NS
```

### 9.2 释放 Blue RDS / Redis

```bash
# 等 Green 稳定运行 1 周后，再释放 Blue 的 RDS 实例和 Redis 实例
# AWS 控制台操作，注意先打快照备份
```

### 9.3 DNS TTL 调回

```bash
# 升级稳定后将 TTL 调回原值（300s 或 3600s）以减少 DNS 查询压力
```

### 9.4 文档归档

- ☐ 升级日志归档到内部 wiki
- ☐ 压测结果记录归档
- ☐ 本手册标注实际执行时间与发现的问题
- ☐ 同步给国内集群升级负责人作为参考

---

## 10. 附录

### 10.1 关键命令速查

```bash
# 查看 release 状态
helm list -n dify-green
helm status dify -n dify-green
helm history dify -n dify-green

# 强制重启某组件
kubectl rollout restart deploy/dify-api -n dify-green
kubectl rollout status deploy/dify-api -n dify-green

# 查看实际生效的环境变量
kubectl exec -n dify-green deploy/dify-api -- env | sort

# 查看 helm 渲染结果（部署前 dry-run）
helm template dify ./charts/dify \
  -f values-dify.yaml -f values-secrets-green.yaml -f values-dify-prod.yaml \
  > /tmp/green-render.yaml

# 比较 Blue / Green 环境变量差异
diff <(kubectl exec -n dify deploy/dify-api -- env | sort) \
     <(kubectl exec -n dify-green deploy/dify-api -- env | sort)
```

### 10.2 关键变更摘要（vs 1.10.1）

| 变更类型 | 详情 |
| --- | --- |
| 新增环境变量 | `UV_CACHE_DIR`、`PUBSUB_REDIS_CHANNEL_TYPE=streams`、`PUBSUB_STREAMS_RETENTION_SECONDS`、`REDIS_MAX_CONNECTIONS`、`CELERY_TASK_ANNOTATIONS`、`CELERY_PREFETCH_MULTIPLIER`、`CELERY_WORKER_AMOUNT`、`MAX_TASKS_PER_CHILD`、`ENABLE_HUMAN_INPUT_TIMEOUT_TASK`、`HUMAN_INPUT_TIMEOUT_TASK_INTERVAL`、`PLUGIN_DAEMON_TIMEOUT`、`PLUGIN_MODEL_SCHEMA_CACHE_TTL`、`ENABLE_WORKFLOW_RUN_CLEANUP_TASK` |
| 删除环境变量 | `REDIS_POOL_SIZE`、`REDIS_POOL_MAX_CONNECTIONS`、`CELERY_BROKER_POOL_LIMIT`、`SQLALCHEMY_ECHO_POOL`、`SQLALCHEMY_POOL_RESET_ON_RETURN`、`RETRY_TIMES`、`MAX_TASK_PRE_CHILD`(typo)、`CELERY_MAX_WORKERS`、`CELERY_MIN_WORKERS` |
| 配置迁移 | `api.url.appWeb/files` → `global.appWebDomain/filesDomain` |
| 自定义 prompt | 不再通过 ConfigMap 挂载，使用 Dify 1.13.x 内置默认（多语言友好） |
| 资源调整 | API HPA maxReplicas 4 → 5，Sandbox HPA maxReplicas 3 → 4（向量库独立后释放余量） |
| 镜像版本 | api/web `1.13.3`、sandbox `0.2.14`、plugin-daemon `0.5.3-local` |

### 10.3 故障排查（FAQ）

**Q1: plugin-daemon 5 分钟还没 Ready？**

A: 看日志 `kubectl logs -n dify-green deploy/dify-plugin-daemon`。常见原因：
- 网络问题，pip install 卡住 → 检查 `PIP_MIRROR_URL` 是否能访问
- 磁盘不足 → 检查节点磁盘 `df -h`
- 等到 7 分钟（readinessProbe initialDelaySeconds=420）仍不 Ready → 进入排错模式

**Q2: API 启动后报 `redis.exceptions.ResponseError: stream not found`？**

A: 这是 1.13.x SSE 走 Redis Streams 后的预期日志，首次启动 stream 还不存在；不影响功能。

**Q3: Worker 日志看不到 streaming workflow 在执行？**

A: 确认 `PUBSUB_REDIS_CHANNEL_TYPE=streams` 在 API 和 Worker 中**都**注入了，且 Redis 实例相同。

**Q4: 切流后某个用户报某个工作流的 chat history 看不到？**

A: 该用户的浏览器可能缓存到 Blue 的 SSE 连接，让用户刷新页面即可。

**Q5: 回滚后发现 Qdrant 中有孤儿向量集合怎么办？**

A: 通过 Qdrant API 查列表 `curl http://<qdrant>:6333/collections`，对比 Blue 数据库中的 `datasets` 表，删除多出的集合。

### 10.4 联系人

- 升级执行：__________
- DBA 配合：__________
- DNS 配合：__________
- 模型供应商联系人：__________（出现 LLM 限流时联系）
- On-call 值班：__________

---

> 文档版本：1.0
> 编写时间：2026-05-18
> 配套配置：分支 `hwjp-1.13.3` commit `f19b113`
