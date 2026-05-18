更新内容总结

本次升级跨越约 5 个月（2025年12月 ~ 2026年4月）
1.11.x 修复了 React 关键安全漏洞（CVE-2025-55182）、修复了 API Key 明文暴露问题（CVE-2025-67732）、增强了 MCP 工具支持（embeddedResource、直接展示）并新增了文档批量重建索引功能。
1.12.0 引入了 Summary Index（知识库摘要索引），通过为文档分块生成 AI 摘要来提升检索准确性。
1.13.0 是大功能更新，新增了 Human Input 节点（人工审核节点），允许工作流在关键决策点暂停等待人工审核、编辑或重新路由后再继续执行。https://docs.dify.ai/zh/use-dify/nodes/human-input
1.13.1 增加了 Hologres 向量数据库支持、工作流画布边右键菜单、可配置的聊天发送键行为（Enter/Shift+Enter）、SQL 注入防护加固、以及 Redis Stream 事件总线替代旧的 PubSub 配置。
1.13.2/1.13.3 是稳定性补丁，修复了流式广播通道并发问题、工作流节点粘贴元数据泄漏、知识库引用元数据丢失等 bug，并新增了 LLM/问题分类器/变量提取器节点的模型参数变量引用支持。

环境概览
项目
国内公共集群 
海外精品集群 
节点配置
16C/32G × 3 + 32C128G 
4C/8G × 3 = 12C/24G
当前版本
1.10.1-fix.1
1.10.1-fix.1
日请求量
200w+
1w+
blocking:streaming
10:1
10:1
数据库
阿里云 RDS (max_conn=3200)
AWS RDS (max_conn=400)
向量库
Milvus (起在k3s主节点，计划迁移出去和集群分离)
Milvus (Docker, 占 ~2C/4G)
对象存储
阿里云 OSS
AWS S3
Redis
外部 Redis
外部 Redis
仓库分支
master
hwjp
日志分区表
✅ pg_cron 按天分区
❌ 使用官方清理任务

关键：blocking:streaming = 10:1， ~91% 的工作流执行仍在 API Pod（blocking 模式不走 Celery），Worker 只承担 ~9% 的 streaming 流量 + 后台任务。
升级流程图（PlantUML）
暂时无法在飞书文档外展示此内容


---
1.13.3 核心架构变化
[图片]
[图片]

1.10.1: 用户请求 → API (执行 workflow + SSE 推流) → 返回
1.13.3: 
  blocking:  用户请求 → API (仍然直接执行 workflow) → 返回
  streaming: 用户请求 → API (转发) → Redis 队列 → Worker (执行) → Redis Pub/Sub → API (SSE) → 返回

直接影响（blocking:streaming = 10:1）：

组件
1.10.1 角色
1.13.3 角色
资源变化
API
执行所有 workflow + SSE
执行 blocking workflow (91%) + SSE 代理
基本不变
Worker
只做后台任务（知识库索引等）
执行 streaming workflow (9%) + 后台任务
小幅 ↑
Redis
缓存/队列/锁
缓存/队列/锁 + SSE 事件总线
连接数 ↑
⚠️ 重要：因为90% 是 blocking 调用，API Pod 仍然是性能关键路径，不像纯 streaming 场景那样需要大幅扩 Worker。

---

升级前：代码仓库准备（通用）

合并上游 chart

cd /path/to/dify-helm
git remote add upstream https://github.com/BorisPolonsky/dify-helm.git || true
git fetch upstream --tags

# 国内集群
git checkout master
git merge --no-ff upstream/dify-0.36.0
# 解决冲突：优先保留上游模板结构，再迁移本地 values 配置

# 海外集群
git checkout hwjp
git merge --no-ff upstream/dify-0.36.0

上游只支持到 1.12.1，额外需要做的

1. 修改 charts/dify/Chart.yaml 中 appVersion: "1.13.3"
2. 修改 values-dify.yaml 中镜像 tag：
  - image.api.tag: "1.13.3"
  - image.web.tag: "1.13.3"
  - image.sandbox.tag: "0.2.14"
  - image.pluginDaemon.tag: "0.5.3-local"
