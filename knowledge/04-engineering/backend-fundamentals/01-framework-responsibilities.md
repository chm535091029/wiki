---
title: 服务端框架的职责
category: engineering
parent: 后端服务基础
level: 理解
updated: 2026-09-04
---

# 服务端框架的职责

## 1. 概念定义

服务端框架是介于**传输层实现**与**业务代码**之间的一层约定。

需要先把边界划清楚：框架不负责接收 TCP 连接、不负责解析 HTTP 报文，那是 Uvicorn、Nginx、Tomcat 这类服务器与容器的职责；框架也不负责业务判断，那是开发者写的处理函数的职责。框架负责的是中间这一段——把一次已经解析好的 HTTP 请求，按照可预测的方式交给某段业务代码，并把业务代码的输出变成合法的 HTTP 响应。

这一层的价值不在于"少写几行代码"，而在于**把横切关注点统一收口**。鉴权、日志、限流、错误处理、序列化契约这些事，不必在每个接口里重复实现，也不依赖开发者的自觉。缺少这一层，系统的行为一致性就只能靠代码评审来保证。

### 1.1 五层分层关系

理解框架的位置，最有效的办法是把它放到完整分层里看：

```
应用代码（业务 Agent 逻辑、路由处理函数）
      ↓  依赖注入、参数校验、序列化、OpenAPI
框架（FastAPI，本身是 Starlette 的子类）
      ↓  路由匹配、中间件栈、Request/Response 封装、lifespan
协议实现（ASGI：scope / receive / send 三参数调用约定）
      ↓  调用约定
服务器（Uvicorn：socket 终止、HTTP/1.1 与 WebSocket 解析、事件循环）
      ↓  系统调用
操作系统（epoll / IOCP / kqueue）
```

| 层 | 负责 | 不负责 |
|----|------|--------|
| 服务器（Uvicorn） | 监听端口、解析报文、构建 scope、驱动事件循环、进程管理 | 路由、校验、依赖注入 |
| 协议（ASGI） | 定义 scope 与事件格式、调用签名 | 任何具体协议实现 |
| 框架（Starlette / FastAPI） | 路由、中间件、请求与响应封装、异常处理、lifespan | 网络 I/O |
| 应用 | 业务 | 以上全部 |

一个有助于记忆的判据：**能否只用 `app(scope, receive, send)` 三个参数把整个应用跑起来**——能跑起来的那层是服务器，跑不起来的那层是框架。

### 1.2 常见误区

| 误区                                    | 更正与依据                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| "Uvicorn 是我的 Web 框架"                  | Uvicorn README 第一句即为"Uvicorn is an ASGI web server implementation for Python"。它支持 HTTP/1.1 与 WebSocket，没有路由、没有依赖注入、没有数据校验 |
| "FastAPI 自带服务器，直接 `python app.py` 就行" | FastAPI 官方 Features 页原文：`FastAPI` is actually a sub-class of `Starlette`。它是框架，必须由 Uvicorn、Daphne、Hypercorn 或 Granian 承载   |
| "ASGI 只是 WSGI 的异步版"                   | ASGI 是"连接 scope + 事件流"的通用协议承载模型，HTTP 只是其中一份子规范，另有 websocket 与 lifespan 子规范                                                |

## 2. 框架之下的协议层：WSGI 与 ASGI

这一节是理解框架能力边界的关键。Agent 服务最典型的三种交互形态（流式、双向、带重资源初始化）全部落在 ASGI 的能力边界内，而全部落在 WSGI 的能力边界外。

### 2.1 WSGI（PEP 3333）

WSGI 不是库、不是服务器，而是**服务器侧与应用侧之间的调用约定**。现行版本 1.0.1 由 PEP 3333 定义。

调用约定：

| 元素 | 规范约束 |
|------|----------|
| `environ` | 必须是内置 `dict`（不允许子类），含 CGI 风格变量，应用可自由修改 |
| `start_response` | 形如 `start_response(status, response_headers, exc_info=None)` 的可调用对象，返回 `write(body_data)` |
| 返回值 | 产生零或多个 **bytestring** 的可迭代对象 |
| 传输语义 | 服务器必须无缓冲传输，逐块发完再取下一块——**缓冲由应用自己负责** |
| 资源释放 | 返回的可迭代对象若有 `close()`，无论是否正常结束，服务器都必须调用 |
| 关键时序 | 应用必须在产出第一个 body 字节前调用 `start_response()` |

**为什么它是同步阻塞模型**：整个契约里没有 `await`、没有事件循环、没有回调。服务器的一个 worker 调用应用 → 应用同步执行完毕 → 返回可迭代对象 → worker 迭代发送。并发只能靠 worker 数量堆出来。**一次调用严格对应一次请求**，应用没有机会在响应之后再收到任何来自服务器的通知。

### 2.2 WSGI 的根本局限

ASGI 官方 Introduction 的表述最为权威：

> WSGI applications are a single, synchronous callable that takes a request and returns a response; this doesn't allow for long-lived connections, like you get with long-poll HTTP or WebSocket connections. Even if we made this callable asynchronous, it still only has a single path to provide a request, so protocols that have multiple incoming events (like receiving WebSocket frames) can't trigger this.

| 特性        | 能否承载          | 原因                                                            |
| --------- | ------------- | ------------------------------------------------------------- |
| WebSocket | 否             | 握手后连接转为长生命周期双向帧流；WSGI 的可调用对象只有"一次传入请求"的单条路径                   |
| 长轮询 / SSE | 理论可勉强实现，实践不可用 | 可返回生成器慢慢 yield，但会长期独占一个 worker；且 WSGI 没有标准手段通知"客户端已断开"，清理无处挂钩 |
| HTTP/2    | 否             | 多路复用下一条连接承载多个并发流，与"一次调用 = 一次请求"的模型结构冲突                        |
| 连接级生命周期钩子 | 否             | 规范只定义请求级调用，没有进程/循环级的启动与关闭协议                                   |

### 2.3 ASGI 的设计

ASGI（Asynchronous Server Gateway Interface）由 Django 生态提出，官方定位是 WSGI 的异步继任者。Uvicorn 官方 README 给出了历史侧证：Daphne 是第一个 ASGI 服务器实现，最初为 Django Channels 而开发。

**可调用对象的演进**：ASGI 2.0（2017-11）采用双层可调用，先同步调用 `application(scope)`，再 `await` 返回的实例；**3.0（2019-03）改为单调用**：

```
coroutine application(scope, receive, send)
```

- `scope`：连接元信息 dict，至少含 `type` 键
- `receive`：awaitable，产出下一个事件 dict
- `send`：awaitable，接收一个事件 dict

与 WSGI 最本质的差别是**事件的引入**：协议被分解为一系列应用要 receive 并响应的事件，以及可以 send 回去的事件。每个事件都是带顶层 `type` 键的 dict，且只允许包含可序列化类型（字节串、字符串、int64、double、list、dict、bool、None）——**这个约束使事件可以跨网络、跨进程传递**，这是"协议隧道"思想的技术前提。

### 2.4 三类协议与 scope 生命周期

