---
title: 连接池
category: engineering
parent: 后端服务基础
level: 应用
updated: 2026-09-03
---

# 连接池

## 1. 概念定义

SQLAlchemy 官方文档的定义：**连接池是一种在内存中维持长连接以高效复用、同时对应用可能同时使用的连接总数施加管理的技术**。

它包含两层语义，缺一不可：

- **复用层**：摊薄连接建立的固定成本。
- **限流层**：把"应用能同时打到后端的并发"约束在一个已知的数上。

第二层常被忽略，却是连接池在稳定性上的主要价值——**连接池本质上是一个有界队列形式的背压装置**。它把"下游被压垮"转化为"上游排队或快速失败"，从而保护整条链路。

## 2. 为什么需要连接池：连接的建立成本

一次数据库连接的建立至少要付出四笔成本：

1. TCP 三次握手。
2. TLS 握手。
3. 数据库认证握手（PostgreSQL 的 startup 报文与 SCRAM 认证为非平凡的多轮交互）。
4. 服务端侧的进程或资源分配。

服务端侧的代价有官方依据：PostgreSQL 文档明确 `max_connections` 会**直接决定部分资源的分配规模，提高该值会导致共享内存等资源分配增加**，且该参数只能在服务启动时设置。

连接池把这四笔成本从"每请求一次"摊销为"每连接一次"。

## 3. 核心参数

### 3.1 客户端侧（以 SQLAlchemy QueuePool 为例）

| 参数 | 默认值 | 语义 |
|------|--------|------|
| `pool_size` | 5 | 池中**持久保留**的连接数上限 |
| `max_overflow` | 10 | 超出 `pool_size` 后可临时创建的连接；归还时直接关闭丢弃，不转为常驻 |
| `pool_timeout` | 30.0 | 获取连接的等待秒数，超时即放弃 |
| `pool_recycle` | -1 | 按连接年龄回收；**仅在检出时生效**，对已检出的连接无效 |
| `pool_pre_ping` | False | 悲观断连检测：每次检出先探测活性 |
| `pool_use_lifo` | False | LIFO 归还，让多余连接保持空闲，交由服务端超时回收 |
| `pool_reset_on_return` | `rollback` | 归还时回滚，清除未提交数据与表/行锁 |

官方给出的总量公式：**池允许的同时连接总数 = `pool_size` + `max_overflow`；池允许的空睡连接总数 = `pool_size`**（默认即 15 / 5）。且所有池实现都**不会预创建连接**，只有真实并发达到该规模时才增长到该规模。

`pool_pre_ping` 的官方边界需特别注意：它**无法处理事务或 SQL 执行中途被断开的连接**。若数据库在执行过程中不可用，该操作已丢失，需由应用层放弃或重试整个事务。

### 3.2 服务端侧池化代理（PgBouncer 关键参数）

| 参数 | 默认值 | 语义 |
|------|--------|------|
| `max_client_conn` | 100 | 客户端连接上限；提升时需同步提高 OS 文件描述符限制 |
| `default_pool_size` | 20 | 每个 user/database 对的 server 连接数 |
| `min_pool_size` | 0 | 池的下限预热 |
| `reserve_pool_size` / `reserve_pool_timeout` | 0 / 5.0 | 应急备用连接；客户端等待超时后才动用 |
| `server_idle_timeout` | 600.0 | 空闲 server 连接关闭时间，0 为禁用 |
| `server_lifetime` | 3600.0 | server 连接最长寿命；设 0 表示只用一次即关 |
| `query_wait_timeout` | 120.0 | 排队等待上限；**设为 0 意味着客户端无限排队** |
| `server_check_query` | 空 | 存活检查；空字符串表示禁用 |
| `server_reset_query` | `DISCARD ALL` | 归还时清理会话态；**transaction 模式下不使用** |

## 4. 数据库侧连接上限与池规模的关系

PostgreSQL 官方默认值：`max_connections` = 100（若内核设置不支持则更低），`superuser_reserved_connections` = 3，`reserved_connections` = 0。备库的 `max_connections` 必须大于或等于主库，否则备库不允许查询。

由此得到三条公式，实践中必须同时满足：

**公式 A（容量硬约束）**

