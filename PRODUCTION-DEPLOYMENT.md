# Dify 生产环境部署说明

## 📊 部署概览

### 集群配置
- **Master 节点**: `izbp16g71i3ye4pe52adhmz` - 32C/124G
- **Worker 节点 1**: `izbp16qq4fgg0w02hw82owz` - 16C/32G
- **Worker 节点 2**: `izbp16qq4fgg0w02hw82oxz` - 16C/32G
- **总资源**: 64 核 / 188GB 内存

### 性能目标
- **当前状态**: 单副本，RPS ~20，响应时间 200ms
- **优化目标**: RPS 400+（参考单节点 Docker 部署）
- **资源利用**: 从当前 1-2 核优化到充分利用 64 核资源

---

## 🚀 优化策略

### 1. 服务副本数配置

| 服务 | 原副本 | 新副本 | HPA 范围 | 资源配置 (requests/limits) |
|------|--------|--------|----------|---------------------------|
| **API** | 1 | 3 | 3-8 | 4C/4G - 8C/8G |
| **Worker** | 1 | 3 | 3-6 | 2C/2G - 4C/4G |
| **Web** | 1 | 2 | 2-4 | 0.5C/512M - 1C/1G |
| **Sandbox** | 1 | 2 | 2-4 | 1C/1G - 2C/2G |
| **Proxy** | 1 | 2 | - | 0.5C/256M - 1C/512M |
| **SSRF Proxy** | 1 | 2 | - | 0.2C/128M - 0.5C/256M |
| **Plugin Daemon** | 1 | 2 | - | 1C/1G - 2C/2G |
| **Beat** | 1 | 1 | - | 0.2C/256M - 0.5C/512M |

### 2. API 服务优化（最关键）

**为什么 API 是瓶颈？**
- 单节点 Docker 环境中，API 可占用 20 核心达到 400 RPS
- 现在配置了 3-8 个副本，每个 4-8 核
- 理论最大资源：8 副本 × 8 核 = 64 核（可能超过集群总核心）

**优化配置：**
```yaml
api:
  replicas: 3
  resources:
    requests:
      cpu: "4000m"
      memory: "4Gi"
    limits:
      cpu: "8000m"
      memory: "8Gi"
  autoscaling:
    minReplicas: 3
    maxReplicas: 8
    targetCPUUtilizationPercentage: 60
    targetMemoryUtilizationPercentage: 70
```

**Gunicorn 工作进程配置：**
- 每个 Pod 4 个 worker
- 每个 worker 2 个线程
- 总并发能力：3 Pod × 4 workers × 2 threads = 24 并发（可扩展到 64）

### 3. Worker 服务优化

**异步任务处理：**
- 3-6 个副本处理 Celery 任务队列
- 每个 Pod 4 个并发 worker
- 总并发能力：3 Pod × 4 workers = 12 并发（可扩展到 24）

**Celery 配置：**
```yaml
- name: CELERY_WORKER_CONCURRENCY
  value: "4"
- name: CELERY_MAX_TASKS_PER_CHILD
  value: "100"  # 防止内存泄漏
```

### 4. 节点亲和性策略

**Pod 分布优化：**
- **podAntiAffinity**: 将同类 Pod 分散到不同节点，提高可用性
- **nodeAffinity**: API 服务优先调度到 Master 节点（资源最多）
- **自动负载均衡**: Kubernetes 会在节点间均衡分配

---

## 📈 监控与观测

### 1. 查看当前状态

```bash
# 查看所有 Pod 状态
kubectl get pods -n dify -o wide

# 查看 HPA 状态
kubectl get hpa -n dify

# 查看资源使用情况
kubectl top pods -n dify --sort-by=cpu

# 查看节点资源
kubectl top nodes
```

### 2. 关键监控指标

**应用层指标：**
- **RPS（每秒请求数）**: 使用 Locust 或 k6 压测获取
- **响应时间**: P50, P95, P99 延迟
- **错误率**: 5xx 错误比例
- **并发数**: 当前活跃请求数

**资源层指标：**
- **API Pod CPU 使用率**: 目标 60-70%（触发扩容阈值）
- **Worker Pod CPU 使用率**: 目标 70-80%
- **内存使用率**: 避免超过 80%（OOM 风险）
- **HPA 事件**: 扩容/缩容频率

**建议监控工具：**
- Prometheus + Grafana（推荐）
- Kubernetes Dashboard
- `kubectl top` 命令

### 3. 实时日志查看

```bash
# API 日志
kubectl logs -f -n dify -l component=api --tail=100

# Worker 日志
kubectl logs -f -n dify -l component=worker --tail=100

# 查看所有容器错误
kubectl get events -n dify --sort-by='.lastTimestamp'
```