| 协议 | scope 生命周期 | 典型事件 |
|------|---------------|----------|
| `http` | 仅一个请求 | receive：`http.request`、`http.disconnect`；send：`http.response.start`、`http.response.body` |
| `websocket` | **与 socket 连接同长** | `websocket.connect` / `receive` / `send` / `disconnect` |
| `lifespan` | **与事件循环同长** | receive：`lifespan.startup`、`lifespan.shutdown`；send：`*.complete` / `*.failed` |

HTTP 响应周期的两个要点：`http.response.body` 带 `more_body` 标志，服务器必须在 `send()` 返回前把数据 flush 进发送缓冲区；响应完成后应用再 `receive()` 会拿到 `http.disconnect`，规范明确说它"mainly useful for long-polling"。对已关闭连接 `send()` 应抛出 `OSError` 的服务器特定子类。

lifespan 协议的三个关键语义：服务器**必须**等到 `lifespan.startup.complete` 才开始接受连接；应用要阻止服务器启动则回 `lifespan.startup.failed`；`scope["state"]` 是一个由应用完全掌控、由服务器**浅拷贝进每个后续请求 scope** 的命名空间——官方明确其目的是"确保应用始终访问与当前事件循环对应的数据库连接（或类似对象），无需使用 context variables 或全局可变状态"。

### 2.5 为什么 ASGI 不止是"WSGI 的异步版"

ASGI 主规范只固定**服务器与应用之间的通信接口**，而**每种协议各自有一份消息格式子规范**。二者叠加，等价于 WSGI 中 `environ` 字典键的规范，但关键设计是把"协议"抽象为 **连接 scope + 事件消息流**，而不是"请求 + 响应"。

由此得到三个推论：

1. 只要能为某种协议定义 scope 存活期与事件格式，就能把它挂到同一个应用接口上——WebSocket 与 lifespan 就是这样被纳入的，而不是靠给 HTTP 打补丁。
2. 应用若要拒绝不认识的协议，必须**主动抛异常**；否则服务器会误以为你支持（官方特别警告 lifespan 场景下服务器会一直等待启动完成）。
3. ASGI 被设计为 WSGI 的**超集**，有明确的双向转换途径：`asgiref.wsgi.WsgiToAsgi` 把 WSGI 应用包成 ASGI 应用，内部用线程池承载同步代码。

### 2.6 为什么这个分层对 Agent 服务重要

| Agent 服务能力 | 依赖的 ASGI 机制 | 在 WSGI 下的处境 |
|---------------|-----------------|-----------------|
| 流式响应（SSE / 逐 token 输出） | `http.response.body` + `more_body` 循环发送；`StreamingResponse` 直接建立在此之上 | 只能返回生成器，独占 worker，无 disconnect 通知 |
| WebSocket（双向工具调用、中间过程推送） | `websocket` scope 与连接同长，可反复 receive/send | 结构上不可能 |
| lifespan 加载模型 / 向量库 / 连接池 | `lifespan.startup` 在**事件循环内**执行，`scope["state"]` 浅拷贝进每个请求 | 只能在模块导入期加载，无法保证与请求同一事件循环 |
| 客户端断开感知 | `http.disconnect` 与已关闭连接 `send()` 抛 `OSError` 子类 | 无标准机制，LLM 长请求会白跑到底 |

最后一条在实际中的代价很直接：客户端关掉浏览器后，服务端若未感知，会继续向模型供应商付费生成完整回答。

## 3. 逐项职责

### 3.1 路由

框架维护一张"方法 + 路径模式 → 处理函数"的映射表，请求到达时做匹配。

关键实现细节：**Starlette / FastAPI 的路由是一条有序链表的线性匹配，不是最精确匹配**。FastAPI 官方文档明确指出路径操作按声明顺序求值，因此 `/users/me` 必须声明在 `/users/{user_id}` 之前，否则前者会被后者吞掉，被当成 `user_id="me"`。同一路径重复声明时，先声明者永久生效，后者静默失效。

这个细节在调试时的表现是：接口存在、路径也对，但永远返回另一个接口的结果，且没有任何报错。

但这个结论**只对部分框架成立**，见下表。

#### 3.1.1 Starlette / FastAPI 的实现

核心函数 `compile_path(path)` 返回三元组 `(regex, format, {param_name: convertor})`：用 `PARAM_REGEX` 扫描 `{name:converter}` 占位符，把字面量段 `re.escape` 后拼接，参数段替换为 `(?P<name>converter.regex)`，最终 `re.compile` 成 `^...$`。内置转换器为 `str`(`[^/]+`)、`int`(`[0-9]+`)、`float`、`uuid`、`path`(`.*`)。

匹配阶段：`Router` 遍历自身 `routes` 列表，逐个调用 `route.matches(scope)`，返回枚举 `Match.NONE / PARTIAL / FULL`。`PARTIAL` 表示路径命中但方法不匹配，用于返回 405（带正确 `Allow` 头）而非 404。全表走完无命中时，若开启 `redirect_slashes` 则尝试补/删尾部斜杠后重定向。

唯一的启动期强校验是重复参数名（`compile_path` 抛 `ValueError: Duplicated param name ...`）。

#### 3.1.2 各框架路由匹配算法对比

| 方案                  | 匹配复杂度                      | 与路由条数关系  | 顺序敏感性               |
| ------------------- | -------------------------- | -------- | ------------------- |
| Starlette / FastAPI | O(n)（正则逐个尝试）               | 线性相关     | **强敏感**             |
| Werkzeug（2.2 前正则表）  | O(n)                       | 线性相关     | 敏感                  |
| Werkzeug（2.2+ 状态机）  | 亚线性（公共前缀被合并）               | 弱相关      | 仍保留规则顺序语义           |
| httprouter / Gin    | O(k)（k 为路径长度）              | 基本无关     | **结构性冲突直接报错，无所谓顺序** |
| Spring PathPattern  | 模式预解析，逐 `PathElement` 链式匹配 | 与注册条数弱相关 | 由特异性比较器决定，不依赖声明顺序   |

**Werkzeug 的演进**：2.2 之前是有序正则表（与 Starlette 同类）。2.2 起换为状态机算法——作者 PGJones 在博客中说明，曾尝试 radix tree 但无法支持 Werkzeug 的全部特性（host/subdomain 匹配、严格尾斜杠、合并斜杠、默认参数、重定向、后通配符匹配），因此改用状态机；加速幅度随路由表规模增大而增大，测试中最高约 5 倍，简单路由表的微基准几乎无变化。

**httprouter / Gin 的 radix tree**：路由依赖一棵大量利用公共前缀的紧凑前缀树，**每个请求方法各自一棵树**；同层子节点按优先级（子树中注册的 handler 数量）排序。三个工程特性：匹配与分发过程产生零字节垃圾；复杂度与路径长度相关而非路由条数；catch-all 参数必须位于模式末尾。

**Spring 的两代匹配器**：

