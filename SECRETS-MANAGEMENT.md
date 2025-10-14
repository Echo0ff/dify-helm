# 敏感信息管理指南

## 概述

为了安全地管理Dify Helm部署中的敏感信息（如密码、API密钥等），本项目采用了分离式配置管理策略：

- **values-dify.yaml**: 主配置文件，包含非敏感的配置项，可以安全地提交到Git
- **values-secrets.yaml**: 敏感信息配置文件，包含所有密码和密钥，**不应提交到Git**
- **values-secrets.yaml.example**: 敏感信息配置模板，供参考使用

## 快速开始

### 1. 创建敏感信息配置文件

```bash
# 复制模板文件
cp values-secrets.yaml.example values-secrets.yaml

# 编辑文件，填入实际的敏感信息
vim values-secrets.yaml
```

### 2. 生成安全密钥

对于需要随机密钥的配置项（如app.secretKey、pluginDaemon.serverKey等），可以使用以下命令生成：

```bash
# 生成42字节的随机Base64密钥
openssl rand -base64 42
```

### 3. 使用配置文件部署

在使用Helm部署时，同时指定两个配置文件：

```bash
# 安装
helm install dify ./charts/dify \\
  -f values-dify.yaml \\
  -f values-secrets.yaml \\
  -n dify

# 升级
helm upgrade dify ./charts/dify \\
  -f values-dify.yaml \\
  -f values-secrets.yaml \\
  -n dify
```

## 配置集中管理

所有外部服务的连接信息都在 `values-dify.yaml` 的 `connectionConfig` 部分集中管理：

```yaml
connectionConfig:
  postgres:    # PostgreSQL配置
  redis:       # Redis配置
  oss:         # 阿里云OSS配置
  milvus:      # Milvus向量数据库配置
  app:         # 应用密钥配置
  mail:        # 邮件配置
```

这些配置会被自动引用到对应的 `externalPostgres`、`externalRedis` 等部分，您只需要在 `values-secrets.yaml` 中覆盖敏感信息即可。

## 敏感信息清单

### 必须配置的敏感信息

1. **PostgreSQL数据库**
   - `postgres.host`: 数据库地址
   - `postgres.password`: 数据库密码

2. **Redis缓存**
   - `redis.host`: Redis地址
   - `redis.password`: Redis密码

3. **阿里云OSS**
   - `oss.endpoint`: OSS endpoint
   - `oss.accessKey`: OSS Access Key
   - `oss.secretKey`: OSS Secret Key
   - `oss.bucketName.api`: Bucket名称

4. **Milvus向量数据库**
   - `milvus.uri`: Milvus地址
   - `milvus.password`: Milvus密码

5. **应用密钥**
   - `app.secretKey`: 应用密钥（用于签名session cookie）
   - `app.consoleSecretKey`: 控制台密钥

6. **Sandbox API**
   - `sandbox.apiKey`: Sandbox API密钥

7. **Plugin Daemon**
   - `pluginDaemon.serverKey`: 服务器密钥
   - `pluginDaemon.difyApiKey`: Dify API密钥

### 可选配置的敏感信息

8. **邮件服务**（如果使用）
   - Resend: `mail.resend.apiKey`
   - SMTP: `mail.smtp.username` 和 `mail.smtp.password`

9. **其他向量数据库**（如果使用）
   - Weaviate: `vectorDB.weaviate.apiKey`
   - Qdrant: `vectorDB.qdrant.apiKey`
   - Pgvector: `vectorDB.pgvector.password`

10. **内置服务密码**（如果使用内置PostgreSQL/Redis）
    - `builtinPostgres.postgresPassword`
    - `builtinRedis.password`

## 安全最佳实践

### 1. 文件权限

确保敏感信息文件的权限设置正确：

```bash
chmod 600 values-secrets.yaml
```

### 2. Git配置

确认 `.gitignore` 已包含敏感文件：

```bash
cat .gitignore | grep values-secrets
```

应该看到：
```
values-secrets.yaml
*.secret.yaml
```

### 3. 备份策略

- ✅ **应该**: 将 `values-secrets.yaml` 备份到安全的密钥管理系统（如1Password、HashiCorp Vault等）
- ❌ **不应该**: 将敏感信息提交到Git仓库
- ❌ **不应该**: 将敏感信息存储在明文文件中并共享

### 4. 环境分离

为不同环境维护不同的敏感信息文件：

```bash
# 开发环境
values-secrets-dev.yaml

# 测试环境
values-secrets-test.yaml

# 生产环境
values-secrets-prod.yaml
```

使用时指定对应的文件：

```bash
helm upgrade dify ./charts/dify \\
  -f values-dify.yaml \\
  -f values-secrets-prod.yaml \\
  -n dify
```

## 使用Kubernetes Secrets（推荐用于生产环境）

对于生产环境，建议使用Kubernetes原生的Secret管理或External Secrets Operator：

### 方法1: 使用Kubernetes Secrets

```bash
# 创建Secret
kubectl create secret generic dify-secrets \\
  --from-literal=postgres-password='your-password' \\
  --from-literal=redis-password='your-password' \\
  --from-literal=oss-access-key='your-key' \\
  --from-literal=oss-secret-key='your-secret' \\
  -n dify

# 在values文件中引用
externalPostgres:
  existingSecret: "dify-secrets"
```

### 方法2: 使用External Secrets Operator

如果您的团队使用AWS Secrets Manager、HashiCorp Vault等，可以启用External Secrets：

```yaml
externalSecret:
  enabled: true
  secretStore:
    name: "your-secret-store"
    kind: "SecretStore"
```

## 故障排查

### 问题1: Helm部署时提示找不到values-secrets.yaml

**原因**: 文件不存在或路径错误

**解决方案**:
```bash
# 检查文件是否存在
ls -la values-secrets.yaml

# 如果不存在，从模板创建
cp values-secrets.yaml.example values-secrets.yaml
```

### 问题2: 敏感信息仍然显示占位符

**原因**: values-secrets.yaml中没有正确覆盖对应的配置

**解决方案**:
确保 `values-secrets.yaml` 中的配置结构与 `connectionConfig` 完全对应：

```yaml
connectionConfig:
  postgres:
    password: "actual-password-here"  # 确保缩进正确
```

### 问题3: Pod无法连接到外部服务

**原因**: 主机地址或端口配置错误

**解决方案**:
1. 检查 `values-secrets.yaml` 中的主机地址是否正确
2. 确认Kubernetes Pod能够访问外部服务（网络策略、防火墙等）
3. 使用 `kubectl exec` 进入Pod测试连接：

```bash
kubectl exec -it <pod-name> -n dify -- sh
# 测试PostgreSQL连接
nc -zv your-postgres-host 5432
# 测试Redis连接
nc -zv your-redis-host 6379
```

## 相关文档

- [快速命令参考](./QUICK-COMMANDS.md)
- [生产环境部署指南](./PRODUCTION-DEPLOYMENT.md)
- [配置模板文件](./config-template.yaml)

## 注意事项

⚠️ **重要提示**:
1. 永远不要将包含真实敏感信息的文件提交到版本控制系统
2. 在推送代码前，务必检查 `git status` 确认没有包含敏感文件
3. 如果不小心提交了敏感信息，应立即：
   - 撤销提交
   - 轮换所有暴露的密钥和密码
   - 清理Git历史记录（使用 `git filter-branch` 或 `BFG Repo-Cleaner`）

## 联系方式

如有疑问或需要帮助，请联系运维团队。