---

## 🧪 压测建议

### 1. 准备工作

```bash
# 确保所有 Pod 就绪
kubectl get pods -n dify | grep -v Running

# 查看当前 HPA 基线
kubectl get hpa -n dify
```

### 2. Locust 压测配置

**极简工作流测试（当前 RPS ~20）：**
```python
# locustfile.py
from locust import HttpUser, task, between

class DifyUser(HttpUser):
    wait_time = between(0.1, 0.5)  # 快速请求
    
    @task
    def workflow_run(self):
        self.client.post("/v1/workflows/run", json={
            "inputs": {},
            "response_mode": "streaming"
        }, headers={
            "Authorization": "Bearer YOUR_API_KEY"
        })

# 启动压测
# locust -f locustfile.py --host=http://your-dify-domain --users=100 --spawn-rate=10
```

### 3. 分阶段压测

**阶段 1: 基线测试（40 用户）**
```bash
locust --users=40 --spawn-rate=5 --run-time=5m
# 预期 RPS: 60-80（3x API 副本）
```

**阶段 2: 中等负载（100 用户）**
```bash
locust --users=100 --spawn-rate=10 --run-time=10m
# 预期 RPS: 150-200（可能触发扩容）
# 观察 HPA 是否扩容到 4-5 个 API Pod
```

**阶段 3: 高负载（200 用户）**
```bash
locust --users=200 --spawn-rate=20 --run-time=15m
# 预期 RPS: 300-400（最大扩容）
# 观察 HPA 是否扩容到 6-8 个 API Pod
```

**阶段 4: 极限测试（400 用户）**
```bash
locust --users=400 --spawn-rate=40 --run-time=20m
# 预期 RPS: 400+（全部资源占满）
# 监控节点 CPU 是否达到 80%+
```

### 4. 压测中监控

**开 3 个终端窗口：**

```bash
# 终端 1: 实时监控 HPA
watch -n 2 'kubectl get hpa -n dify'

# 终端 2: 实时监控 Pod 资源
watch -n 2 'kubectl top pods -n dify --sort-by=cpu'

# 终端 3: 实时监控节点资源
watch -n 2 'kubectl top nodes'
```

---

## 🔧 调优建议

### 1. 如果 RPS 未达预期

**检查清单：**
```bash
# 1. 确认 HPA 是否扩容
kubectl get hpa -n dify
kubectl describe hpa dify-api -n dify

# 2. 查看 API Pod 是否均衡分布
kubectl get pods -n dify -l component=api -o wide

# 3. 检查资源限制是否过低
kubectl describe pod <api-pod-name> -n dify | grep -A 5 "Limits"

# 4. 查看是否有 Pod 重启
kubectl get pods -n dify | grep Restart

# 5. 检查网络延迟
kubectl exec -it <api-pod-name> -n dify -- ping <service-name>
```

**可能的优化点：**
- 增加 `api.autoscaling.maxReplicas` 到 10-12
- 调低 HPA 触发阈值到 50%（更激进扩容）
- 增加 Gunicorn worker 数量到 6-8
- 检查数据库/Redis 连接池配置

### 2. 如果资源浪费

**缩减策略：**
```yaml
# values-dify-prod.yaml 调整
api:
  replicas: 2                  # 降低初始副本
  autoscaling:
    minReplicas: 2
    maxReplicas: 6
    targetCPUUtilizationPercentage: 70  # 提高阈值
```

### 3. 如果出现 OOM（内存不足）

```bash
# 查看内存使用趋势
kubectl top pods -n dify --sort-by=memory

# 查看 OOM 事件
kubectl get events -n dify | grep OOM

# 临时增加内存限制
kubectl patch deployment dify-api -n dify -p '{"spec":{"template":{"spec":{"containers":[{"name":"api","resources":{"limits":{"memory":"12Gi"}}}]}}}}'
```

### 4. 数据库优化

**PostgreSQL 连接池：**
```yaml
api:
  extraEnv:
    - name: SQLALCHEMY_POOL_SIZE
      value: "20"              # 每个 Pod 20 个连接
    - name: SQLALCHEMY_POOL_RECYCLE
      value: "3600"            # 1 小时回收
    - name: SQLALCHEMY_MAX_OVERFLOW
      value: "10"              # 额外 10 个溢出连接
```

**Redis 连接池：**
```yaml
api:
  extraEnv:
    - name: REDIS_POOL_SIZE
      value: "50"              # 每个 Pod 50 个连接
```

---

## 📝 部署与回滚

### 应用生产配置