3. 添加 1.13.3 新增环境变量（见下方通用变量清单）
4. 修复无效变量（见下方清理清单）
  

---

通用部分：两个集群都需要做的变更

需要删除的无效变量

变量
原设置位置
原因
REDIS_POOL_SIZE
API
1.13.3 不存在，正确名称是 REDIS_MAX_CONNECTIONS
REDIS_POOL_MAX_CONNECTIONS
API
同上
CELERY_BROKER_POOL_LIMIT
API
1.13.3 不存在
SQLALCHEMY_ECHO_POOL
API
1.13.3 DatabaseConfig 中不存在
SQLALCHEMY_POOL_RESET_ON_RETURN
ALL
1.13.3 硬编码为 None，无法覆盖
MAX_TASK_PRE_CHILD
Worker
typo！正确名称是 MAX_TASKS_PER_CHILD
CELERY_MAX_WORKERS
Worker
CELERY_AUTO_SCALE=false 时无效
CELERY_MIN_WORKERS
Worker
同上
RETRY_TIMES
API
1.13.3 不存在
需要新增的环境变量（API + Worker + Beat）
变量
值
说明
UV_CACHE_DIR
/tmp/.uv-cache
uv 包管理器缓存
PUBSUB_REDIS_CHANNEL_TYPE
streams
SSE 事件传输（推荐 streams，at-least-once）
PUBSUB_STREAMS_RETENTION_SECONDS
600
stream key 过期时间
REDIS_MAX_CONNECTIONS
(按集群调整)
替代原无效的 Redis pool 配置
CELERY_TASK_ANNOTATIONS
null
Celery 任务注解
CELERY_PREFETCH_MULTIPLIER
1
控制任务预取
ENABLE_HUMAN_INPUT_TIMEOUT_TASK
true
HITL 人工输入超时
HUMAN_INPUT_TIMEOUT_TASK_INTERVAL
1
检查间隔（秒）
PLUGIN_DAEMON_TIMEOUT
600.0
插件调用超时
PLUGIN_MODEL_SCHEMA_CACHE_TTL
3600
模型 schema 缓存

需要新增的环境变量（仅 API + Worker）
变量
值
说明
ENABLE_WORKFLOW_RUN_CLEANUP_TASK
false (国内) / true (海外)
国内用分区表，海外用官方清理
WORKFLOW_LOG_CLEANUP_ENABLED
false (国内) / true (海外)
同上

Custom Prompts 迁移（通用）
1.13.3 支持环境变量覆盖，不再需要 ConfigMap 挂载：

- 删除 api.persistence.volumes / api.persistence.volumeMounts（原本就不生效）
- 删除 api.extraVolumes / api.extraVolumeMounts（如果有）
- 新增环境变量：
  
- name: SUGGESTED_QUESTIONS_PROMPT
  value: "请帮我预测用户最可能问的三个问题，每个问题控制在20个字符以内。\n确保你的输出语言与助手最新回复的语言保持一致。输出必须是JSON数组格式，遵循以下模式：\n[\"问题1\",\"问题2\",\"问题3\"]\n"

api.url.* 迁移（通用）

原 api.url.appWeb / api.url.files 是死配置（模板不读取），改为：

global:
  appWebDomain: "<外部访问地址>"
  filesDomain: "<外部访问地址>"

---

蓝绿升级执行步骤（通用流程）

Phase 1: 旧集群停机

export NS=dify
export RELEASE=dify

helm upgrade $RELEASE ./charts/dify -n $NS \
  -f values-dify.yaml \
  -f values-secrets.yaml \
  -f values-dify-prod.yaml \
  -f values-maintenance.yaml \
  --timeout 15m --wait

kubectl get pods -n $NS  # 确认全部 0/0

Phase 2: 创建数据克隆

- RDS：从生产实例克隆（阿里云/AWS 控制台操作）@Flynn 
- Redis：新建独立实例@Flynn 
- OSS/S3：共用（不克隆）
- Milvus：共用（不克隆）
  