| 维度 | AntPathMatcher | PathPattern |
|------|---------------|-------------|
| 处理方式 | String 模式匹配 String 路径 | **预解析**的模式，匹配同样预解析为 `PathContainer` 的路径 |
| 效率 | 较低 | 高效；能更有效处理编码与路径参数 |
| 归属 | 最初方案，也用于类路径/文件系统等资源选择 | 专为 Web 设计 |
| 适用 | 可回退使用 | WebFlux **唯一**选择；Spring MVC 自 5.3 起可启用，**6.0 起默认** |
| 语法 | Ant 风格 | 与 AntPathMatcher 相同，另支持捕获模式 `{*spring}` |
| 限制 | 无 | `**` **只允许出现在模式末尾**，以消除特异性比较时的歧义 |

PathPattern 的性能优势来自"解析与匹配分离"：模式在注册期解析为对象，请求期只对预解析的路径做匹配，避免重复的字符串切分与分配。

#### 3.1.3 由此推出的 API 设计规范

1. **在 radix tree 框架中，路由顺序无关**——匹配由树结构唯一决定，两个模式若结构冲突（如 `/user/:id` 与 `/user/new`），注册时即失败。因此 API 必须设计成**结构上无歧义**的。
2. **在 Starlette / Flask 中，顺序敏感**——`/users/{user_id}` 若声明在 `/users/me` 之前，后者永远不会命中且**没有任何报错**。规范应强制：静态路径段优先声明，参数化路径段后置；这类对偶必须在代码评审中显式检查。

#### 3.1.4 路由冲突检测矩阵

| 框架 | 启动期报错的冲突 | 静默通过的冲突 |
|------|----------------|---------------|
| Starlette / FastAPI | 同一路径内重复参数名 → `ValueError` | 路径遮蔽（参数路由先于静态路由声明）、同路径同方法重复注册 |
| Flask / Werkzeug | 同一 endpoint 名映射到不同 view 函数 → `AssertionError: View function mapping is overwriting an existing endpoint function` | 路径遮蔽；`RequestRedirect` 类"伪冲突"（尾斜杠、连续斜杠、defaults）被自动规范化 |
| httprouter | 注册冲突路由时 **panic** | — |
| Spring MVC | Ambiguous mapping 在启动时抛 `IllegalStateException`（未找到官方依据，为工程推演） | — |

### 3.2 参数解析与校验

把 path、query、header、cookie、body 中的字符串取出，转换为目标类型，拒绝非法值。

现代框架的趋势是把类型声明本身作为校验规约。这一职责的意义在于**契约前置**：非法请求不应进入业务逻辑。校验缺失的直接后果不是报错，而是脏数据直达业务层，错误在更深处爆发，排查成本成倍上升。

#### 3.2.1 Pydantic v2 的架构

| 层 | 职责 |
|----|------|
| Python 层（`pydantic`） | 读取类型注解 → 构建 `core_schema` → 生成 JSON Schema；不常用类型用 Python 验证器函数实现 |
| Rust 层（`pydantic-core`，基于 pyo3） | 执行真正的校验与序列化；提供 `SchemaValidator` / `SchemaSerializer`；可直接解析 JSON，避免"先转 Python 对象再校验"的开销 |

官方博客明确给出了用 Rust 重写内核的三条动机，其中第二条尤其值得注意：**Rust 无栈开销，使得 pydantic-core 能被实现为一棵互相调用的小验证器树**（a tree of small validators which call each other），既易读易扩展又不损性能。官方基准称 V2 比 V1 快 4 到 50 倍，对含常见字段的代表性模型约 17 倍。

一个重要的架构变化：V1 的校验核心必须是 model，V2 操作的是**验证器树**，树根不要求是 model，因此校验单个 str、TypedDict、函数参数与校验整个 model 代价相当——这正是 FastAPI 能廉价地为 query/header/body 参数逐个校验的原因。

#### 3.2.2 宽松模式与严格模式

**默认是 lax（宽松）模式**。官方原则：若输入在该字段类型中有**唯一且直观的表示**，且**转换过程中无数据丢失**，则转换；否则报校验错误。唯一例外是 **str 字段**——几乎所有数据都有直观的字符串表示，故特设规则：**只有 `str`、`bytes`、`bytearray` 可作为 str 字段的输入**。

strict 可在三个层级启用，且字段级可覆盖配置级：

| 层级 | 写法 |
|------|------|
| 调用级 | `MyModel.model_validate(data, strict=True)` |
| 字段级 | `age: int = Field(strict=True)` / `Annotated[int, Strict()]` / `StrictInt` |
| 配置级 | `model_config = ConfigDict(strict=True)` |

Agent 场景高频坑（依据官方转换表）：

| 字段类型 | 输入 | lax 结果 | strict 结果 |
|---------|------|---------|------------|
| `int` | `"123"` | 转为 `123` | 报错 `int_type` |
| `int` | `123.0` | 转为 `123` | 报错 |
| `int` | `123.1` | 报错 `int_from_float` | 报错 |
| `bool` | `"true"` / `"yes"` / `"on"`（及其否定形式） | 转为 `True` / `False` | 报错 `bool_type` |
| `bool` | `"test"` | 报错 `bool_parsing` | 报错 |
| `str` | `123` | **报错 `string_type`** | 报错 |

最后一行是解析 LLM 输出时最常踩的坑：LLM 经常把数字塞进本该是字符串的字段（如 `id: str` 收到 `1001`），lax 模式下**不会**帮你转，直接 422。

另一个关键细节：**strict 模式在 JSON 输入下更宽松**。官方说明：严格模式下日期时间类型仍接受字符串，因为 JSON 本身没有 datetime 类型——`TypeAdapter(date).validate_json('"2000-01-01"', strict=True)` 成功，而 `validate_python('2000-01-01', strict=True)` 报错。

#### 3.2.3 校验错误的结构

`ValidationError.errors()` 返回 `ErrorDetails` 列表：

| 字段 | 含义 |
|------|------|
| `loc` | 元组，标识错误发生在 **schema 中的位置**，如 `('body', 'size')` |
| `msg` | 人可读的错误描述 |
| `type` | **机器可读**错误码，如 `int_parsing`、`missing`、`string_too_long` |
| `input` | 导致该错误的原始输入值 |
| `url` | 指向错误文档的链接，形如 `https://errors.pydantic.dev/2/v/<type>` |
| `ctx` | 可选，渲染错误消息所需的上下文变量，也便于透传自定义错误数据 |

FastAPI 把它包成 422 响应体：

```json
{"detail": [{"loc": ["body", "size"], "msg": "...", "type": "..."}]}
```

`loc` 的首元素是**参数位置**（`body` / `query` / `path` / `header` / `cookie`），其后是字段路径。

需要注意：FastAPI 官方 Handling Errors 文档示例中的 `type` 值仍是 V1 风格（`type_error.integer`），V2 下对应 `int_parsing` / `int_type`，引用文档示例时应以 Pydantic 官方错误列表为准。

#### 3.2.4 常用校验器

