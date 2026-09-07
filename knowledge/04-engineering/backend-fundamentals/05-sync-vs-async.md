---
title: 同步与异步
category: engineering
parent: 后端服务基础
level: 理解
updated: 2026-09-03
---

# 同步与异步

## 1. 概念辨析：两种"异步"语义

"异步"一词在工程中承载两种互不等同的含义，混用是大量误判的根源。

**并发模型意义上的异步**：调用发起后不阻塞调用方线程，结果通过回调、Future/Promise 或后续轮询取得。此处的对立面是"同步调用"。

**编程语法意义上的异步**：`async` / `await` 关键字与协程。此处的对立面是"普通函数"。

关键结论：**语法上的 `async def` 并不自动带来并发模型上的异步**。Python 官方文档指出，事件循环使用协作式调度，一次只运行一个 Task。因此若 `async def` 内部包含阻塞调用，语法是异步的，运行时却是完全串行的——代码看着现代，性能比同步还差，因为它额外承担了协程调度的开销。

## 2. 阻塞 I/O 与非阻塞 I/O

阻塞 I/O 中，发起 I/O 的线程被内核挂起直到数据就绪，期间无法执行任何其他代码。非阻塞 I/O 立即返回"未就绪"状态，由事件循环（底层通常是 `select` / `epoll` / `kqueue`）统一等待多个描述符就绪后再回调。

MDN 对 JavaScript 执行模型的描述刻画了同一机理的抽象形式：agent 维护堆、作业队列与调用栈，一次只能处理一条语句；当代码需要执行异步动作时，完成处理后要执行的代码被定义为回调并作为作业入队，栈清空后再拉取下一个作业。

该模型的关键保证是"永不阻塞"，但 MDN 同时指出，**这一保证以平台 API 本身是异步的为前提**，例外如 `alert()` 或同步 XHR 会破坏该保证。这一点与 Python 生态完全相同：async 的收益取决于底层库是否真正非阻塞。

## 3. 事件循环机理与 await 的让出点

Python 官方文档对 `await` 行为的描述可概括为三步：

1. 协程 `await` 一个 Future 时，Task 挂起该协程的执行，交还控制权。
2. 事件循环随即运行其他 Task、回调或执行 I/O。
3. Future 完成后被包装的协程恢复执行，并以结果作为 `await` 表达式的值。

由此得到两条推论。

**推论一：让出点只存在于 `await`（以及 `async for` / `async with`）。** 没有 `await` 的连续代码段是不可被打断的原子段。这既意味着协程内的临界区天然不需要锁，也意味着一个不含 `await` 的长循环会冻结整个循环。

**推论二：并发必须显式构造。** 顺序 `await` 两个协程是串行执行，须用 `asyncio.create_task()` 或 `TaskGroup` 包装后才被并发调度。这是初学者最常见的误解——写了 `async` 却没获得任何并发。

两条易被忽视的官方约束：事件循环只对 Task 保持**弱引用**，`create_task()` 的返回值必须保存强引用，否则任务可能在完成前被回收；`Task` 本身**不是线程安全的**。

## 4. 收益边界

| 负载类型 | 协程的收益 | 依据 |
|----------|-----------|------|
| I/O 密集（网络、磁盘、数据库调用） | 显著：等待时间用于服务其他 Task，单线程可承载大量并发连接 | 事件循环在 Task 挂起期间执行其他任务 |
| CPU 密集（纯计算） | 无收益，且有害：阻塞循环，延迟所有并发任务 | 官方文档：若某函数进行 1 秒 CPU 密集计算，所有并发的 asyncio Task 与 I/O 操作都会延迟 1 秒 |
| CPU 密集且实现为释放 GIL 的 C 扩展 | 可用 `to_thread` 获得部分收益 | 官方文档：`asyncio.to_thread()` 通常只能使 I/O 密集函数非阻塞；对于释放 GIL 的扩展模块或无 GIL 的 Python 实现，也可用于 CPU 密集 |

需注意 `asyncio.to_thread()` 的边界：官方文档明确其用途是在单独线程中运行 **I/O 密集**函数，且当前 `contextvars.Context` 会被传播。

## 5. CPU 密集任务的正确处理

- **线程池**：`loop.run_in_executor()` 配合 `ThreadPoolExecutor`，或 `asyncio.to_thread()`。适用于 I/O 阻塞或释放 GIL 的扩展。
- **进程池**：真正的 CPU 并行，绕过 GIL。代价是参数与返回值需序列化、进程间不共享内存。
- **独立服务**：将重计算拆为独立部署单元（如模型推理服务、任务队列），由主服务通过消息或 RPC 调用。这是 Agent 系统中嵌入计算、文档解析等重任务的常见形态。

## 6. FastAPI 中 `def` 与 `async def` 的处理差异