Phase 3: Migration

export NS=dify
export RELEASE=dify

helm upgrade --install $GREEN_RELEASE ./charts/dify -n $GREEN_NS --create-namespace \
  -f values-dify.yaml \
  -f values-secrets-green.yaml \
  -f values-dify-prod-1.13.3.yaml \
  --set api.replicas=1 \
  --set api.autoscaling.enabled=false \
  --set worker.replicas=0 \
  --set beat.enabled=false \
  --set web.replicas=0 \
  --set sandbox.replicas=0 \
  --set pluginDaemon.replicas=0 \
  --timeout 20m --wait

验证：
SELECT version_num FROM alembic_version;
-- 国内集群额外验证：
SELECT maintain_workflow_partitions(7, 1);

Phase 4: 全量启动 + 冒烟测试（4:00 ~ 4:30）

4.1 全量启动新集群

export NS=dify
export RELEASE=dify

helm upgrade $GREEN_RELEASE ./charts/dify -n $GREEN_NS \
  -f values-dify.yaml \
  -f values-secrets-green.yaml \
  -f values-dify-prod-1.13.3.yaml \
  --timeout 30m --wait

确认所有 Pod Running：

kubectl get pods -n $GREEN_NS

4.2 插件兼容性验证

⚠️ 1.13.3 的 plugin-daemon 架构有变化，插件可能存在不兼容情况。这是升级后最容易出问题的地方。

4.2.1 插件分级

级别
插件
验证标准
失败影响
P0 核心
火山豆包 / Qwen（国内）、OpenAI / Gemini（海外）
正常调用并返回结果
阻断升级+回滚
P0 核心
Embedding 模型（知识库检索依赖）
正常调用并返回结果
阻断升级+回滚
P0 核心
代码执行（Sandbox）
代码节点正常执行
阻断升级+回滚
P0 核心
其他工具插件（HTTP等）
正常调用并返回结果
阻断升级+回滚
P1 重要
各类 search ，ocr等插件
正常调用并返回结果
尝试降级运行

4.2.2 插件启动检查

# 1. 确认 plugin-daemon Pod 启动完成（插件编译需要 5-8 分钟）
kubectl logs -n $GREEN_NS deploy/$GREEN_RELEASE-plugin-daemon --tail=100 | grep -i "error\|failed\|exception"

# 2. 确认插件列表加载正常（通过 Console 页面查看）
# 进入 Console → 工作区设置 → 模型供应商，确认 P0 模型显示正常

# 3. 检查 API 日志中是否有插件相关报错
kubectl logs -n $GREEN_NS deploy/$GREEN_RELEASE-api --tail=300 | grep -i "plugin\|daemon"

4.2.3 插件报错持续监控命令

升级后 30 分钟内持续观察：

# 实时监控 plugin-daemon 错误
kubectl logs -f -n $GREEN_NS deploy/$GREEN_RELEASE-plugin-daemon | grep -i "error\|exception\|traceback"

# 实时监控 API 中插件调用错误
kubectl logs -f -n $GREEN_NS deploy/$GREEN_RELEASE-api | grep -i "plugin.*error\|plugin.*fail\|daemon.*error"

常见插件兼容性问题：
- 插件 manifest 格式变化 → 表现为插件加载失败
- 插件 API 接口变化 → 表现为调用时 500 错误
- 插件依赖包版本冲突 → 表现为 plugin-daemon 启动报错
  
4.3 功能冒烟测试
4.3.1 基础功能

[] 打开应用列表（确认历史应用都在）
[] 打开几个核心工作流，编排里确认正常显示+运行（海外coin识别，国内背书匠，暖暖月记对话）

4.3.2 其他功能

[] 文件上传 / 下载
[] 知识库检索（上传文档 → 索引 → 召回验证）
[] 代码节点执行
[] 查看 workflow run 详情和 node execution 详情

4.3.3 分区表专项（仅国内集群）

-- 确认当天分区有数据
SELECT count(*) FROM workflow_runs
WHERE created_at >= date_trunc('day', (now() AT TIME ZONE 'UTC')::timestamp);