| 类别 | 写法 | 对应错误 `type` |
|------|------|----------------|
| 数值约束 | `Field(gt=, ge=, lt=, le=, multiple_of=)` | `greater_than` / `multiple_of` 等 |
| 长度约束 | `Field(min_length=, max_length=)` | `string_too_long` / `too_short` |
| 模式匹配 | `Field(pattern=...)` | `string_pattern_mismatch` |
| Decimal 精度 | `Field(max_digits=, decimal_places=)` | `decimal_max_digits` |
| 严格性 | `Field(strict=True)` | `*_type` 系列 |
| 额外字段 | `ConfigDict(extra='forbid')` | `extra_forbidden` |
| 字段级自定义 | `@field_validator('x')`（mode 可为 before/after/wrap） | `value_error` |
| 模型级自定义 | `@model_validator(mode=...)` | 同上 |
| 循环引用 | — | `recursion_loop` |

需要注意：`Field` 的 `description`、`title`、`examples`、`json_schema_extra` **只影响 JSON Schema，不影响校验**。

### 3.3 序列化与反序列化

入站方向是 JSON 或表单转成语言对象，出站方向是语言对象转成 JSON。

难点不在转换本身，而在两处：**类型不可逆**（datetime、Decimal、UUID、字节流在 JSON 中没有原生对应）与**对象图边界**（ORM 实体的关联字段会无限展开，双向关联直接序列化必然触发循环引用）。

工程上的标准解法是显式声明输出模型，用 ID 引用替代嵌套对象，把"序列化什么"变成显式的契约而非默认行为。

#### 3.3.1 三种调用的关系

| 调用 | 输出 | 说明 |
|------|------|------|
| `model_dump()` | Python `dict` | 默认 `mode='python'`，**可能含非 JSON 类型** |
| `model_dump(mode='json')` | Python `dict` | 只含 JSON 兼容类型（`tuple` → `list`） |
| `model_dump_json()` | JSON **字符串** | 直接序列化，不做中间 dict |

**为什么 datetime 在两种模式下表现不同**：Python 模式返回 `datetime` 实例本身，JSON 模式转 ISO 8601 字符串。这条差异对 Agent 服务很实际——把 `model_dump()` 的结果直接喂给 `json.dumps()` 会失败，而 `model_dump(mode='json')` 的结果可以。

#### 3.3.2 类型处理表

| 类型 | `mode='python'` | `mode='json'` |
|------|----------------|---------------|
| `datetime` / `date` / `time` | 原样返回对象 | ISO 8601 **字符串** |
| `UUID` | 原样返回 `UUID` | **字符串** |
| `Decimal` | 原样返回 `Decimal` | 默认**字符串**；可用 `PlainSerializer(float, when_used='json')` 改成数字 |
| `Enum` / `IntEnum` | 默认返回**枚举成员**；配 `use_enum_values=True` 则校验期即取 `value` | 使用成员的 **`value`** |
| `set` / `frozenset` | 原样返回 | **数组** |
| `bytes` | 原样返回 `bytes` | 官方该页未设 Serialization 小节，未给出 JSON 表示的明确条款（业界普遍为 base64 字符串，此点未找到官方依据） |

#### 3.3.3 序列化期的"尽最大努力"哲学

序列化警告与错误的控制由 `warnings` 参数统一管辖（默认 `True`）：

| `warnings` 取值 | 行为 |
|----------------|------|
| `False` / `'none'` | 忽略序列化错误 |
| `True` / `'warn'`（默认） | 记录日志，表现为 `UserWarning: Pydantic serializer warnings: ...` |
| `'error'` | 抛出 `PydanticSerializationError` |

典型触发场景：字段被赋了与注解不符的值（如 `point.x = 'a'` 后 `model_dump()`）。官方解释得很清楚——`PydanticSerializationUnexpectedValue` "is often caught and coerced into a warning, as pydantic-core generally makes a **best attempt** at serializing values, in contrast with validation where errors are eagerly raised"。

**校验期立即抛错，序列化期尽最大努力并降级为警告**——这个不对称是 Pydantic 的设计哲学，也是生产环境静默产生脏数据的常见入口。工程上建议在测试环境把 `warnings` 设为 `'error'`，把静默问题提前暴露。

#### 3.3.4 `response_model` 的作用与陷阱

FastAPI 官方列举的四个作用：**校验**返回数据、为 OpenAPI 生成 JSON Schema、用 Pydantic（Rust 内核）**序列化**、以及最关键的——**裁剪与过滤输出字段**（官方强调这对安全尤其重要，例：入参模型含 `password`，出参模型不含，则密码不会出现在响应里）。

三个使用要点：

- `response_model` **优先于**函数返回类型注解；`response_model=None` 可完全关闭。
- `response_model_exclude_unset=True` 只返回显式设置过的字段，另有 `exclude_defaults` / `exclude_none` / `include` / `exclude`。
- 官方明确提醒：`include` / `exclude` / `by_alias` **不会改变 OpenAPI 中生成的 schema**，它仍是完整模型的 schema——文档与真实响应会不一致。

**与流式响应的冲突**：当返回类型注解是 `Response` 或其子类时（`JSONResponse`、`RedirectResponse`、`StreamingResponse`），FastAPI 会直接放行、不做 response_model 处理；若注解是 `Response` 与其他类型的**联合**（如 `Response | dict`），由于不是合法 Pydantic 类型，创建响应模型时会直接失败。因此流式接口应把返回类型注解为 `StreamingResponse`，而不是声明 `response_model`。

深层原因是语义冲突（此点为工程推演）：response_model 要求先拿到完整的返回值对象、做二次校验与字段裁剪、再一次性序列化，这必然要求把整个响应体物化在内存中，从而破坏流式语义。

### 3.4 中间件

见 [[03-middleware]]。

### 3.5 异常处理

框架提供从业务异常到 HTTP 语义的统一映射。这一节的机理比"注册一个 handler"要复杂得多，理解 Starlette 的中间件栈结构是排查"500 但日志无异常"这类问题的前提。

#### 3.5.1 三层中间件栈

| 层 | 位置 | 职责 |
|----|------|------|
| `ServerErrorMiddleware` | 最外层 | 捕获整个栈内未处理异常，生成 500 响应 |
| 用户添加的中间件 | 中间 | 认证、CORS、日志、限流 |
| `ExceptionMiddleware` | 最内层 | 把"已处理异常"转换为 HTTP 响应 |
| Router / Endpoints | 最内 | 路由与端点 |

关键概念是区分**已处理异常（handled exception）**与**错误（error）**：前者（如 `HTTPException`）被转换为响应，该响应会**再沿标准中间件栈向外穿过**；后者必须作为异常**穿透整个中间件栈**直达服务器，日志/观测类中间件在记录后必须重新抛出。

#### 3.5.2 500 错误：生成响应后仍然 re-raise

`ServerErrorMiddleware` 的逻辑为：捕获异常 → 若 `debug` 返回 traceback 响应；否则返回 `PlainTextResponse("Internal Server Error", 500)` → 仅当响应尚未开始（`not response_started`）时才发送 → 最后**无条件 `raise exc`**。

源码注释说明了设计意图：

```python
# We always continue to raise the exception.
# This allows servers to log the error, or allows test clients
# to optionally raise the error within the test case.
```

