---
title: 并发模型
category: engineering
parent: 后端服务基础
level: 认知
updated: 2026-09-03
---

# 并发模型：进程、线程与协程

## 1. 三种模型的对比

| 维度 | 进程（Process） | 线程（Thread） | 协程（Coroutine） |
|------|----------------|---------------|------------------|
| 定义 | 资源分配与隔离的基本单位 | CPU 调度的最小单位，进程内的执行流 | 用户态的协作式执行单元 |
| 调度者 | 操作系统内核 | 操作系统内核（抢占式） | 用户态运行时 / 事件循环（协作式） |
| 地址空间 | 独立，默认不共享内存 | 共享进程内存 | 共享线程内存，栈为独立的小块堆内存 |
| 内存开销 | 高（独立解释器、独立堆） | 中（每线程独立栈，通常 MB 级） | 低（量级远小于线程） |
| 切换成本 | 高（需陷入内核、切换页表与上下文） | 中（内核态上下文切换） | 低（用户态，无陷入内核） |
| 并行能力 | 可跨多核真正并行 | 受 GIL 约束（见第 3 节） | 单线程内并发，无并行 |
| 通信方式 | 管道 / 队列（序列化）、共享内存、网络 | 共享内存 + 锁等同步原语 | 直接共享变量（需注意让出点） |
| 隔离性 | 一个崩溃不影响其他 | 一个线程崩溃影响整个进程 | 未捕获异常终止所在 Task |

Python 官方文档对多进程的定义是：通过使用**子进程而非线程**来规避 GIL，从而充分利用机器上的多个处理器。关于内存，官方文档明确：放入 `multiprocessing` 队列的对象会被 `pickle` 序列化，`get` 返回的是**重新创建的对象，与原始对象不共享内存**；并建议在并发编程中尽可能避免使用共享状态，"在使用多进程时尤其如此"。

## 2. 协程的调度本质

Python 官方文档表述为：事件循环在一个线程（通常是主线程）中运行并执行所有回调与 Task；**当一个 Task 正在事件循环中运行时，同一线程中的其他 Task 无法运行**；Task 执行 `await` 表达式时被挂起，事件循环转去执行下一个 Task。

因此协程模型可归纳为：**单线程内的协作式多路复用**。其优势来自切换成本低与无锁编程，其限制来自无并行能力。

## 3. GIL 对 Python 多线程的真实影响

Python 官方术语表对 GIL 的定义：CPython 解释器用以**保证同一时刻只有一个线程执行 Python 字节码**的机制；它通过使对象模型（包括 `dict` 等内建类型）隐式地免于并发访问问题，简化了 CPython 的实现；代价是**牺牲了多处理器机器上的大部分并行能力**。

该定义同时给出两条关键例外：

- **部分标准库或第三方扩展模块被设计为在执行压缩、哈希等计算密集型任务时释放 GIL**。这类扩展可在多线程下实现真正的并行。
- **执行 I/O 时 GIL 总是被释放**。这直接解释了为何多线程对 I/O 密集任务仍然有效：等待 I/O 的线程不持有 GIL，其他线程得以执行字节码。

`parallelism` 词条进一步补充：在带 GIL 的 Python 构建中，要利用多核 CPU，通常需要使用**多进程**，或依赖释放 GIL 的原生扩展。Python 3.13 起可通过 `--disable-gil` 构建自由线程版本（PEP 703），运行时需以 `-X gil=0` 或 `PYTHON_GIL=0` 启用。

由此得到判别表：

| 负载 | 多线程 | 协程 | 多进程 |
|------|--------|------|--------|
| I/O 密集 | 有效（I/O 期间 GIL 释放），但切换与内存成本高于协程 | 最优 | 可行，但资源开销大 |
| CPU 密集（纯 Python 字节码） | 无效，无法跨核 | 无效，且会阻塞循环 | 唯一有效路径 |
| CPU 密集（释放 GIL 的 C 扩展） | 有效 | 可配合 `to_thread` | 有效 |

## 4. 混合模型：Gunicorn + Uvicorn worker

Gunicorn 采用 **pre-fork worker 模型**：由 arbiter（主进程）管理 worker 进程池，主进程不接触客户端套接字，仅监听信号（TTIN/TTOU 调整 worker 数、CHLD 重启崩溃 worker、HUP 重载配置）。

| Worker 类型 | 并发模型 | Keep-Alive | 适用场景 |
|------------|----------|-----------|----------|
| sync | 每 worker 一次处理一个请求 | 否 | CPU 型应用，置于反向代理之后 |
| gthread | 每进程一个线程池 | 是 | 混合负载、中等并发 |
| ASGI（`uvicorn.workers.UvicornWorker`） | asyncio | 是 | FastAPI / Starlette 等异步框架 |
| gevent | greenlet | 是 | I/O 密集、WebSocket、长轮询 |
| tornado | Tornado IOLoop | 是 | 原生 Tornado 应用 |

Uvicorn 部署文档说明：Uvicorn 提供 `--workers 4` 这样的多进程方式，但**不提供任何进程监控**；Gunicorn 则处理套接字建立、启动多个服务进程、监控存活并响应信号以实现重启、关闭与扩缩容。最小命令为 `gunicorn -w 4 -k uvicorn.workers.UvicornWorker`；`UvicornWorker` 默认使用 `uvloop` 与 `httptools` 实现。

需注意：Gunicorn 的配置选项集与 Uvicorn 不同，部分选项（如 `--limit-concurrency`）在 Gunicorn 下尚不支持，需通过子类化 `UvicornWorker` 并覆写 `CONFIG_KWARGS` 传递。

这一组合即**多进程 × 协程**的两层并发：外层由操作系统在多个核上并行调度进程，每个进程内由一个事件循环并发调度大量协程。