-- 确认 pg_cron 任务存在
SELECT * FROM cron.job WHERE jobname = 'dify-workflow-partition-maintenance';

4.3.4 Worker 队列验证

kubectl logs -n $GREEN_NS deploy/$GREEN_RELEASE-worker --tail=200 | grep "Starting Celery worker with queues"

必须包含：workflow_based_app_execution, dataset_summary, api_token


---

Phase 5: 压力测试 + 切流量（4:30 ~ 5:00）

5.1 压测工具选择

hey：（brew install hey），一行命令就能压测，输出清晰。

5.2 压测准备

5.2.1 创建测试工作流

在 Green 集群 Console 中创建 2 个测试工作流并发布为 API：

测试工作流 A（blocking）：
- 开始 → LLM 节点（选择 P0 模型，prompt: "用一句话回答：1+1等于几"） → 结束

测试工作流 B（streaming）：
- 开始 → LLM 节点（同上） → 结束

5.2.2 压测参数（按集群规模）

参数
国内集群
海外集群
blocking 并发数
50
10
streaming 并发数
5
2
持续时间
10 分钟
5 分钟
总请求数
不限（按时间）
不限（按时间）
目标 RPS
50
10

5.3 压测执行

5.3.1 安装 hey

# macOS
brew install hey

# Linux
wget https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x hey_linux_amd64
mv hey_linux_amd64 /usr/local/bin/hey

5.3.2 Blocking 模式压测

# 国内集群（50 并发，持续 10 分钟）
hey -n 10000 -c 50 -t 120 \
  -m POST \
  -H "Authorization: Bearer app-blocking-xxx" \
  -H "Content-Type: application/json" \
  -d '{"inputs":{"query":"用一句话回答1+1等于几"},"response_mode":"blocking","user":"loadtest"}' \
  http://<GREEN_ENDPOINT>/v1/workflows/run

# 海外集群（10 并发，持续 5 分钟）
hey -n 2000 -c 10 -t 120 \
  -m POST \
  -H "Authorization: Bearer app-blocking-xxx" \
  -H "Content-Type: application/json" \
  -d '{"inputs":{"query":"answer 1+1 in one word"},"response_mode":"blocking","user":"loadtest"}' \
  http://<GREEN_ENDPOINT>/v1/workflows/run

5.3.3 Streaming 模式压测

streaming 模式 hey 不太适合（SSE 长连接），用简单的并发 curl 脚本：

# streaming-test.sh
#!/bin/bash
ENDPOINT="http://<GREEN_ENDPOINT>"
API_KEY="app-streaming-xxx"
CONCURRENCY=${1:-5}  # 默认 5 并发
DURATION=${2:-300}   # 默认 5 分钟

echo "Starting streaming load test: ${CONCURRENCY} concurrent, ${DURATION}s duration"

end_time=$((SECONDS + DURATION))
success=0
fail=0

run_one() {
  while [ $SECONDS -lt $end_time ]; do
    response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 120 \
      -X POST "${ENDPOINT}/v1/workflows/run" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d '{"inputs":{"query":"hello"},"response_mode":"streaming","user":"loadtest-'$$'"}')
    if [ "$response" = "200" ]; then
      ((success++))
    else
      ((fail++))
      echo "FAIL: HTTP $response"
    fi
    sleep 1
  done
}

for i in $(seq 1 $CONCURRENCY); do
  run_one &
done

wait
echo "Done. Success: $success, Fail: $fail, Error Rate: $(echo "scale=2; $fail*100/($success+$fail)" | bc)%"

执行：

# 国内
chmod +x streaming-test.sh
./streaming-test.sh 5 600

# 海外
./streaming-test.sh 2 300

5.4 压测通过标准

指标
国内集群标准
海外集群标准
错误率
< 1%
< 1%
Blocking P95 延迟
< 10s（含 LLM 响应时间）
< 15s
Blocking P99 延迟
< 20s
< 30s
Streaming 首 token
< 5s
< 8s
API Pod CPU
< 80%
< 80%
Worker Pod CPU
< 70%
< 70%
DB 连接数
< 2000 (RDS 3200)
< 280 (RDS 400)
无 QueuePool limit reached
✓
✓
无 OOMKilled
✓
✓
无 CrashLoopBackOff
✓
✓
无 plugin 报错
✓
✓