需要更正一处常见表述：默认 500 响应**并非"没有响应体"**，而是有一个不含任何细节的纯文本响应体 `Internal Server Error`。"无响应体"只在响应已开始发送（流式已发出首块）时才成立——此时连这个响应都会被丢弃。re-raise 的目的是让 ASGI 服务器与观测系统能看到完整异常对象，而客户端只看到一个无害的 500。

#### 3.5.3 `ExceptionMiddleware` 的查找流程

内部维护两张表：`_status_handlers`（键为 int 状态码）与 `_exception_handlers`（键为异常类，默认预置 `HTTPException`、`WebSocketException`）。查找流程：

1. 若异常是 `HTTPException`，先查 `_status_handlers[exc.status_code]`；
2. 否则沿 `type(exc).__mro__` 逐级查 `_exception_handlers`；
3. 均未命中则 `raise exc`，冒泡至 `ServerErrorMiddleware` 变成 500；
4. 若 `response_started` 已为真，则抛 `RuntimeError("Caught handled exception, but response already started.")`。

#### 3.5.4 自定义 handler 挂在哪一层

`build_middleware_stack` 会对 `exception_handlers` 做分流：

```python
for key, value in self.exception_handlers.items():
    if key in (500, Exception):
        error_handler = value            # → ServerErrorMiddleware
    else:
        exception_handlers[key] = value  # → ExceptionMiddleware
```

即：注册 `500` 或 `Exception` 的处理器挂到**最外层**；注册 `RequestValidationError`、`StarletteHTTPException` 等**具体类**的处理器挂到**最内层**。

由此得到一个反直觉但重要的结论：**`ExceptionMiddleware` 位于用户中间件之内，恰恰意味着它捕获不到用户中间件自身抛出的异常**。异常传播方向是由内向外，用户中间件在它外层，其异常只会向上冒泡到 `ServerErrorMiddleware`，得到 500。

它放在最内层的真实理由是两条：让路由/端点抛出的"已处理异常"尽早转成响应，使该响应随后能完整穿过用户中间件栈（CORS、会话等中间件仍能对其加工）；保证真正的错误穿透整个栈，被用户的错误日志中间件看到。

#### 3.5.5 `debug=True` 与生产禁用

`debug=True` 时 `ServerErrorMiddleware` 按 `Accept` 返回 HTML 或纯文本 traceback，源码中使用 `traceback.TracebackException.from_exception(exc, capture_locals=True)`，**局部变量值会被渲染进 HTML**。这会泄漏源码路径、代码片段与变量内容，生产环境必须禁用。

#### 3.5.6 生产实践

| 目标 | 做法 |
|------|------|
| 避免校验错误泄漏内部结构 | 覆盖 `RequestValidationError` 处理器，只回传 `loc` + `msg`，不回传 `body`、文件名、行号 |
| 复用默认行为 | 从 `fastapi.exception_handlers` 导入 `http_exception_handler` / `request_validation_exception_handler`，先打日志再 `await` 默认处理器 |
| 统一记录 traceback | 注册 `Exception` 处理器（落到 `ServerErrorMiddleware`），或写用户中间件 `try/except` 记录后 re-raise |
| 区分业务/系统异常 | 业务异常继承 Starlette `HTTPException`，走 `ExceptionMiddleware`；其余落到 500 |

#### 3.5.7 关键陷阱

- `ExceptionMiddleware` 只能处理**其内层**抛出的异常；用户中间件与 ASGI 层抛出的异常它捕获不到，只能得到 500。
- **响应一旦开始发送就无法改写**：流式响应中途出错，异常处理器生成的响应会被丢弃。
- **后台任务内抛异常由 `Exception` 处理器接管，但此时响应已发出**，该响应同样被丢弃——后台任务的失败不会反馈给客户端。

### 3.6 生命周期管理

`lifespan` 是 `contextlib.asynccontextmanager` 装饰的异步生成器：`yield` 之前为启动，之后为关闭。Starlette 文档明确："Starlette will not start serving any incoming requests until the lifespan has been run"；拆卸在全部连接关闭且进程内后台任务完成后执行。

#### 3.6.1 为什么重资源必须在 lifespan 加载

| 加载时机 | 问题 |
|---------|------|
| 模块导入期 | 跑一个无关的单测也要等模型加载完；导入与事件循环解耦，资源可能绑定到错误的循环 |
| 首次请求懒加载 | 首请求延迟尖刺；并发首请求存在重复初始化竞态（此点为工程推演） |
| `lifespan` | 启动一次、与请求共用同一事件循环 |

ASGI 规范对此有明确表述：lifespan 与请求运行在同一个事件循环，确保连接池等对象不跨事件循环移动或共享。

**启动失败则服务器不启动**：收到 `lifespan.startup.failed` 的服务器应记录 message 并退出；服务器在收到 `lifespan.startup.complete` 前不得处理连接。这一条对 Agent 服务是好事——模型加载失败应当让服务起不来，而不是带着一个坏掉的模型接流量。

#### 3.6.2 state 的三种形态

| 对象 | 生命周期 | 可见范围 |
|------|---------|---------|
| `app.state` | 应用实例级，进程级 | 全应用、跨请求共享 |
| lifespan yield 的 dict | 一次 lifespan | 被 `scope["state"].update(...)` 合并 |
| `scope["state"]` | 事件循环级，由服务器管理 | 服务器保证其**浅拷贝**传入后续每个请求 |
| `request.state` | 单次请求 | 读取该请求 scope 的 state |

要点：请求收到的 state 是 lifespan state 的**浅拷贝**；该命名空间的存在正是为了让应用不必依赖 context variable 或全局可变状态。若服务器不支持 `state` 而 lifespan 又 yield 了值，Starlette 直接抛 `RuntimeError`。

### 3.7 后台任务

`BackgroundTasks` 来自 `starlette.background`，**仅在响应发送之后运行**；多个任务**顺序执行，任一抛异常则后续任务不再执行**。

| 适用 | 不适用 |
|------|--------|
| 发通知邮件、写审计日志、轻量善后 | 长耗时任务、需要重试的任务、必须保证执行的任务 |
| 需要访问本进程内存/变量的短任务 | 需要跨进程横向扩展的计算（官方建议改用 Celery 等队列） |

"进程被杀即丢失、无重试、无持久化"属于实现语义的必然推论。**Agent 的长任务绝不能用 BackgroundTasks**，应交给任务队列 + 独立 worker，接口侧返回任务 ID 供轮询或回调。

#### 3.7.1 与依赖 yield 清理逻辑的执行顺序

`Depends(scope="request")`（默认）的退出代码在**响应发送之后**执行；`scope="function"` 则在路径操作函数结束之后、响应发送之前执行。

自 FastAPI 0.106.0 起，**退出代码先于后台任务完成**——此前退出代码在后台任务之后才运行，目的是让后台任务复用依赖 yield 出的资源。现在官方明确要求：后台任务应在自身内部创建资源（例如新建数据库会话），只接收不依赖这些资源的数据（传 ID 而非 ORM 对象）。

对流式响应的额外提醒：0.118.0 起退出代码在响应发送完毕后才执行，因此 `StreamingResponse` 的生成器**可以**使用依赖 yield 出的会话（此前会被提前关闭）。