```bash
# 方法 1: 使用两个配置文件（推荐）
cd /home/zard/dify-helm
helm upgrade dify charts/dify \
  -f values-dify.yaml \
  -f values-dify-prod.yaml \
  -n dify

# 方法 2: 仅使用生产配置
helm upgrade dify charts/dify \
  -f values-dify-prod.yaml \
  -n dify --wait
```

### 回滚到单副本

```bash
# 方法 1: 回滚到上一个版本
helm rollback dify -n dify

# 方法 2: 仅使用基础配置
helm upgrade dify charts/dify \
  -f values-dify.yaml \
  -n dify

# 方法 3: 手动缩容（快速临时）
kubectl scale deployment dify-api --replicas=1 -n dify
kubectl scale deployment dify-worker --replicas=1 -n dify
```

### 查看部署历史

```bash
# 查看 Helm 版本历史
helm history dify -n dify

# 查看特定版本的值
helm get values dify -n dify --revision 20
```

---

## 🎯 预期效果

### 资源利用率对比

| 指标 | 优化前 | 优化后（预期） |
|------|--------|---------------|
| **API 副本数** | 1 | 3-8（动态） |
| **Worker 副本数** | 1 | 3-6（动态） |
| **总 CPU 使用** | 1-2 核 | 30-50 核（高负载） |
| **总内存使用** | ~2GB | 30-60GB（高负载） |
| **RPS** | ~20 | 300-400+ |
| **平均响应时间** | 200ms | 100-150ms（更多副本分担） |
| **P99 响应时间** | ~500ms | ~300ms |

### 成本效益分析

**资源成本：**
- Master: 32C/124G（已有）
- 2x Worker: 16C/32G（已有）
- **无额外成本**，仅充分利用现有资源

**性能提升：**
- RPS 提升 15-20 倍（20 → 400）
- 响应时间降低 30-50%
- 系统可用性提升（多副本容错）

---

## ⚠️ 注意事项

### 1. 数据库连接数

**当前配置最大连接数：**
- API: 8 Pod × 20 连接 = 160 连接
- Worker: 6 Pod × 20 连接 = 120 连接
- **总计: ~300 连接**

**请确保 PostgreSQL 支持：**
```sql
-- 查看当前最大连接数
SHOW max_connections;

-- 如果不足，需要调整（需要重启数据库）
ALTER SYSTEM SET max_connections = 500;
```

### 2. Redis 连接数

**当前配置最大连接数：**
- API: 8 Pod × 50 连接 = 400 连接
- Worker: 6 Pod × 50 连接 = 300 连接
- **总计: ~700 连接**

**确保 Redis 配置：**
```bash
# 查看 Redis 最大连接数
redis-cli CONFIG GET maxclients

# 如果不足，调整
redis-cli CONFIG SET maxclients 10000
```

### 3. 存储 IOPS

高并发下 OSS/对象存储 IOPS 需求增加：
- 监控 OSS 请求数和延迟
- 考虑启用 CDN 缓存静态资源
- 增加 OSS 带宽限制（如有）

### 4. 网络带宽

确保节点间网络带宽充足：
- 内网带宽建议 ≥ 1Gbps
- 监控 Pod 间网络延迟
- 使用 `iperf3` 测试节点间带宽

---

## 🔍 故障排查

### Pod 无法启动

```bash
# 查看 Pod 详情
kubectl describe pod <pod-name> -n dify

# 常见问题：
# 1. 资源不足 -> 降低 requests 或增加节点
# 2. 镜像拉取失败 -> 检查镜像仓库
# 3. 配置错误 -> 检查 ConfigMap/Secret
```

### HPA 不生效

```bash
# 检查 metrics-server
kubectl get deployment metrics-server -n kube-system

# 如果不存在，安装
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 查看 HPA 详细信息
kubectl describe hpa dify-api -n dify
```

### 服务响应慢

```bash
# 检查数据库连接
kubectl exec -it <api-pod> -n dify -- nc -zv <postgres-host> 5432

# 检查 Redis 连接
kubectl exec -it <api-pod> -n dify -- nc -zv <redis-host> 6379

# 检查 OSS 延迟
kubectl exec -it <api-pod> -n dify -- time curl -I <oss-endpoint>
```

---

## 📞 技术支持

**配置文件位置：**
- 基础配置: `/home/zard/dify-helm/values-dify.yaml`
- 生产优化: `/home/zard/dify-helm/values-dify-prod.yaml`
- 本文档: `/home/zard/dify-helm/PRODUCTION-DEPLOYMENT.md`

**相关文档：**
- [Dify 官方文档](https://docs.dify.ai/)
- [Kubernetes HPA](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Helm 文档](https://helm.sh/docs/)

---

**部署时间**: 2025-10-11  
**当前版本**: Dify 1.7.2  
**Helm Chart 版本**: 参见 Chart.yaml  

祝压测顺利！🚀

