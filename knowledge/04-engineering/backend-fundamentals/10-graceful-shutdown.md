---
title: 优雅关闭
category: engineering
parent: 后端服务基础
level: 应用
updated: 2026-09-03
---

# 优雅关闭

## 1. 概念定义与信号语义

**SIGTERM** 是可被进程捕获、忽略或用于执行清理逻辑的信号，本质是一次"请退出"的**协商**。
**SIGKILL** 不可被捕获、不可被忽略，由内核直接终止进程，进程**没有任何执行清理逻辑的机会**。

`kill -9` 之所以丢数据，是因为它跳过了四类收尾动作：

1. 未提交事务与缓冲区未落盘。
2. 在途响应被截断，客户端收到不完整结果。
3. 已取未还的资源（分布式锁、租约、队列消息）无法归还。
4. 后台埋点、trace、检查点队列未 flush。

注意其中一部分在数据库侧会被回滚，但**应用层已对外宣告的状态与数据库的实际状态可能因此不一致**——这才是"丢数据"的真正含义，不只是数据消失。

十二要素第 IX 节（Disposability）的主张：进程应在收到 SIGTERM 时优雅关闭；同时**也应对"突然死亡"具备鲁棒性**（硬件故障）。后者的推荐做法是使用健壮的队列后端，在客户端断开或超时后把任务归还队列。

## 2. 优雅关闭的标准流程

1. **摘除流量**：从负载均衡器或服务发现的端点集合中移除本实例。
2. **停止接收新请求**：对 HTTP 服务即"停止监听服务端口，从而拒绝所有新请求"。
3. **等待在途请求完成，且必须设上限**。
4. **释放资源**：关闭连接池、收敛后台任务、队列消息归还（NACK）、释放锁与租约、检查点落盘。
5. **退出进程**。

对 worker 进程，十二要素的要求是**把当前任务归还工作队列**：RabbitMQ 发送 NACK；Beanstalkd 在 worker 断开时自动归还；基于锁的系统须确保释放对任务记录的锁。其隐含前提是**所有任务可重入**，通常通过把结果包装在事务中、或使操作幂等来实现。

## 3. Kubernetes 中的时序与参数

官方终止流程依次为：

1. Pod 被标记 `Terminating`，API 对象记录体面终止限期（**默认 30 秒**）。
2. 若容器定义了 `preStop` 且 `terminationGracePeriodSeconds` 不为 0，kubelet **先在容器内执行该回调**。若回调在宽限期届满后仍在运行，kubelet 会请求一次性的 2 秒宽限期延长。
3. kubelet 触发容器运行时向每个容器内的 1 号进程发送 **TERM 信号**。除 sidecar 容器有特定顺序外，**各容器接收 TERM 的时间与顺序是任意的**；若关闭顺序重要，官方建议用 `preStop` 钩子同步。
4. 与此同时，控制平面评估是否把该 Pod 从 EndpointSlice 移除；ReplicaSet 等工作负载资源不再将关闭中的 Pod 视为合法的服务中副本。**正在终止的端点其 `ready` 状态恒为 false**，负载均衡器不会将其用于常规流量。
5. 宽限期届满后，若仍有容器在运行，kubelet 触发强制关闭，容器运行时发送 **SIGKILL**。
6. kubelet 将 Pod 转入终止阶段，并强制移除 API 对象。

两个必须记住的官方约束：

- **宽限期是针对 `preStop` 回调执行时间与容器正常停止时间的总和。** 官方示例：若 `terminationGracePeriodSeconds=60`，回调耗时 55 秒，容器收到信号后需 10 秒完成，则容器**会在正常结束前被杀死**（55 + 10 > 60）。
- **`preStop` 回调不会与信号处理异步执行，回调必须先完成，TERM 信号才会发出。** 回调失败会杀死容器。

## 4. 超时参数的推荐搭配

Google Cloud GKE 官方给出了一套成套推荐值（面向 NEG 场景）：

| 参数 | 推荐值 | 默认值 | 约束 |
|------|--------|--------|------|
| BackendService Drain Timeout（`connectionDraining.drainingTimeoutSec`） | 60 秒 | 0（即停用排空） | 范围 0–3600 秒；**应为请求处理时长的 1.5–2 倍** |
| `preStop` sleep | 120 秒 | 无 | ≥ Drain Timeout + 排空延迟（排空延迟建议按 60 秒估算） |
| `terminationGracePeriodSeconds` | 210 秒 | 30 秒 | ≥ preStop 时间 + Pod 关停时间 |

官方给出的两个公式：