### 3.8 契约自动化：OpenAPI 与 JSON Schema

FastAPI 从类型注解生成 OpenAPI：路由表 → `fastapi.openapi.utils.get_openapi(...)` → 路径项与 Pydantic 模型转 JSON Schema → 缓存到 `.openapi_schema` → `/openapi.json` 路由返回该 JSON。

#### 3.8.1 三个产物端点与生产暴露

| 端点 | 参数 | 关闭方式 |
|------|------|---------|
| `/openapi.json` | `openapi_url` | 设为 `None` 会**连带禁用** docs 与 redoc |
| `/docs`（Swagger UI） | `docs_url` | 设为 `None` |
| `/redoc`（ReDoc） | `redoc_url` | 设为 `None` |

官方文档仅说明如何关闭，**未给出安全建议**。是否关闭属于风险评估：暴露即等于公开全部接口签名与模型结构，建议内网/鉴权后暴露或直接关闭。

#### 3.8.2 `operation_id`

OpenAPI 要求全文档唯一。FastAPI 默认用"函数名 + 路径 + HTTP 方法"组合以保证唯一，因此生成的客户端方法名形如 `createItemItemsPost`。可通过 `generate_unique_id_function` 定制，此时**唯一性由开发者自行保证**，建议纳入 CI 校验。

#### 3.8.3 定制能力

`title`、`summary`、`description`、`version`、`terms_of_service`、`contact`、`license_info`、`openapi_tags`（顺序决定 UI 展示顺序）、`servers`（多环境切换）、`separate_input_output_schemas`（默认 `True`，为输入与输出生成不同 Schema，使"可选输入 / 必有输出"更精确）。`securitySchemes` 等深层定制通过覆盖 `app.openapi()` 调用 `get_openapi()` 后修改字典实现。

#### 3.8.4 JSON Schema 的两种模式

`model_json_schema()` 返回描述模型结构的 dict（与 `model_dump_json()` 序列化实例数据是两类操作，官方文档专门提醒不要混淆）。生成结果符合 **JSON Schema Draft 2020-12** 与 **OpenAPI v3.1.0**。

| 参数 | 作用 |
|------|------|
| `mode='validation'`（默认） | 描述**可接受的输入**形态 |
| `mode='serialization'` | 描述**输出**形态 |

mode 差异的实际影响：`Decimal` 字段在 validation 模式下是 `anyOf[number, string]`（数字与数字字符串都收），在 serialization 模式下只有 `string`。

**对 Agent 服务的直接结论**：喂给 LLM 做 function calling 的 `parameters` 应当用 **validation 模式**（表达"你可以传什么"），描述工具返回值或给客户端的响应契约应当用 **serialization 模式**（表达"你会收到什么"）。

一个官方提醒的坑：定长元组 `Tuple[str, int]` 在 JSON Schema 中生成 `items` **数组**形式，这在 JSON Schema 中合法但**在 OpenAPI 中不合法**，用于 OpenAPI 时应避免该声明。

## 4. 主流框架定位对比

| 维度 | FastAPI | Django | Flask | Express | Spring Boot | Gin |
|------|---------|--------|-------|---------|-------------|-----|
| 语言与运行模型 | Python，ASGI，原生 async | Python，WSGI 为主 | Python，WSGI，同步 | Node.js，事件循环 | Java，Servlet 容器 + 线程池 | Go，goroutine per request |
| 路由算法 | 有序正则表，O(n)，顺序敏感 | 有序正则表 | 状态机（2.2+），亚线性 | 按注册顺序 | PathPattern（6.0 起默认） | radix tree，O(k) |
| 定位 | API 优先的现代异步框架 | 全栈，电池齐全 | 微框架，最小内核 | 路由 + 中间件的极简内核 | 企业级全栈，约定优于配置 | 高性能极简 HTTP 框架 |
| 参数校验 | 内置（Pydantic） | Forms / DRF Serializer | 需扩展 | 需第三方 | Bean Validation | 绑定 + 校验标签 |
| 序列化 | 内置（Pydantic） | DRF | 需扩展 | 需第三方 | Jackson | encoding/json |
| API 文档 | 内置 OpenAPI | 需 drf-spectacular | 需扩展 | 需扩展 | Springdoc | 需扩展 |
| 拦截模型 | ASGI 中间件栈 | `MIDDLEWARE` 列表 | WSGI 中间件 | 中间件栈 | Filter → Interceptor | HandlersChain |
| 异常处理 | ServerError + Exception 双层 | 中间件 + DRF 处理器 | 错误处理器装饰器 | 四参数错误中间件（置于最后） | `@RestControllerAdvice` | `c.Error()` + Recovery |
| 典型适用 | 高并发 I/O、AI/ML 服务接口 | 含后台管理的关系型业务系统 | 小服务、原型、高度定制 | BFF、轻量网关 | 大型企业级后端、强事务系统 | 高吞吐网关、低延迟服务 |

关于 Spring Boot 的 Filter 与 Interceptor 差异，本次检索到的均为中文技术社区文章，未见 Spring 官方参考文档的直接引用。其结论高度一致：Filter 属 Servlet 规范、作用于容器级全部请求；Interceptor 属 Spring MVC，运行在 `DispatcherServlet` 之内。使用时应以 Spring Framework 官方参考文档复核。

## 5. 关键取舍：约定强度与控制力的对价

选择框架的核心张力是**约定强度**与**控制力**之间的对价。

- Django 与 Spring Boot 以高约定换取开发速度与团队一致性，代价是运行模型不够灵活。Django 传统上偏同步、与关系型数据库紧耦合，FastAPI 官方文档即指出它是为后端生成 HTML 而设计，并非为现代前端提供 API。
- Flask 与 Express 以极简换取自由，代价是所有横切关注点需自行组装，团队缺乏架构约束时容易失控。
- FastAPI 的取舍是：**在 ASGI 异步与类型驱动校验上做强约定，在其余部分保持微框架的松散性**。

这条取舍对 Agent 服务尤其关键，因为 Agent 服务恰好需要"异步 + 强契约"这两项，而不需要全栈 ORM 与管理后台。

## 6. 为什么 Agent 服务普遍选择 Python 系框架

需要说明的诚实边界：本次检索**未找到**权威机构发布的、关于"AI Agent 服务普遍采用 FastAPI"的统计数据。以下判断基于官方文档的自我定位陈述与生态可观察事实，属于合理推断。

**第一，运行模型匹配。** ASGI 加 `async def` 使等待时间归还事件循环，单个进程即可承载大量并发挂起请求。FastAPI 官方文档明确说明，用普通 `def` 声明的处理函数会被放入外部线程池执行，而 `async def` 直接运行于事件循环——这决定了"等待中的请求"是否占用线程。Agent 服务几乎全是等待，这一差异被放大。

**第二，生态同一性。** FastAPI 官方 "Alternatives" 文档直接给出理由：Python 是数据科学、机器学习尤其是深度学习的主要语言。Agent 服务的编排逻辑与模型侧代码同处 Python 生态，避免了跨语言序列化与依赖割裂。

