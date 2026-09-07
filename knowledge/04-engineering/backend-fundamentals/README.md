---
title: 后端服务基础
category: engineering
parent: AI Agent 部署工程知识体系大纲
updated: 2026-09-03
---

# 后端服务基础

对应《AI Agent 部署工程知识体系大纲》第 3 章。十个知识点各自独立成文，按大纲中的排列顺序编号。

| 编号 | 文档 | 大纲标注深度 | 核心问题 |
|------|------|-------------|----------|
| 01 | [[01-framework-responsibilities\|服务端框架的职责]] | 理解 | WSGI/ASGI 协议层、路由算法差异、Pydantic v2 校验与序列化、异常栈、Agent 服务化实践 |
| 02 | [[02-request-lifecycle\|请求生命周期]] | 应用 | 两种连接队列、HTTP 版本与复用、网关错误码判定、超时收敛体系、慢请求判定树 |
| 03 | [[03-middleware\|中间件]] | 理解 | 洋葱模型、顺序为何敏感、四类陷阱 |
| 04 | [[04-dependency-injection\|依赖注入]] | 认知 | 三种注入方式、作用域陷阱、Agent 服务的注入清单 |
| 05 | [[05-sync-vs-async\|同步与异步]] | 理解 | 两种"异步"语义、让出点、收益边界 |
| 06 | [[06-concurrency-models\|并发模型]] | 认知 | 进程线程协程对比、GIL 的真实影响、worker 数 |
| 07 | [[07-connection-pool\|连接池]] | 应用 | 三条容量公式、PgBouncer 三模式、连接耗尽雪崩 |
| 08 | [[08-stateless-service\|无状态服务]] | 理解 | 状态外置四去处、粘性会话为何是妥协、Agent 的划界 |
| 09 | [[09-configuration-management\|配置管理]] | 应用 | 十二要素 Config、四层分层、密钥管理 |
| 10 | [[10-graceful-shutdown\|优雅关闭]] | 应用 | SIGTERM 语义、K8s 时序、长任务的矛盾 |

## 贯穿这一章的三条主线

**主线一：横切关注点必须收口。** 中间件收口鉴权与限流，依赖注入收口资源装配，框架收口序列化与错误处理。散落在业务代码里的横切逻辑，是系统行为不一致的根源。

**主线二：等待是 Agent 服务的常态，因此所有阻塞都是事故。** 同步与异步、并发模型、连接池，本质上都在回答同一个问题——等待期间资源是否被无效占用。

**主线三：进程会死，状态不能跟着死。** 无状态服务、配置外置、优雅关闭，共同保证了"进程可以随时被替换"这一前提。Agent 的任务有状态，但这份状态必须活在执行器之外。

## 速查：最容易被忽略的十个默认值

| 参数 | 默认值 | 为什么危险 |
|------|--------|-----------|
| Nginx `proxy_read_timeout` | 60s | 计量的是读间隔，长文本生成的静默期会触发 |
| Nginx `proxy_buffering` | on | 攒够缓冲区才转发，SSE 表现为一直 Pending |
| Uvicorn `--limit-concurrency` | 超限返回 503 | 不排队，高峰期请求直接失败 |
| Uvicorn `--timeout-keep-alive` | 5s | 长连接场景过短 |
| SQLAlchemy `pool_size` / `max_overflow` | 5 / 10 | 单实例上限 15，多 worker 下需乘算 |
| PgBouncer `query_wait_timeout` | 120s | 设为 0 即无限排队，背压失效 |
| PgBouncer `max_prepared_statements` | 0 | transaction 模式下协议级 prepare 被关闭 |
| aiohttp `limit_per_host` | 0 | 对单端点不限制，单一 provider 可占满全局 |
| K8s `terminationGracePeriodSeconds` | 30s | 远小于 Agent 任务耗时 |
| K8s 探针 `timeoutSeconds` | 1s | 小于依赖抖动时长，抖动即摘流量 |

## 01 篇补充：三个非参数型的默认行为

| 默认行为 | 后果 | 应对 |
|----------|------|------|
| Pydantic 默认 lax 模式，且 `str` 字段拒收数字 | LLM 把数字塞进字符串字段会直接 422 | 放宽类型或加 `mode='before'` 校验器 |
| Pydantic 序列化"尽最大努力"，类型不符只降级为 `UserWarning` | 脏数据静默通过，生产无感知 | 测试环境把 `warnings` 设为 `'error'` |
| Starlette 路由按声明顺序线性匹配 | `/users/{id}` 声明在前会静默吞掉 `/users/me` | 静态路径段一律前置，代码评审显式检查 |

## 02 篇补充：超时收敛阶梯

方向必须是**外层 > 内层**（外层是内层的上界）。搞反后外层先断、内层白干，Agent 场景表现为客户端已放弃而 LLM 仍在烧 token。

| 层 | 典型默认值 | Agent 场景的矛盾 |
|----|-----------|-----------------|
| Gunicorn `timeout` | 30s | 单次 LLM 调用即可超过 |
| ALB `idle_timeout` | 60s | 空闲超时，首字节不来即断 |
| Nginx `proxy_*_timeout` | 60s（三者） | 长上下文 prefill 的静默期会触发 |
| aiohttp `ClientTimeout.total` | 300s | 长输出生成会被切断 |
| httpx 默认 | 网络不活动 5s | 对 LLM 调用过短 |
| requests 默认 | **无超时** | 下游挂死则线程永久阻塞 |

另需记住两条：`proxy_read_timeout` 计量的是**两次读之间**而非总时长（因此流式持续吐字就不会触发）；重试预算必须满足 `重试次数 × 单次超时 + 退避 < 外层超时`。

## 02 篇补充：错误码判定

| 码 | 判定规则 |
|----|---------|
| 499 | Nginx 私有码，只进 access log 不发给客户端。**客户端先放弃** |
| 502 | 收到了上游响应但**内容非法**，或上游提前关闭 |
| 504 | **压根没收到**上游响应（连/读/发超时） |
| 503 | 无可用 upstream 或主动限流；针对特定客户端的限流应用 429 |
