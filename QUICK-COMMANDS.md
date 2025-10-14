# Dify 生产环境快速命令速查表 🚀

## 📊 监控命令

### 实时监控（三终端方案）

```bash
# 终端 1: HPA 自动伸缩监控
watch -n 2 'kubectl get hpa -n dify'

# 终端 2: Pod 资源监控（按 CPU 排序）
watch -n 2 'kubectl top pods -n dify --sort-by=cpu | head -20'

# 终端 3: 节点资源监控
watch -n 2 'kubectl top nodes'
```

### 一键查看所有状态

```bash
#!/bin/bash
# 保存为 check-dify.sh
echo "=== Dify 服务状态 ==="
kubectl get pods -n dify -o wide | grep -E "NAME|Running"
echo ""
echo "=== HPA 状态 ==="
kubectl get hpa -n dify
echo ""
echo "=== 资源使用 TOP 10 ==="
kubectl top pods -n dify --sort-by=cpu | head -11
echo ""
echo "=== 节点资源 ==="
kubectl top nodes
```

---

## 🚀 部署与更新

### 应用生产配置

```bash
# 完整部署（基础 + 生产优化）
cd /home/zard/dify-helm
helm upgrade dify charts/dify \
  -f values-dify.yaml \
  -f values-dify-prod.yaml \
  -n dify \
  --wait --timeout 10m

# 仅更新生产配置（不改基础配置）
helm upgrade dify charts/dify \
  -f values-dify.yaml \
  -f values-dify-prod.yaml \
  -n dify \
  --reuse-values
```

### 快速调整副本数

```bash
# 临时增加 API 副本（不修改配置文件）
kubectl scale deployment dify-api --replicas=5 -n dify

# 临时增加 Worker 副本
kubectl scale deployment dify-worker --replicas=4 -n dify

# 查看当前副本数
kubectl get deployment -n dify
```

### 滚动重启服务

```bash
# 重启 API（不停机）
kubectl rollout restart deployment dify-api -n dify

# 重启 Worker
kubectl rollout restart deployment dify-worker -n dify

# 重启所有服务
kubectl rollout restart deployment -n dify

# 查看滚动更新状态
kubectl rollout status deployment dify-api -n dify
```

---

## 📈 压测相关

### 压测前检查

```bash
# 1. 确认所有 Pod 就绪
kubectl get pods -n dify | grep -v "Running\|Completed"
# 应该没有输出（所有都是 Running）

# 2. 确认 HPA 已启用
kubectl get hpa -n dify
# 应该看到 dify-api, dify-worker 等

# 3. 查看当前资源基线
kubectl top pods -n dify
kubectl top nodes

# 4. 清理旧数据（可选）
# kubectl exec -it <api-pod> -n dify -- python manage.py cleanup
```

### 压测中监控

```bash
# 实时查看 API 日志（压测时查看错误）
kubectl logs -f -n dify -l component=api --tail=50 | grep -i "error\|exception"

# 实时查看扩容事件
kubectl get events -n dify --watch | grep -i "scale"

# 实时查看 Pod 变化
kubectl get pods -n dify --watch
```

### 压测后分析

```bash
# 查看 HPA 历史事件
kubectl describe hpa dify-api -n dify | grep -A 20 "Events"

# 查看 Pod 重启次数（排查稳定性）
kubectl get pods -n dify -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount

# 查看资源限制是否触顶
kubectl top pods -n dify --sort-by=cpu | awk '{if(NR>1)print $1,$2,$3}' | while read name cpu mem; do echo "$name: CPU=$cpu MEM=$mem"; done
```

---

## 🔧 故障排查

### Pod 异常排查

```bash
# 查看异常 Pod
kubectl get pods -n dify | grep -v "Running\|Completed"

# 查看 Pod 详细信息
kubectl describe pod <pod-name> -n dify

# 查看 Pod 日志（最近 100 行）
kubectl logs <pod-name> -n dify --tail=100

# 查看 Pod 日志（包含已重启的）
kubectl logs <pod-name> -n dify --previous

# 进入 Pod 内部调试
kubectl exec -it <pod-name> -n dify -- /bin/bash
```