5.5 压测期间监控命令

在压测运行的同时，另开终端执行k9s监控资源使用

5.6 压测结果记录

项目
结果
是否达标
Blocking 错误率


Blocking P95


Blocking P99


Streaming 错误率


Streaming 首 token


最大 DB 连接数


API Pod 最大 CPU


Worker Pod 最大 CPU


Plugin 报错数


QueuePool 报错



5.7 风险确认 

确认项
状态
P0 插件全部验证通过

冒烟测试全部通过

Blocking 压测达标

Streaming 压测达标

无 DB 连接池报错

无 Plugin 兼容性报错

可以切正式流量

确认人

确认时间


5.8 切流量

# 根据入口方式选择（留占位，建集群后填入）：
# 国内：修改 DNS/LB 指向 <GREEN_ENDPOINT_CN>
# 海外：修改 DNS/LB 指向 <GREEN_ENDPOINT_JP>

5.9 切流后观察（15 分钟）

切流后使用k9s重点观察 3 个日志源： api worker plugin-daemon

如果异常 → 立即执行回滚（切入口回 Blue）。

回滚

任何阶段失败：恢复旧集群（原数据库从未被修改），直接ng切流量回原集群，5 分钟内恢复。


---

国内集群参数

环境信息

项目
值
集群
16C/32G × 3 = 48C/96G
日请求量
百万级
RDS max_connections
3200
分区表
✅ pg_cron 按天分区，保留 7 天
当前 API 副本
9 (min) ~ 18 (max)
当前 Worker 副本
3 (min) ~ 8 (max)

负载预估
日请求百万，按活跃 10 小时算：
  平均 RPS ≈ 28
  峰值 RPS ≈ 100-150

blocking:streaming = 10:1
  blocking ≈ 91% → API 执行 → 峰值 ~136 RPS 在 API
  streaming ≈ 9% → Worker 执行 → 峰值 ~14 RPS 在 Worker

每个 workflow 执行 3-5 秒：
  API 稳态并发 ≈ 136 × 4 = 544（需要足够的 Gunicorn 连接 + DB 连接）
  Worker 稳态并发 ≈ 14 × 4 = 56（需要足够的 Celery 协程）

国内集群 1.13.3 关键参数

API

参数
旧值
新值
理由
replicas
9
9
91% 负载仍在 API，保持不变
SERVER_WORKER_AMOUNT
2
2
保持
SERVER_WORKER_CONNECTIONS
50
50
保持（9×2×50=900 并发容量）
SQLALCHEMY_POOL_SIZE
60
30
API 不再持有 LLM 长连接（streaming 走 Worker）
SQLALCHEMY_MAX_OVERFLOW
30
15
同上
SQLALCHEMY_POOL_USE_LIFO
false
true
短连接场景 LIFO 更优
GRAPH_ENGINE_MAX_WORKERS
5
10
blocking workflow 仍在 API，需要并行能力
REDIS_MAX_CONNECTIONS
(无效变量)
100
替代原 REDIS_POOL_SIZE/MAX_CONNECTIONS
PUBSUB_REDIS_CHANNEL_TYPE
(无)
streams
新增：SSE 事件通道
WORKFLOW_LOG_CLEANUP_ENABLED
false
false
保持：用分区表管理
ENABLE_WORKFLOW_RUN_CLEANUP_TASK
(无)
false
新增：保护分区表

Worker