```
preStop 执行时间          ≥ BACKEND_SERVICE_DRAIN_TIMEOUT + DRAIN_LATENCY
terminationGracePeriod    ≥ preStop hook time + Pod shutdown time
```

并强调：**Drain Timeout 必须与 `preStop` 搭配使用，否则未完成的现有请求会收到 502 错误**；将 Drain Timeout 设为大于 0 可减少 503 错误。另需注意 `preStop` 必须施加到 Pod 中的**每个容器**，没有该钩子的容器会在 Pod 删除后立即退出。

AWS 侧对应概念是 **Deregistration delay**：ELB 停止向正在注销的目标发送请求，**默认等待 300 秒**以让在途请求完成；若目标在注销延迟届满前主动断开连接，客户端会收到 500 级错误响应。若目标已无在途请求与活动连接，注销会立即完成。

## 5. 就绪探针与存活探针的分工

| 探针 | 判定内容 | 失败后果 | 适用 |
|------|----------|----------|------|
| startup | 容器内应用是否已启动 | 重启容器 | 启动慢的应用；成功前不执行 liveness / readiness |
| liveness | **何时重启容器** | 重启容器 | 死锁等"进程在但无法推进"的不可恢复故障 |
| readiness | **容器是否可接收流量** | 从匹配 Service 的 EndpointSlice 移除该 Pod IP | 初始化、临时故障、过载；全生命周期持续运行 |

官方警告需要完整引述：**liveness 探针"必须谨慎配置，确保它真的指示不可恢复的应用故障"；错误的实现会导致级联故障——高负载下重启容器、客户端请求失败、应用可扩展性变差，并把额外负载压到剩余 Pod 上。**

其他要点：若容器进程遇到问题会自行崩溃，则**不一定需要 liveness 探针**，kubelet 会按 `restartPolicy` 自动处理；readiness 探针实现不当可能导致容器内进程数不断增长并引发资源耗尽；readiness 失败时容器继续运行并持续被探测。

官方对"依赖健康"的处理有明确表述：当应用对后端服务有严格依赖时，可同时实现两个探针——**liveness 探针在应用自身健康时通过，readiness 探针额外检查每个必需的后端服务是否可用**。这正是"不要把依赖组件健康当作自身健康"的落地方式。

补充：若只想在 Pod 删除时排空请求，**不一定要 readiness 探针**——Pod 删除时对应端点在 EndpointSlice 中的 ready 条件会被置为 false。

## 6. 健康检查端点设计的常见错误

| 错误 | 后果 | 正确做法 |
|------|------|----------|
| 把数据库 / 缓存 / 下游模型服务的健康当作 liveness | 单点依赖抖动触发全量重启，形成级联故障 | liveness 只做进程级自检；依赖健康放 readiness |
| 探针执行重活（查库、查向量库） | 探针本身成为负载放大器，超时后又触发重启 | 探针只做 O(1) 内存态检查 |
| 所有探针共用一个 `/health` | 无法区分"可接流量"与"需重启" | 拆分 `/livez` 与 `/readyz`，后者可含依赖检查 |
| 关闭期仍返回 ready | 新流量持续打入正在终止的 Pod | 收到 SIGTERM 后立即翻转 ready 为 false，并维持一段时间以覆盖端点传播延迟 |
| 探针超时小于依赖抖动时长 | 抖动即摘流量 | `timeoutSeconds` 默认仅 1 秒，需按实际调整 |

上述清单为工程经验归纳，Kubernetes 官方仅覆盖其中"liveness 不得依赖外部依赖"与"readiness 可额外检查后端"两条。

## 7. 超时强制终止与长任务的矛盾

**矛盾是结构性的。** 十二要素对优雅关闭的隐含假设是"HTTP 请求很短（不超过几秒）"，长轮询场景下则要求客户端在连接断开后无缝重连。而 Agent 任务的典型耗时在数十秒至数分钟量级，远超默认 30 秒宽限期。

三条处理路径：

1. **拉长宽限期**。可行但有明确上限：滚动发布时长、节点维护窗口、云厂商排空超时上限都会约束它，且拉长宽限期会降低故障恢复速度。
2. **任务外置（推荐）**。HTTP 层只负责提交与查询进度，任务由独立 worker 池执行，服务关停不影响任务存活。这是根本解法。
3. **检查点 + 可恢复**。任务按步骤推进，每步完成即落盘；被 SIGKILL 后由任一副本从最后一个检查点续跑。

GKE 官方对 ML 工作负载的建议即第 3 类：设置足够长的 `terminationGracePeriodSeconds`（示例 600 秒），由工作负载捕获 SIGTERM 并启动检查点过程。