### HPA 不工作排查

```bash
# 检查 metrics-server 是否运行
kubectl get pods -n kube-system | grep metrics-server

# 如果不存在，安装
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 等待几分钟后检查 metrics 是否可用
kubectl top nodes
kubectl top pods -n dify

# 查看 HPA 详细状态
kubectl describe hpa dify-api -n dify

# 手动触发扩容测试（修改阈值）
kubectl patch hpa dify-api -n dify -p '{"spec":{"targetCPUUtilizationPercentage":10}}'
# 等待观察是否扩容，测试完恢复：
kubectl patch hpa dify-api -n dify -p '{"spec":{"targetCPUUtilizationPercentage":60}}'
```

### 服务连接问题

```bash
# 测试 PostgreSQL 连接
kubectl run -it --rm debug --image=postgres:15 --restart=Never -n dify -- \
  psql -h <postgres-host> -U postgres -d dify

# 测试 Redis 连接
kubectl run -it --rm debug --image=redis:7 --restart=Never -n dify -- \
  redis-cli -h <redis-host> -a <password> ping

# 测试 Milvus 连接
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -n dify -- \
  curl -v http://192.168.44.231:19530/healthz

# 测试 OSS 连接（在 API Pod 内）
kubectl exec -it <api-pod> -n dify -- \
  python -c "import oss2; print('OSS connection OK')"
```

### 资源不足排查

```bash
# 查看节点资源剩余
kubectl describe nodes | grep -A 5 "Allocated resources"

# 查看节点 Pod 分布
kubectl get pods -n dify -o wide | awk '{print $7}' | sort | uniq -c

# 查看 Pod 调度失败事件
kubectl get events -n dify | grep -i "Failed\|FailedScheduling"

# 查看资源配额（如果设置了）
kubectl describe quota -n dify
```

---

## 🎯 性能调优

### 调整 API 资源限制

```bash
# 方法 1: 通过 kubectl patch（临时）
kubectl patch deployment dify-api -n dify -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "api",
          "resources": {
            "requests": {"cpu": "6000m", "memory": "6Gi"},
            "limits": {"cpu": "12000m", "memory": "12Gi"}
          }
        }]
      }
    }
  }
}'

# 方法 2: 编辑 Deployment（永久）
kubectl edit deployment dify-api -n dify
# 在编辑器中修改 resources 部分

# 方法 3: 修改配置文件重新部署（推荐）
# 编辑 values-dify-prod.yaml，然后：
helm upgrade dify charts/dify -f values-dify.yaml -f values-dify-prod.yaml -n dify
```

### 调整 HPA 阈值

```bash
# 更激进的扩容（降低阈值到 50%）
kubectl patch hpa dify-api -n dify -p '{
  "spec": {
    "targetCPUUtilizationPercentage": 50,
    "targetMemoryUtilizationPercentage": 60
  }
}'

# 增加最大副本数
kubectl patch hpa dify-api -n dify -p '{"spec":{"maxReplicas":10}}'

# 查看修改结果
kubectl get hpa dify-api -n dify -o yaml
```

### 调整 Gunicorn Worker 数量

```bash
# 方法 1: 通过环境变量（需要重启 Pod）
kubectl set env deployment/dify-api -n dify \
  GUNICORN_WORKERS=6 \
  GUNICORN_THREADS=2 \
  GUNICORN_TIMEOUT=360

# 方法 2: 修改配置文件
# 在 values-dify-prod.yaml 中修改 api.extraEnv，然后重新部署

# 验证配置
kubectl exec -it <api-pod> -n dify -- env | grep GUNICORN
```

---

## 📊 数据导出与备份

### 导出 HPA 监控数据

```bash
# 导出 HPA 状态（用于分析）
kubectl get hpa -n dify -o yaml > hpa-status-$(date +%Y%m%d-%H%M%S).yaml

# 导出 Pod 资源使用（CSV 格式）
kubectl top pods -n dify --no-headers | \
  awk '{print $1","$2","$3}' > pod-resources-$(date +%Y%m%d-%H%M%S).csv
```