```
Σ(单实例池上限 × 单实例 worker 数) × 实例副本数 + 运维预留
    ≤ max_connections − superuser_reserved_connections − reserved_connections
```

违反此式的后果是连接建立被直接拒绝，而非排队。

**公式 B（性能软约束，PostgreSQL wiki 官方建议）**

```
活跃连接数 ≈ (core_count × 2) + effective_spindle_count
```

其中 core_count 不计超线程；数据集完全缓存时 effective_spindle_count 取 0。wiki 同时强调：**`max_connections` 应始终略大于池中启用的连接数**，以便留出少量槽位供系统维护与监控直连。

**公式 C（死锁避免下界，HikariCP wiki）**

```
pool_size = Tn × (Cm − 1) + 1
```

`Tn` 为最大线程数，`Cm` 为单线程同时持有的最大连接数。这是**避免死锁所需的最小值，不是最优值**。

PostgreSQL wiki 解释了为什么越过"拐点"后吞吐反而下降：磁盘寻道颠簸、`work_mem` 按每连接每查询节点多份分配导致缓存被冲掉或触发 swap、自旋锁与 LW 锁竞争、上下文切换、CPU 缓存行竞争，以及部分内部结构按 `max_connections` 以 O(N²) 或 O(N·logN) 规模分配。

## 5. 外部池化代理：PgBouncer 的三种模式

PgBouncer 官方表述：`pool_mode` 决定 **server 连接何时可被其他客户端复用**。

| PostgreSQL 特性 | session | transaction | statement |
|----------------|---------|-------------|-----------|
| 连接释放时机 | 客户端断开后 | 事务结束后 | 单条查询结束后 |
| 多语句事务 | 支持 | 支持 | **禁止** |
| `SET` / `RESET` | 支持 | **不支持** | **不支持** |
| `LISTEN` | 支持 | **不支持** | **不支持** |
| `NOTIFY` | 支持 | 支持 | 支持 |
| `WITH HOLD` 游标 | 支持 | **不支持** | **不支持** |
| SQL 级 `PREPARE` / `DEALLOCATE` | 支持 | **不支持** | **不支持** |
| **协议级预处理语句** | 支持 | **支持（需 `max_prepared_statements` 设为非 0 才启用）** | 支持 |
| 会话级 advisory lock | 支持 | **不支持** | **不支持** |
| 临时表 | 支持 | **不支持** | **不支持** |

对预处理语句的影响是最容易踩的坑，需区分两个层次：

1. **SQL 级** `PREPARE` / `DEALLOCATE` 在 transaction 模式下明确不可用。
2. **协议级**（扩展查询协议）的 prepared statement 在 transaction 模式下**可用，但必须把 `max_prepared_statements` 配置为非 0 值才会启用**——默认值下该支持是关闭的。

由于 psycopg 等主流驱动默认走协议级 prepare 而非 SQL 级 `PREPARE`，迁移到 transaction 模式时若未调整该参数，表现会是间歇性的 prepare 失败或连接状态异常，而非明确的报错。这类问题极难定位。

官方另注明 transaction 模式下 `server_reset_query` 不生效，因为该模式下每个事务可能落在不同 server 连接上、获得不同会话状态。

## 6. 常见故障与排查

| 故障 | 机理 | 排查要点 |
|------|------|----------|
| 连接泄漏 | 未显式归还；异步任务未退出上下文；异常路径跳过 finally | 监控 checkout/checkin 事件与 `Pool.status()`；为长任务设持有时间上限 |
| 连接耗尽雪崩 | 池满后请求在 `pool_timeout` 内排队，超时向上游传导，客户端重试放大流量 | `query_wait_timeout=0`（无限排队）是最危险的配置——它把背压从"拒绝"变成"累积" |
| 池化后长事务 | transaction 模式下长事务全程独占 server 连接，等效于缩小池 | 拆分长事务；为长任务独立建池 |
| 超时级联 | 客户端超时 < 池等待超时 < 服务端语句超时形成倒挂 | 自下而上递增；每一层的超时必须是下一层的上界 |
| 陈旧连接 | 负载均衡器或防火墙回收空闲连接，池不知情 | `pool_pre_ping` + `pool_recycle` 组合；注意 pre-ping 救不了"执行中断连" |
| 池大小设置误区 | "越大越好" | 见公式 B；HikariCP wiki 给出的实证是连接数从 2048 降到 96 后响应时间从约 100ms 降到约 2ms |