FastAPI 官方文档的表述：以普通 `def` 声明的路径操作函数，会在**外部线程池**中运行并被 await，而不是直接调用（因为直接调用会阻塞服务器）。同样规则适用于依赖。

实践含义有三层：

1. `async def` 端点中的阻塞调用会阻塞该 worker 的整个事件循环，影响该进程内所有并发请求。
2. `def` 端点被卸载到线程池，不会阻塞循环，但会占用一个线程池槽位；线程池容量有限，阻塞型端点过多仍会形成排队。
3. 官方文档特别提示：来自其他框架、习惯用普通 `def` 定义纯计算端点以换取微小时延收益（约 100 纳秒）的开发者，在 FastAPI 中效果相反——除非端点内确为阻塞 I/O，否则应使用 `async def`。

关于线程池默认大小，社区讨论常引用的数值未见于 FastAPI 官方文档，本次检索未能取得可核实的官方出处，此处不作断言。

## 7. 常见陷阱

| 陷阱 | 后果 | 正确做法 |
|------|------|----------|
| 在 `async def` 中调用阻塞库（`requests`、`time.sleep()`、同步 ORM、标准 `open()`） | 冻结整个事件循环 | 改用 `httpx.AsyncClient`、`asyncio.sleep()`、`asyncpg`、`aiofiles`，或显式 `to_thread` |
| 忘记 `await` | 协程不仅不运行，还会发出 `RuntimeWarning: coroutine '...' was never awaited` | 静态检查工具可捕获 |
| 混用同步与异步客户端 | 连接池割裂、事务边界失效、时序问题难以复现 | 同一事务内统一客户端类型 |
| 异步上下文中的全局变量竞态 | 跨 `await` 的读—改—写不原子 | 状态收敛到 Task 局部，或用 `contextvars`、异步锁、外部存储 |
| 网络日志阻塞循环 | 日志写入成为隐蔽瓶颈 | 官方文档建议为日志处理使用独立线程或非阻塞 I/O |
| 跨线程调用 asyncio API | 几乎所有 asyncio 对象都不是线程安全的 | 用 `loop.call_soon_threadsafe()` 调度回调，`asyncio.run_coroutine_threadsafe()` 调度协程 |

关于第三条"混用客户端"：这在 Agent 服务中尤为常见，因为 LLM SDK 是异步的而某些内部服务的 SDK 只有同步实现，此时必须用 `to_thread` 显式卸载，并注意线程池容量。

## 8. Agent 服务为何天然 I/O 密集，以及收益边界

一次典型的 Agent 请求，其时间构成中占据主导的是等待：调用 LLM 推理接口（单次数百毫秒至数十秒）、向量库检索、工具调用（HTTP、数据库、搜索引擎）、多轮对话中的编排往返。真正的 CPU 计算通常只占请求耗时的很小比例（JSON 序列化、提示词拼装、轻量后处理）。因此异步模型在此处高度契合：等待期让出循环，单进程即可维持数千并发连接。

收益边界同样清晰：

1. **流式输出（SSE / WebSocket）会长期占用连接与 Task**，此时并发上限由内存与下游速率决定，而非事件循环本身。异步不消除这类占用的资源成本。
2. **本地推理是 CPU 密集**，必须用线程池或进程池卸载，或拆到独立推理服务，否则会冻结整个 worker。
3. **工具调用并非全部可异步化**。只有同步实现的 SDK 需要 `to_thread` 卸载，其并发度受线程池容量约束。
4. **同步客户端是异步收益的漏点**。链路中任一环节使用阻塞客户端，该环节的等待便无法让出循环，整条链路的并发能力被这一环决定。
5. **异步不提供并行**。官方定义为协作式调度，同一时刻只有一个 Task 在运行；真正的多核利用必须依赖多进程，见 [[06-concurrency-models]]。

## 9. 自测问题

1. "异步"的两种含义分别是什么？为什么 `async def` 不自动等于异步执行？
2. 让出点出现在什么位置？由此推出的两条推论是什么？
3. 顺序 `await` 两个协程是并发还是串行？如何实现并发？
4. 在 `async def` 中调用 `requests.get()` 会造成多大范围的影响？
5. FastAPI 中 `def` 与 `async def` 的处理差异是什么？什么情况下应该用 `def`？
6. 跨 `await` 的读—改—写为什么不安全？
7. Agent 服务中，异步收益的五个边界分别是什么？

## 10. 参考来源

1. Python — Coroutines and Tasks，https://docs.python.org/3/library/asyncio-task.html
2. Python — Developing with asyncio，https://docs.python.org/3/library/asyncio-dev.html
3. Python — Glossary: global interpreter lock，https://docs.python.org/3/glossary.html
4. FastAPI — Concurrency and async / await，https://fastapi.tiangolo.com/async
5. MDN — JavaScript execution model，https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Execution_model