需注意 **PodDisruptionBudget 与宽限期的耦合**：PDB 的 `maxUnavailable` / `minAvailable` 必须允许在通知窗口内完成驱逐，否则驱逐时可能被迫违反可用性约束。

## 8. AI Agent 场景注意点

### 8.1 流式连接（SSE / WebSocket）如何优雅断开

1. 收到 SIGTERM 后先停止接受新流，向已有流发送一个**终止事件**，携带 reason 与最后的 sequence id。
2. **服务端不要立即关闭 TCP**，需给客户端留出重连窗口。`preStop` sleep 的作用正是覆盖"端点传播 + 客户端重连"这段延迟——这是该钩子在 Agent 场景下最常见的用途。
3. 半途截断的响应在客户端侧必须**可识别**：缺少 `[DONE]` 或终止事件即视为不完整，触发带游标的重连续传。
4. 注意反向代理自身的缓冲与超时同样会截断流，其参数必须与 Pod 侧排空参数对齐。

### 8.2 在途 Agent 任务的三分类处置

| 类型 | 处置 |
|------|------|
| 已提交未开始 | 归还队列 / NACK，任务态保持 pending |
| 进行中且可检查点 | 在下一个安全点落盘检查点，状态置为 interrupted，由调度器重新派发 |
| 进行中且不可中断（已发出不可逆的外部工具调用） | 依赖幂等键与可重入设计；**宁可重复执行，不可半途丢失** |

### 8.3 检查点落盘

检查点必须**先落盘、后推进**（write-ahead 语义），否则恢复时会重复执行不可逆的副作用。检查点内容应至少包含：`session_id`、已完成步骤序号、工具调用参数与结果、累计 token 与成本。

落盘之后仍需保证幂等——因为"至少一次"语义下恢复必然带来重放。

### 8.4 关闭顺序（Agent 场景特有）

```
停止接收新请求
  → 等待已有 LLM 请求完成或按 read timeout 放弃
  → 关闭 HTTP 客户端（LLM SDK）
  → 关闭数据库连接池
```

顺序颠倒会产生"连接已关但回调仍在写入"的错误。

### 8.5 资源释放清单

HTTP 客户端（LLM SDK）、数据库连接池、Redis 池、向量库客户端、消息中间件消费者（先停拉取，再 ack / 归还）、文件句柄、检查点写入器、后台 trace / 埋点队列（**必须 flush**）。

其中最后一项是关停期最常见的数据丢失点：追踪数据在内存队列中尚未上报，进程已退出，导致最后一批请求在观测系统中凭空消失。

### 8.6 与弹性伸缩的交互

HPA 缩容同样走终止流程。若 Agent 长任务跑在 HTTP 请求连接上，一次缩容就会杀掉一批在途任务——这是"任务外置"最强的工程理由。

## 9. 自测问题

1. SIGTERM 与 SIGKILL 的本质差别是什么？`kill -9` 跳过哪四类收尾动作？
2. 优雅关闭的五个步骤是什么？哪一步必须设上限？
3. Kubernetes 中 `preStop` 与 TERM 信号的执行顺序是什么？宽限期覆盖哪两段时间之和？
4. GKE 推荐的三个超时参数值分别是多少？两个公式是什么？
5. liveness 与 readiness 的判定内容分别是什么？为什么 liveness 不能检查外部依赖？
6. 长任务与宽限期之间的矛盾有哪三条处理路径？推荐哪一条？
7. 流式连接在优雅关闭时应如何处理？为什么服务端不能立即关闭 TCP？
8. 检查点为什么必须先落盘后推进？落盘后为什么还需要幂等？

## 10. 参考来源

1. The Twelve-Factor App — IX. Disposability，https://12factor.net/disposability
2. Kubernetes — Pod Lifecycle，https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle
3. Kubernetes — Container Lifecycle Hooks，https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
4. Kubernetes — Liveness, Readiness, and Startup Probes，https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/
5. Kubernetes — Explore Termination Behavior for Pods And Their Endpoints，https://kubernetes.io/docs/tutorials/services/pods-and-endpoint-termination-flow
6. Google Cloud — GKE Ingress configuration，https://docs.cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration
7. AWS — Edit target group attributes for your Application Load Balancer，https://docs.aws.amazon.com/elasticloadbalancing/latest/application/edit-target-group-attributes.html
8. AWS — Configure connection draining for your Classic Load Balancer，https://docs.aws.amazon.com/elasticloadbalancing/latest/classic/config-conn-drain.html