### 4.1 worker 数的经验公式与其适用边界

Gunicorn 官方文档给出 `workers = (2 × CPU 核数) + 1`，并警告"不要过度扩容"，通常 4-12 个 worker 即可承载重流量，过多会浪费资源并降低吞吐。

但需要明确其语境：该公式出自 Gunicorn 官方设计文档，针对的是同步 worker。多篇工程博客指出，对 ASGI 异步 worker，因单个 worker 已能在事件循环内承载大量并发，worker 数应更接近 CPU 核数（甚至更少）而非 2 倍核数加一。此判断属工程经验，**未见官方文档明确背书**，建议以实测为准。

## 5. 常见陷阱

- **进程间不共享内存**。官方文档明确传递对象是序列化后的重建副本；`Value` / `Array` 共享内存中 `counter.value += 1` 这类读—改—写**不是原子操作**，需显式加锁。实践推论：进程内缓存、计数器、限流器在多 worker 下是每进程一份，语义被放大 N 倍，必须外置到 Redis 等共享存储。
- **线程安全**。线程共享进程内存，同步原语的必要性高于多进程。GIL 只保证字节码级的互斥，**不保证应用层复合操作的原子性**——这一点常被误读为"有 GIL 就不用加锁"。
- **协程中的阻塞调用**。协程的阻塞代价高于线程，因为其阻塞影响的是整个事件循环内的所有任务。
- **worker 数与内存的关系**。每增加一个 worker 即复制一份应用代码、依赖、连接池与模型权重，内存随 worker 数近似线性增长。
- **fork 与已建立的连接**。`preload_app` 在 fork 前加载应用，可借写时复制节省内存，但父进程中已建立的连接池、套接字会被子进程继承，须在 fork 后重建。此项的详细约束未在本次检索的官方文档中查到，仅见于工程博客，落地时应自行验证。
- **Python 3.14 起 `fork` 不再是任何平台的默认启动方法**。官方文档说明 POSIX 默认改为 `forkserver`，Windows 与 macOS 为 `spawn`；在 REPL 中定义的局部函数无法被子进程反序列化，会抛 `AttributeError`。使用进程池时目标函数须定义在可导入模块中。
- **协程与进程池混用时的序列化**。提交给进程池的函数与参数需可 pickle，闭包与 lambda 不可用。

## 6. AI Agent 服务的进程模型考量

| 考量项 | 说明 |
|--------|------|
| worker 数上限由内存决定，而非 CPU | 本地推理场景下，模型权重常驻内存，worker 数 × 单 worker 内存须留出余量给 KV cache、批处理与页缓存 |
| 模型常驻内存 | 在 `lifespan` 中加载一次并按进程级持有；每 worker 独立持有一份副本，N 个 worker 即 N 份权重 |
| 显存是硬约束 | GPU 场景下并非进程数越多越好，通常让推理由独立服务（如 vLLM）统一批处理，业务层只做 HTTP 调用，把 GPU 显存管理与 HTTP 并发模型解耦 |
| 流式长连接占用 | SSE / WebSocket 连接在存活期间占用 worker 内的 Task 与文件描述符；长尾请求需要更长的 `timeout` 与 `graceful_timeout`，并与负载均衡器超时对齐 |
| 状态外置 | 会话历史、工具执行中间态、限流计数、分布式锁都必须外置；进程内字典在多 worker 下不可用 |
| 优雅重启 | 依赖进程管理器完成：Gunicorn 通过 SIGHUP 重载、CHLD 重启崩溃 worker；`max_requests` 配合 jitter 可回收 worker 以缓解内存缓慢增长 |
| 请求回收与长任务 | 超过 worker `timeout` 未响应的进程会被重启；耗时远超该值的任务应下沉到任务队列，而非留在请求链路中 |

### 6.1 组合建议：按职责分层，而非单一模型

1. **接入层**：多进程（worker 数取 CPU 核数量级，以实测内存与下游并发为准）+ 每进程协程，处理 HTTP、鉴权、编排与流式响应。
2. **I/O 层**：统一使用异步客户端，保证等待可让出。
3. **CPU 层**：CPU 密集操作以进程池或独立服务承载，避免占用事件循环。
4. **状态层**：Redis / 数据库 / 对象存储，作为跨进程唯一事实来源。

## 7. 自测问题

1. 进程、线程、协程的调度者分别是谁？由此导致的切换成本差异是什么？
2. GIL 的两条例外是什么？为什么多线程对 I/O 密集任务仍然有效？
3. 协程能提供真正的并行吗？为什么？
4. Gunicorn + Uvicorn 组合构成几层并发？各自解决什么问题？
5. `workers = 2 × CPU + 1` 这个公式的适用语境是什么？异步 worker 下是否仍然适用？
6. 多 worker 下，进程内的计数器与限流器会发生什么？为什么？
7. Agent 服务中，worker 数的上限由什么决定？本地推理场景下又由什么决定？

## 8. 参考来源

1. Python — multiprocessing，https://docs.python.org/3/library/multiprocessing.html
2. Python — Glossary: global interpreter lock，https://docs.python.org/3/glossary.html
3. Python — Coroutines and Tasks，https://docs.python.org/3/library/asyncio-task.html
4. Gunicorn — Design，https://gunicorn.org/design/
5. Uvicorn — Deployment（官方文档站抓取受阻，取自其文档仓库镜像），https://github.com/MarioIshac/uvicorn/blob/master/docs/deployment.md
6. PEP 703 — Making the Global Interpreter Lock Optional，https://peps.python.org/pep-0703/
7. FastAPI — Concurrency and async / await，https://fastapi.tiangolo.com/async