**第三，契约自动化。** Agent 的 tool schema、函数调用参数、流式事件结构本质上都是 JSON Schema，而 Pydantic 的类型注解可直接产出 JSON Schema 并汇入 OpenAPI。同一份代码同时驱动校验、序列化与文档，这在工具定义频繁变动的 Agent 场景下价值极高。

**第四，协议能力完整。** 见第 2.6 节。流式、双向、带重资源初始化这三项全部是 ASGI 原生能力，在 WSGI 框架上要么不可能，要么要付出独占 worker 的代价。

## 7. Agent 服务的框架层实践

### 7.1 三种接口形态

| 形态 | 适用 | 框架载体 | 代价 |
|------|------|---------|------|
| 同步一次性返回 | 短任务、工具调用、批处理 | 普通路由 + `response_model` | 长推理会占用连接、易超时 |
| SSE 流式 | 对话、token 增量输出、过程可观测 | `StreamingResponse` | 反代缓冲、断连取消、长连接资源 |
| 后台任务 + 轮询 | 分钟级 Agent 任务 | 任务队列（非 `BackgroundTasks`） | 需额外的任务存储与进度查询 |

该分类为工程推演，其中流式与后台任务两列的框架行为有官方依据。

### 7.2 流式响应的框架层要点

`StreamingResponse` 接受 async generator 或普通 generator，逐步 `yield` 出 body 分片，构造时可指定 `media_type` 与 `headers`。

官方技术提示值得单独记：async 任务只能在 `await` 处被取消，因此不含 `await` 的生成器应穿插 `await anyio.sleep(0)`，否则客户端断开后生成器可能继续运行——**对 LLM 流式生成意味着继续烧钱**。

`X-Accel-Buffering: no` 响应头的依据：nginx 官方文档说明 `proxy_buffering` 默认为 `on`，而"缓冲也可通过响应头字段 `X-Accel-Buffering` 传 `yes`/`no` 来启用或禁用"。流式接口经 nginx 时必须带该头，否则事件会被攒到响应结束再一次性下发。**多层反代时需逐级透传该头**（第一层会消费掉它，需在配置中再次 `add_header`），此点来自社区博客，非官方文档。

### 7.3 一份 Pydantic 模型的两种用途

OpenAI function calling 的 `parameters` 字段就是一份 JSON Schema，模型返回的 `arguments` 需符合该 schema；开启 `strict: true` 后要求每个对象 `additionalProperties: false` 且 `properties` 中所有字段都进 `required`，可选字段用 `"type": ["string", "null"]` 表示。MCP 侧同理：`tools/list` 返回的 `inputSchema`（必需）与 `outputSchema`（可选）均为 JSON Schema，未声明 `$schema` 时默认 2020-12。

于是同一模型的两个用途收敛为两行代码：

```python
schema = Model.model_json_schema(mode="validation")  # 交给模型消费
args   = Model.model_validate(call_args)             # 校验模型回传的参数
```

这把"提示词里的 schema"与"服务端的运行时校验"统一为单一事实来源。

### 7.4 流式事件的判别联合类型

把 Agent 的流事件建模为带 `Literal` 标签的 Pydantic 联合类型，并用 `Field(discriminator=...)` 标注：

```python
class TokenEvent(BaseModel):
    type: Literal["token"] = "token"
    text: str

Event = Annotated[Union[TokenEvent, ToolCallEvent, DoneEvent, ErrorEvent],
                  Field(discriminator="type")]
```

Pydantic 官方推荐判别联合：只按判别字段选择成员校验，比无标签联合**更快、更可预测**，且**生成的 JSON Schema 会带上 OpenAPI 的 `discriminator` 属性**——即事件契约可同时供前端代码生成与 LLM 消费。

### 7.5 MCP 与 Web 框架的关系

MCP 的传输层绑定为两种：

- **stdio**：客户端启动的子进程上的换行分隔消息。
- **Streamable HTTP**：每条消息是对**单个 MCP 端点**的 HTTP POST，回复为 JSON 对象或请求级 SSE 流。

可见 MCP server 通常是**独立进程或独立服务**（stdio 形态由客户端拉起，根本不监听端口），并非一个 Web 框架应用；FastAPI 只在"你自己实现 Streamable HTTP 传输"时才介入。但两侧共享同一套契约语言：MCP 的 `inputSchema` / `outputSchema` 与 OpenAI 的 `parameters` 同为 JSON Schema。

### 7.6 错误语义的选择

此节为工程推演，无官方定论，但实践中必须做一个明确选择：

| 方案 | 适用 | 风险 |
|------|------|------|
| 上游模型故障 → 502 | 网关语义清晰、便于 LB 熔断与重试 | 客户端易把"部分成功"（已产出若干 token）当整体失败 |
| 200 + 结构化错误体 | 流式中途失败仍可续传已产出内容，与 MCP 的 `isError: true` 语义一致 | 监控无法靠状态码统计失败率，需额外埋点 |

推荐折中：请求建立前失败用 4xx/5xx；流式已开始后只能用流内错误事件收尾，并要求客户端按事件而非状态码判定成败。

MCP 官方对工具错误的处理思路值得借鉴：客户端 SHOULD 把工具执行错误回喂模型，以便模型自我纠正——即错误不是终止信号，而是新的上下文。

## 8. 常见问题与排查

| 症状 | 根因 | 排查路径 |
|------|------|---------|
| 固定路径接口被参数路径拦截 | 路由按声明顺序匹配（Starlette 系） | 检查声明顺序，`/me` 类固定段须前置 |
| 返回循环引用错误 | ORM 双向关联直接进入序列化 | 显式声明输出模型，以 ID 引用替代嵌套对象 |
| 500 但业务日志无异常 | 异常被默认处理器吞掉；或异常来自用户中间件层，未被业务代码触及 | 注册 `Exception` handler 或写中间件记录后 re-raise |
| 流式接口返回被攒成一次性 | nginx `proxy_buffering` 默认 on | 加 `X-Accel-Buffering: no`，多层反代需逐级透传 |
| 流式接口报 response_model 相关错误 | 流式返回了 `Response` 与其他类型的联合 | 返回类型注解为 `StreamingResponse`，不声明 response_model |
| 客户端断开后仍在烧 token | 生成器不含 `await`，无法被取消 | 在生成循环中穿插 `await anyio.sleep(0)` |
| 并发上不去 | 处理函数用同步 `def` 且含阻塞 I/O | 确认是否走了线程池；阻塞调用须外置 |
| LLM 返回的数字被判为非法 | lax 模式下 str 字段不接受数字 | 放宽字段类型或用 `mode='before'` 校验器预处理 |
| 文档与实际响应不一致 | 用了 `include`/`exclude`/`by_alias`，它们不影响 OpenAPI schema | 用独立输出模型而非运行时裁剪 |
| 序列化期脏数据静默通过 | 序列化"尽最大努力"降级为警告 | 测试环境把 `warnings` 设为 `'error'` |

## 9. 部署侧的硬约束

FastAPI 官方部署文档指出，进程之间不共享内存，模型加载 1 GB 时启动 4 个 worker 即占用约 4 GB。Agent 服务常在同一进程内持有嵌入模型、连接池与会话状态，因此 worker 数不能简单按 CPU 核数设定。