参数
旧值
新值
理由
replicas (min)
3
5
承接 streaming workflow + 后台任务
replicas (max)
8
10
峰值 56 并发，5×16=80 覆盖
resources requests
500m/1Gi
1500m/3Gi
执行 streaming workflow + LLM 调用
resources limits
2000m/4Gi
3000m/6Gi
防止大工作流 OOM
CELERY_WORKER_AMOUNT
(auto_scale)
16
替代 MAX/MIN_WORKERS，gevent 协程数
CELERY_AUTO_SCALE
true
false
使用固定协程数更稳定
MAX_TASKS_PER_CHILD
100
200
修正拼写 + 减少重启频率
SQLALCHEMY_POOL_SIZE
40
50
streaming workflow 有 LLM I/O 持连接
SQLALCHEMY_MAX_OVERFLOW
20
25
峰值冗余
SQLALCHEMY_POOL_TIMEOUT
30
30
快速失败
GRAPH_ENGINE_MAX_WORKERS
5
20
工作流并行分支
REDIS_MAX_CONNECTIONS
(无)
50
新增
PUBSUB_REDIS_CHANNEL_TYPE
(无)
streams
新增：必须与 API 一致

连接数预算（国内）

常态（min replicas）：
  API:          9 Pod × 2 workers × (30+15) = 810
  Worker:       5 Pod × 1 进程 × (50+25) = 375
  Beat:         1 Pod × (10+5) = 15
  PluginDaemon: 3 Pod × (20+10) = 90
  总计:         1290 / 3200 (40%) ✓

HPA 峰值（max replicas）：
  API:          18 × 2 × 45 = 1620
  Worker:       10 × 1 × 75 = 750
  Beat:         15
  PluginDaemon: 90
  总计:         2475 / 3200 (77%) ✓


---

海外精品集群参数

环境信息

项目
值
集群
4C/8G × 3 = 12C/24G（Milvus 占 ~2C/4G）
Dify 可用
~8.5C / 18.5G
日请求量
数万级
RDS max_connections
400
分区表
❌ 使用官方清理任务
当前 API 副本
2 (min) ~ 4 (max)
当前 Worker 副本
1

负载分析

日请求数万，按活跃 10 小时算：
  平均 RPS ≈ 1-3
  峰值 RPS ≈ 10-15

blocking:streaming = 10:1
  blocking ≈ 91% → API → 峰值 ~14 RPS
  streaming ≈ 9% → Worker → 峰值 ~1.5 RPS

每个 workflow 执行 3-5 秒：
  API 稳态并发 ≈ 14 × 4 = 56（2 Pod × 2 workers × 50 conn = 200，充足）
  Worker 稳态并发 ≈ 1.5 × 4 = 6（3 个 greenlet 足够）

海外集群 1.13.3 关键参数

API

参数
旧值
新值
理由
replicas
2
2
负载低，保持不变
SERVER_WORKER_AMOUNT
2
2
保持
SERVER_WORKER_CONNECTIONS
30
50
提高：SSE 代理需要更多长连接
SQLALCHEMY_POOL_SIZE
20
20
保持：blocking 仍在 API
SQLALCHEMY_MAX_OVERFLOW
10
10
保持
SQLALCHEMY_POOL_USE_LIFO
true
true
保持
GRAPH_ENGINE_MAX_WORKERS
5
5
负载低，保持
REDIS_MAX_CONNECTIONS
(无效变量)
40
替代原 REDIS_POOL_SIZE
PUBSUB_REDIS_CHANNEL_TYPE
(无)
streams
新增
WORKFLOW_LOG_CLEANUP_ENABLED
true
true
海外用官方清理
ENABLE_WORKFLOW_RUN_CLEANUP_TASK
(无)
true
海外用官方清理

Worker

参数
旧值
新值
理由
replicas
1
1
负载低，1 个够用
resources requests
1000m/3Gi
1000m/3Gi
保持
resources limits
2000m/5Gi
2500m/5Gi
适度提高 CPU
CELERY_WORKER_AMOUNT
(1/auto)
3
streaming 峰值 1-3 并发
CELERY_AUTO_SCALE
false
false
固定协程数
MAX_TASKS_PER_CHILD
100
100
修正拼写即可
SQLALCHEMY_POOL_SIZE
10
15
streaming + 后台任务
SQLALCHEMY_MAX_OVERFLOW
5
5
保持
SQLALCHEMY_POOL_TIMEOUT
180
30
快速失败
GRAPH_ENGINE_MAX_WORKERS
5
6
适度提高
REDIS_MAX_CONNECTIONS
(无)
30
新增
PUBSUB_REDIS_CHANNEL_TYPE
(无)
streams
新增

