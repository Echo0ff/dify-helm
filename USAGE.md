# Dify Helm 使用指南

本仓库是对 [BorisPolonsky/dify-helm](https://github.com/BorisPolonsky/dify-helm) 的自定义配置。

## 快速开始

### 1. 准备敏感信息配置

```bash
# 复制模板文件
cp values-secrets.yaml.example values-secrets.yaml

# 编辑文件，填入实际的连接信息和密钥
vim values-secrets.yaml
```

需要配置的关键信息：
- PostgreSQL 数据库连接
- Redis 连接
- 对象存储（OSS）配置
- Milvus 向量数据库连接
- 应用密钥（使用 `openssl rand -base64 42` 生成）

详细说明请参考 [SECRETS-MANAGEMENT.md](./SECRETS-MANAGEMENT.md)

### 2. 部署方式

#### 开发/测试环境

```bash
helm install dify ./charts/dify \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -n dify --create-namespace
```

#### 生产环境

```bash
helm install dify ./charts/dify \
  -f values-dify.yaml \
  -f values-dify-prod.yaml \
  -f values-secrets.yaml \
  -n dify --create-namespace
```

### 3. 升级部署

```bash
# 开发/测试环境
helm upgrade dify ./charts/dify \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -n dify

# 生产环境
helm upgrade dify ./charts/dify \
  -f values-dify.yaml \
  -f values-dify-prod.yaml \
  -f values-secrets.yaml \
  -n dify
```

## 配置文件说明

### values-dify.yaml
主配置文件，包含：
- 镜像版本和仓库
- 基础资源配置（适用于开发/测试环境）
- 服务默认配置（单副本）
- 连接配置结构（使用占位符）
- 功能特性开关

**适用场景**: 开发、测试环境，或作为基础配置

### values-dify-prod.yaml
生产环境覆盖配置，包含：
- 生产级别的资源配置（更高的CPU/内存）
- HPA自动伸缩配置
- 多副本高可用配置
- 优化的健康检查参数
- Pod拓扑分散策略

**适用场景**: 生产环境，高并发场景

### values-secrets.yaml（不提交到Git）
敏感信息配置，包含：
- 数据库密码
- Redis密码
- OSS访问密钥
- API密钥和令牌
- 应用密钥

**重要**: 此文件已在 `.gitignore` 中，不会被提交到版本控制

### values-secrets.yaml.example
敏感信息配置模板，可以安全地提交到Git

## 配置集中管理

所有外部服务的连接信息都在 `connectionConfig` 部分集中管理：

```yaml
connectionConfig:
  postgres:    # PostgreSQL配置
  redis:       # Redis配置  
  oss:         # 阿里云OSS配置
  milvus:      # Milvus向量数据库配置
  app:         # 应用密钥配置
  mail:        # 邮件配置
```

这些配置会自动应用到相应的 `externalPostgres`、`externalRedis` 等部分。

## 常用命令

### 查看部署状态

```bash
# 查看所有Pod
kubectl get pods -n dify

# 查看服务
kubectl get svc -n dify

# 查看HPA状态（生产环境）
kubectl get hpa -n dify

# 查看资源使用情况
kubectl top pods -n dify
```

### 查看日志

```bash
# API日志
kubectl logs -n dify -l component=api --tail=100 -f

# Worker日志
kubectl logs -n dify -l component=worker --tail=100 -f

# Web日志
kubectl logs -n dify -l component=web --tail=100 -f
```

### 故障排查

```bash
# 查看Pod详细信息
kubectl describe pod <pod-name> -n dify

# 进入容器调试
kubectl exec -it <pod-name> -n dify -- sh

# 查看事件
kubectl get events -n dify --sort-by='.lastTimestamp'
```

## 同步上游更新

```bash
# 获取上游更新
git fetch upstream

# 合并上游主分支
git merge upstream/master

# 如有冲突，解决后提交
git add .
git commit -m "Merge upstream updates"

# 推送到自己的仓库
git push origin master
```

## 注意事项

### 安全提示

⚠️ **重要**: 
- 永远不要将 `values-secrets.yaml` 提交到Git
- 推送代码前务必检查 `git status`
- 如果不小心提交了敏感信息，立即轮换所有密钥

### 生产环境最佳实践

1. **使用多副本**: 确保高可用性
2. **配置HPA**: 自动应对流量波动
3. **资源限制**: 设置合理的 requests 和 limits
4. **健康检查**: 配置适当的 liveness 和 readiness 探针
5. **持久化**: 确保重要数据使用持久化存储
6. **监控**: 部署 Prometheus 和 Grafana 监控资源使用

### 资源规划建议

| 环境 | API副本 | Worker副本 | 推荐集群配置 |
|------|---------|-----------|--------------|
| 开发 | 1 | 1 | 4C/8G单节点 |
| 测试 | 2 | 1 | 8C/16G单节点 |
| 生产 | 3-8 | 3-6 | 多节点，总计16C+/32G+ |

## 相关文档

- [敏感信息管理指南](./SECRETS-MANAGEMENT.md) - 详细的安全配置说明
- [官方README](./README.md) - 上游项目文档
- [Dify官方文档](https://docs.dify.ai/) - Dify使用文档

## 获取帮助

如遇到问题，可以：
1. 查看 [SECRETS-MANAGEMENT.md](./SECRETS-MANAGEMENT.md) 中的故障排查部分
2. 检查 Pod 日志和事件
3. 参考上游项目 [Issues](https://github.com/BorisPolonsky/dify-helm/issues)

## License

本配置基于 [BorisPolonsky/dify-helm](https://github.com/BorisPolonsky/dify-helm) 项目。