另外三个默认值在 Agent 场景下会成为故障源：

- `--timeout-keep-alive` 默认 5 秒。
- `--limit-concurrency` 超限时**立即返回 503，而非排队**。在 Agent 长请求场景下，这意味着高峰期大量请求直接失败，必须与网关侧排队策略协同设计。
- `--backlog` 默认 2048，这是操作系统级 accept 队列，与前者相互独立，不要混淆。

## 10. 自测问题

1. 框架与 Web 服务器的职责边界在哪里？能否只用三个参数把应用跑起来这个判据说明了什么？
2. WSGI 为什么无法支持 WebSocket？即使把可调用对象改成异步的，为什么仍然不行？
3. ASGI 的三类协议各有什么 scope 生命周期？lifespan 的 `state` 解决了什么问题？
4. 为什么路由匹配的顺序在 Starlette 中敏感，在 Gin 中却不敏感？这如何影响 API 设计规范？
5. Pydantic 的 lax 模式下，`str` 字段收到数字会怎样？为什么这个坑在解析 LLM 输出时特别常见？
6. `model_dump()` 与 `model_dump(mode='json')` 的差别是什么？直接把前者喂给 `json.dumps()` 会怎样？
7. 校验期与序列化期的错误处理策略有何不对称？这在生产环境意味着什么风险？
8. 流式接口为什么不能声明 `response_model`？
9. Starlette 的中间件栈有哪三层？注册 `Exception` handler 与注册 `RequestValidationError` handler 分别落在哪层？
10. 用户自己加的中间件抛出的异常，为什么 `ExceptionMiddleware` 捕获不到？
11. 为什么重资源应在 `lifespan` 而非模块导入期加载？
12. Agent 的长任务为什么不能用 `BackgroundTasks`？
13. `model_json_schema()` 的 validation 模式与 serialization 模式，分别该用在什么场合？
14. Agent 服务选择 Python 系框架的四条理由分别对应什么工程收益？

## 11. 参考来源

**WSGI / ASGI**

1. PEP 3333 – Python Web Server Gateway Interface v1.0.1，https://www.python.org/dev/peps/pep-3333/
2. ASGI Documentation: Introduction，https://asgi.readthedocs.io/en/latest/introduction.html
3. ASGI Specification（主规范 3.0），https://asgi.readthedocs.io/en/latest/specs/main.html
4. ASGI HTTP & WebSocket Message Format，https://asgi.readthedocs.io/en/latest/specs/www.html
5. ASGI Lifespan Protocol，https://asgi.readthedocs.io/en/latest/specs/lifespan.html
6. django/asgiref 仓库 README，https://github.com/django/asgiref
7. Kludex/uvicorn 仓库 README，https://github.com/Kludex/uvicorn
8. FastAPI Features，https://fastapi.tiangolo.com/features/

**路由匹配**

9. encode/starlette `routing.py` 源码，https://github.com/encode/starlette/blob/4b37cf89ec80f8eee74eefa8bdce6384ae7af5c3/starlette/routing.py
10. Werkzeug URL Routing，https://werkzeug.palletsprojects.com/en/stable/routing/
11. Faster routing for Flask & Quart（PGJones），https://pgjones.dev/blog/faster-routing-2022
12. julienschmidt/httprouter README，https://github.com/julienschmidt/httprouter
13. Spring Framework 6.0.2 Reference — Web on Servlet Stack，https://docs.spring.io/spring-framework/docs/6.0.2/reference/html/web.html

**异常处理与生命周期**

14. Starlette — Exceptions，https://starlette.dev/exceptions/
15. Starlette — Lifespan，https://starlette.dev/lifespan/
16. Starlette — Background Tasks，https://starlette.dev/background/
17. Starlette 源码 `applications.py`（`build_middleware_stack`），https://raw.githubusercontent.com/Kludex/starlette/master/starlette/applications.py
18. Starlette 源码 `middleware/errors.py`，https://raw.githubusercontent.com/Kludex/starlette/master/starlette/middleware/errors.py
19. Starlette 源码 `middleware/exceptions.py`，https://raw.githubusercontent.com/Kludex/starlette/master/starlette/middleware/exceptions.py
20. FastAPI — Handling Errors，https://fastapi.tiangolo.com/tutorial/handling-errors/
21. FastAPI — Lifespan Events，https://fastapi.tiangolo.com/advanced/events/
22. FastAPI — Background Tasks，https://fastapi.tiangolo.com/tutorial/background-tasks/
23. FastAPI — Advanced Dependencies（后台任务与 yield 顺序），https://fastapi.tiangolo.com/advanced/advanced-dependencies/

**Pydantic v2**

24. Pydantic V2 官方博客，https://github.com/pydantic/pydantic/blob/3a77a579843bf1c0038ba1f331d2d42a19fd7052/docs/blog/pydantic-v2.md
25. Pydantic Docs: Strict Mode，https://pydantic.dev/docs/validation/latest/concepts/strict_mode/
26. Pydantic Docs: Conversion Table，https://pydantic.dev/docs/validation/latest/concepts/conversion_table/
27. Pydantic Docs: Serialization，https://pydantic.dev/docs/validation/latest/concepts/serialization/
28. Pydantic Docs: Validation Errors，https://pydantic.dev/docs/validation/latest/errors/validation_errors/
29. Pydantic Docs: JSON Schema，https://pydantic.dev/docs/validation/latest/concepts/json_schema/
30. Pydantic Docs: Standard Library Types，https://pydantic.dev/docs/validation/latest/api/standard_library_types/
31. Pydantic — Unions（判别联合），https://docs.pydantic.dev/latest/concepts/unions/
32. Pydantic — Forward Annotations（循环引用），https://pydantic.dev/docs/validation/latest/concepts/forward_annotations

**OpenAPI 与响应**

33. FastAPI — Response Model，https://fastapi.tiangolo.com/tutorial/response-model/
34. FastAPI — Metadata and Docs URLs，https://fastapi.tiangolo.com/tutorial/metadata/
35. FastAPI — Extending OpenAPI，https://fastapi.tiangolo.com/how-to/extending-openapi/
36. FastAPI — Generating SDKs（operationId），https://fastapi.tiangolo.com/advanced/generate-clients/
37. FastAPI — Custom Response（StreamingResponse），https://fastapi.tiangolo.com/advanced/custom-response/
38. FastAPI — Deployment Concepts，https://fastapi.tiangolo.com/deployment/concepts/

**Agent 服务化相关**

39. MCP — Transports，https://modelcontextprotocol.io/specification/2026-07-28/basic/transports
40. MCP — Server Tools（`inputSchema` / `isError`），https://modelcontextprotocol.io/specification/2026-07-28/server/tools
41. OpenAI — Function Calling（`parameters` 为 JSON Schema、strict mode），https://developers.openai.com/api/docs/guides/function-calling
42. nginx — ngx_http_proxy_module（`proxy_buffering`、`X-Accel-Buffering`），https://nginx.org/en/docs/http/ngx_http_proxy_module.html