### 导出配置

```bash
# 导出当前 Helm values
helm get values dify -n dify > current-values-$(date +%Y%m%d-%H%M%S).yaml

# 导出完整 Deployment 配置
kubectl get deployment -n dify -o yaml > deployments-backup-$(date +%Y%m%d-%H%M%S).yaml

# 导出 ConfigMap 和 Secret
kubectl get configmap -n dify -o yaml > configmaps-backup-$(date +%Y%m%d-%H%M%S).yaml
# kubectl get secret -n dify -o yaml > secrets-backup-$(date +%Y%m%d-%H%M%S).yaml
```

---

## 🔄 回滚与恢复

### Helm 回滚

```bash
# 查看部署历史
helm history dify -n dify

# 回滚到上一个版本
helm rollback dify -n dify

# 回滚到指定版本（例如版本 19）
helm rollback dify 19 -n dify

# 查看指定版本的配置
helm get values dify -n dify --revision 19
```

### Deployment 回滚

```bash
# 查看 Deployment 滚动历史
kubectl rollout history deployment dify-api -n dify

# 回滚到上一个版本
kubectl rollout undo deployment dify-api -n dify

# 回滚到指定版本
kubectl rollout undo deployment dify-api -n dify --to-revision=3

# 暂停滚动更新（用于调试）
kubectl rollout pause deployment dify-api -n dify
# 恢复滚动更新
kubectl rollout resume deployment dify-api -n dify
```

### 紧急降级（回到单副本）

```bash
#!/bin/bash
# 紧急降级脚本 - emergency-downscale.sh

echo "紧急降级到单副本模式..."

# 禁用 HPA（避免自动扩容）
kubectl patch hpa dify-api -n dify -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'
kubectl patch hpa dify-worker -n dify -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'
kubectl patch hpa dify-web -n dify -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'
kubectl patch hpa dify-sandbox -n dify -p '{"spec":{"minReplicas":1,"maxReplicas":1}}'

# 缩减副本数
kubectl scale deployment dify-api --replicas=1 -n dify
kubectl scale deployment dify-worker --replicas=1 -n dify
kubectl scale deployment dify-web --replicas=1 -n dify
kubectl scale deployment dify-sandbox --replicas=1 -n dify
kubectl scale deployment dify-proxy --replicas=1 -n dify
kubectl scale deployment dify-ssrf-proxy --replicas=1 -n dify
kubectl scale deployment dify-plugin-daemon --replicas=1 -n dify

echo "降级完成，等待 Pod 稳定..."
sleep 10
kubectl get pods -n dify
```

---

## 📞 快速联系

**配置文件位置：**
- `/home/zard/dify-helm/values-dify.yaml` - 基础配置
- `/home/zard/dify-helm/values-dify-prod.yaml` - 生产优化
- `/home/zard/dify-helm/PRODUCTION-DEPLOYMENT.md` - 详细文档
- `/home/zard/dify-helm/QUICK-COMMANDS.md` - 本速查表

**快速诊断脚本：**
```bash
# 一键健康检查
cd /home/zard/dify-helm
cat > health-check.sh << 'EOF'
#!/bin/bash
echo "🔍 Dify 健康检查报告 - $(date)"
echo "========================================"
echo ""
echo "📊 Pod 状态："
kubectl get pods -n dify | grep -c "Running" | xargs echo "  运行中: "
kubectl get pods -n dify | grep -c "Pending\|Error\|CrashLoop" | xargs echo "  异常: "
echo ""
echo "📈 HPA 状态："
kubectl get hpa -n dify --no-headers | wc -l | xargs echo "  总数: "
echo ""
echo "💾 资源使用 TOP 5："
kubectl top pods -n dify --sort-by=cpu | head -6
echo ""
echo "🖥️  节点状态："
kubectl top nodes
echo ""
echo "✅ 检查完成"
EOF
chmod +x health-check.sh
./health-check.sh
```

---

**最后更新**: 2025-10-11  
**适用版本**: Dify 1.7.2, Kubernetes 1.23+

💡 提示：建议将本文件加入书签，压测时随时查阅！