## 7. 不止数据库：HTTP 与 Redis

- **httpx**：`httpx.Limits(max_keepalive_connections=20, max_connections=100, keepalive_expiry=5.0)`，三项均为官方默认值。
- **aiohttp**：`TCPConnector(limit=100, limit_per_host=0)`。`limit_per_host` 默认 0 表示**对单端点不做限制**，这是默认值中最需要注意的一项。另默认启用 DNS 缓存，TTL 为 10 秒。
- **Redis**：官方区分两种模型。连接池在池满时按需新建连接；多路复用以单连接承载全部流量，效率更高，但**无法支持 `BLPOP` 这类阻塞命令**——阻塞会拖住所有调用方。

## 8. AI Agent 场景下的注意点

1. **长耗时请求长期占用连接是结构性矛盾。** 若请求全程持有 DB 连接，而单次 LLM 调用耗时数十秒至数分钟，少数长请求即可占满整个池。正确做法是把数据库访问收敛为离散的**短事务片段**，在调用 LLM 之前取连接、用完后立即归还，LLM 等待期间不持连接。

2. **LLM 客户端本质是 HTTP 连接池 + 超时三件套。** 应放大 read timeout（等待生成）、收紧 connect timeout（快速失败），并按 provider 域名拆分 `limit_per_host`，避免单一 provider 占满全局连接上限。注意 aiohttp 的 `limit_per_host` 默认为 0 即不限制，必须显式设置。

3. **乘积关系是容量核算的陷阱。** 总服务端连接数 ≈ 池上限 × 单 Pod worker 数 × Pod 副本数。启用 HPA 后副本数动态变化，连接预算必须按最大副本数核算，否则扩容会击穿数据库——这是"平时正常、一扩容就雪崩"的典型成因。

4. **工具调用扇出推高单请求连接需求。** 一次推理可能并发触发 N 个工具调用，单请求同时持有多个连接，应套用公式 C 估算下界，并为工具调用设置并发闸门。

5. **为在线请求与 Agent 后台任务建立两个独立池。** 长任务不应抢占在线池，这是 HikariCP wiki 对"长事务与短事务混合系统"给出的明确建议。

## 9. 自测问题

1. 连接池的两层语义是什么？为什么说它是背压装置？
2. `pool_size` 与 `max_overflow` 的区别是什么？默认总连接数上限是多少？
3. `pool_pre_ping` 能解决哪类断连问题，不能解决哪类？
4. 容量硬约束公式是什么？违反它的后果是排队还是拒绝？
5. PgBouncer transaction 模式下，协议级预处理语句需要什么额外配置？不配置的症状是什么？
6. `query_wait_timeout=0` 为什么是最危险的配置？
7. Agent 服务中，为什么不能在调用 LLM 期间持有数据库连接？
8. 启用 HPA 后，连接预算应按什么副本数核算？

## 10. 参考来源

1. SQLAlchemy 2.0 — Connection Pooling，https://docs.sqlalchemy.org/en/20/core/pooling.html
2. SQLAlchemy 2.0 — Engine Configuration，https://docs.sqlalchemy.org/20/core/engines.html
3. PgBouncer — Config，https://www.pgbouncer.org/config.html
4. PgBouncer — Features，https://www.pgbouncer.org/features.html
5. PostgreSQL — Connections and Authentication，https://www.postgresql.org/docs/current/runtime-config-connection.html
6. PostgreSQL wiki — Number Of Database Connections，https://wiki.postgresql.org/wiki/Number_Of_Database_Connections
7. HikariCP Wiki — About Pool Sizing，https://github.com/brettwooldridge/HikariCP/wiki/About-Pool-Sizing
8. HTTPX — Resource Limits，https://www.python-httpx.org/advanced/resource-limits/
9. aiohttp — Advanced Client Usage，https://docs.aiohttp.org/en/stable/client_advanced.html
10. Redis Docs — Connection pools and multiplexing，https://redis.io/docs/latest/develop/clients/pools-and-muxing/