连接数预算（海外）

常态：
  API:          2 Pod × 2 workers × (20+10) = 120
  Worker:       1 Pod × 1 进程 × (15+5) = 20
  Beat:         1 Pod × (3+2) = 5
  PluginDaemon: 2 Pod × (5+3) = 16
  总计:         161 / 400 (40%) ✓

HPA 峰值：
  API:          4 × 2 × 30 = 240
  Worker:       20
  Beat:         5
  PluginDaemon: 16
  总计:         281 / 400 (70%) ✓


---

附录 A：变量变更清单

✅ 两个集群都要新增

变量
API
Worker
Beat
值
UV_CACHE_DIR
✓
✓
✓
/tmp/.uv-cache
PUBSUB_REDIS_CHANNEL_TYPE
✓
✓

streams
PUBSUB_STREAMS_RETENTION_SECONDS
✓
✓

600
REDIS_MAX_CONNECTIONS
✓
✓

(按集群)
CELERY_TASK_ANNOTATIONS
✓
✓
✓
null
CELERY_PREFETCH_MULTIPLIER

✓

1
CELERY_WORKER_AMOUNT

✓

(按集群)
MAX_TASKS_PER_CHILD

✓

(按集群)
ENABLE_HUMAN_INPUT_TIMEOUT_TASK
✓
✓
✓
true
HUMAN_INPUT_TIMEOUT_TASK_INTERVAL
✓
✓
✓
1
PLUGIN_DAEMON_TIMEOUT
✓
✓

600.0
PLUGIN_MODEL_SCHEMA_CACHE_TTL
✓
✓

3600
SUGGESTED_QUESTIONS_PROMPT
✓


(中文提示词)
ENABLE_WORKFLOW_RUN_CLEANUP_TASK
✓
✓
✓
(按集群)

❌ 两个集群都要删除

变量
位置
REDIS_POOL_SIZE
API
REDIS_POOL_MAX_CONNECTIONS
API
CELERY_BROKER_POOL_LIMIT
API
SQLALCHEMY_ECHO_POOL
API
SQLALCHEMY_POOL_RESET_ON_RETURN
ALL
MAX_TASK_PRE_CHILD
Worker（typo）
CELERY_MAX_WORKERS
Worker
CELERY_MIN_WORKERS
Worker
RETRY_TIMES
API

🔄 两个集群都要修改

变量
位置
变化
理由
api.url.*
API
删除，改用 global.*
死配置修复
api.persistence.volumes
API
删除
改用环境变量
CELERY_AUTO_SCALE
Worker
删除或设 false
使用固定 CELERY_WORKER_AMOUNT

---

附录 B：检查清单（通用）

[] 上游 chart 已合并 (dify-0.36.0)
[] 镜像版本已更新 (1.13.3 / 0.2.14 / 0.5.3-local)
[] 无效变量已清理
[] 新变量已添加
[] 本地 migration 测试通过
[] 本地压测 P95 达标
[] k6 脚本准备就绪
[] Green 基础设施已准备（RDS 克隆方案确认、新 Redis 已创建）
[] 回滚流程已演练
[] DNS TTL 已降到 60 秒以下
[] 维护窗口内相关人员在线


---

附录 C：回滚保证

存储
是否克隆
回滚影响
RDS
✅ 克隆
旧集群数据库从未修改，直接恢复
Redis
✅ 新建
Blue Redis 未被污染
OSS/S3
❌ 共用
可能多出孤儿文件（无害）
vectorDB（milvus 和 qdrant）
❌ 共用
可能多出孤儿向量（无害）

回滚操作： 拉起旧集群 → 切流量入口回旧集群 → 完成（约 5 分钟）


---

附录 D：升级顺序

1. 先升级海外集群（量小、风险低、验证流程）
2. 海外稳定运行至少2-3天后，再升级国内集群（量大、有分区表、插件多、需要更多验证）
