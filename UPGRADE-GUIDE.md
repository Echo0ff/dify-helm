# Dify Helm 升级指南 - 自定义 Prompts

## 当前修改内容

### 1. 已创建 ConfigMap
```bash
kubectl create configmap dify-prompts \
  --from-file=prompts.py=./custom-configs/prompts.py \
  -n dify
```

### 2. 修改的文件
- `charts/dify/templates/api-deployment.yaml` - 添加自定义 volumes 支持
- `values-dify-prod.yaml` - 配置 prompts.py 挂载

## 升级前检查

### 1. 验证 ConfigMap
```bash
kubectl get configmap dify-prompts -n dify
kubectl describe configmap dify-prompts -n dify
```

### 2. 验证 Helm 模板渲染
```bash
helm template dify ./charts/dify -n dify \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  --show-only templates/api-deployment.yaml | less
```

### 3. Dry-run 测试
```bash
helm upgrade dify ./charts/dify -n dify \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  --dry-run --debug | less
```

## 执行升级

### 推荐方式：使用 --wait 确保成功
```bash
helm upgrade dify ./charts/dify -n dify \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  --wait --timeout 10m
```

## 升级流程时间线

```
时间轴：
├─ 0s    │ 开始升级
│         │
├─ 0-5s  │ 创建新 API Pod (maxSurge: 3)
│         │ - 拉取镜像（如已缓存则很快）
│         │ - 容器启动
│         │
├─ 20s   │ ReadinessProbe 开始 (initialDelaySeconds: 20)
│         │ - 访问 /health 端点
│         │
├─ 20s+  │ Pod 标记为 Ready ✅
│         │ - 开始接收流量
│         │ - Service 将流量路由到新 Pod
│         │
├─ 21s   │ 开始终止旧 Pod (因为 maxUnavailable: 0)
│         │ - 旧 Pod 停止接收新流量
│         │ - 等待现有连接完成（优雅关闭）
│         │
└─ 完成   │ 旧 Pod 完全销毁
```

**关键保障：**
- ✅ 新 Pod 启动 20 秒后才接收流量（满足您的 10 秒需求）
- ✅ 旧 Pod 只有在新 Pod Ready 后才销毁（零停机）
- ✅ 始终有足够的 Pod 处理请求（maxUnavailable: 0）

## 监控升级过程

### 1. 实时查看 Pod 状态
```bash
watch -n 1 'kubectl get pods -n dify -l component=api -o wide'
```

### 2. 查看滚动更新事件
```bash
kubectl describe deployment dify-api -n dify
```

### 3. 查看 Pod 日志
```bash
# 查看新 Pod 日志
kubectl logs -n dify -l component=api --tail=100 -f

# 查看特定 Pod
kubectl logs -n dify <pod-name> -f
```

### 4. 验证文件挂载
```bash
# 进入 Pod 检查文件
kubectl exec -n dify <pod-name> -- cat /app/api/core/llm_generator/prompts.py | head -20
```

## 回滚操作

### 如果升级出现问题，立即回滚
```bash
# 回滚到上一个版本
helm rollback dify -n dify

# 回滚到特定版本
helm rollback dify <revision> -n dify
```

### 查看历史版本
```bash
helm history dify -n dify
```

## 更新 ConfigMap 后重新部署

如果修改了 `custom-configs/prompts.py`：

```bash
# 1. 更新 ConfigMap
kubectl create configmap dify-prompts \
  --from-file=prompts.py=./custom-configs/prompts.py \
  -n dify \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. 强制重启 Pod（触发重新挂载）
kubectl rollout restart deployment/dify-api -n dify
kubectl rollout restart deployment/dify-worker -n dify

# 3. 查看重启状态
kubectl rollout status deployment/dify-api -n dify
```

## 验证自定义 Prompts 是否生效

```bash
# 1. 进入 API Pod
kubectl exec -n dify -it <api-pod-name> -- bash

# 2. 查看挂载的文件
cat /app/api/core/llm_generator/prompts.py

# 3. 验证内容是否为自定义版本
head -5 /app/api/core/llm_generator/prompts.py
```

## 注意事项

### ⚠️ ConfigMap 大小限制
- ConfigMap 最大 1MB
- 您的 prompts.py 约 18KB，没有问题 ✅

### ⚠️ Pod 不会自动重启
- 修改 ConfigMap 后，已运行的 Pod 不会自动重启
- 需要手动触发 rollout restart 或 helm upgrade

### ⚠️ 只读挂载
- 文件以 `readOnly: true` 挂载
- Pod 内无法修改文件（安全考虑）

### ⚠️ Worker Pod
- 当前配置只影响 API Pod
- 如果 Worker 也需要自定义 prompts，需要同样配置

## 常见问题

### Q: 升级会中断服务吗？
A: 不会。配置了 `maxUnavailable: 0`，确保零停机部署。

### Q: 升级需要多久？
A: 通常 30-60 秒：
- 新 Pod 启动：5-10s
- 等待 Ready：20s
- 旧 Pod 销毁：5-10s

### Q: 如何确认挂载成功？
A: 进入 Pod 查看文件内容：
```bash
kubectl exec -n dify <pod-name> -- head -5 /app/api/core/llm_generator/prompts.py
```

### Q: 可以挂载多个文件吗？
A: 可以！在 ConfigMap 中添加更多文件，并在 volumeMounts 中配置：
```yaml
volumes:
  - name: custom-prompts
    configMap:
      name: dify-prompts
volumeMounts:
  - name: custom-prompts
    mountPath: /app/api/core/llm_generator/prompts.py
    subPath: prompts.py
  - name: custom-prompts
    mountPath: /app/api/other/file.py
    subPath: other-file.py
```

