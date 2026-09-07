---
title: 中间件
category: engineering
parent: 后端服务基础
level: 理解
updated: 2026-09-03
---

# 中间件

## 1. 概念定义

Django 官方的定义：中间件是介入请求与响应处理的钩子框架，一个用于全局改变输入或输出的轻量级、低层级插件系统。

Express 官方的表述更直接：一个 Express 应用本质上就是一系列在请求-响应周期中执行的中间件函数调用。

两者的共性指向同一件事：**中间件是横切关注点的统一挂载点**。鉴权、日志、限流、CORS、错误处理这些逻辑不属于任何一个具体业务接口，却要对所有接口生效，中间件就是为它们准备的标准化插槽。

## 2. 执行模型：洋葱模型

中间件采用**洋葱模型**，即责任链模式的双向变体：请求自外向内逐层穿过，响应自内向外逐层穿出。

Django 官方文档直接使用了这一隐喻：每个中间件类都是包裹视图的一"层"，视图位于洋葱的核心；若某一层决定短路并直接返回响应而不调用 `get_response`，则该层以内（含视图）的所有层都不会看到这个请求或响应，响应只会经由请求已经穿过的层返回。

### 2.1 各框架的堆叠规则

| 框架 | 请求方向顺序 | 响应方向顺序 | 短路机制 |
|------|-------------|-------------|----------|
| FastAPI / Starlette | **后添加者为最外层**，最外层最先执行 | 最外层最后执行 | 不调用 `call_next` |
| Django | 按 `MIDDLEWARE` 列表自上而下 | 自下而上（逆序） | 直接返回 Response，不调用 `get_response` |
| Express | 按 `app.use()` 声明顺序 | 逆序 | 不调用 `next()` |
| Gin | 按 `Use()` 注册顺序 | `c.Next()` 之后的代码逆序返回 | `c.Abort()` |
| Spring Boot | Filter（容器级）→ Interceptor `preHandle` | `postHandle` / `afterCompletion`（逆序）→ Filter | 不调用 `chain.doFilter()`；`preHandle` 返回 `false` |

**顺序的表述方向需要特别区分。** FastAPI 官方明确：每个新中间件都会包裹应用形成栈，最后添加的是最外层。而 Django 的列表首项是最外层。两者在直觉上相反，跨框架工作时极易记反。

## 3. 顺序为什么敏感

顺序敏感源于三点：

1. **依赖传递**。后置中间件依赖前置中间件写入的上下文。Django 官方给出的实例是 `AuthenticationMiddleware` 把已认证用户存储在 session 中，因此必须运行在 `SessionMiddleware` 之后。
2. **语义分歧**。不同组件对同一请求的处理结论不同，会产生认证边界穿透（见 [[02-request-lifecycle]] 第 3.1 节的两个真实案例）。
3. **短路截断**。外层短路后内层完全不执行，包括鉴权。

Express 官方强调：中间件与路由函数按其声明顺序调用，某些中间件的顺序至关重要（例如 session 中间件依赖 cookie 中间件，则 cookie 处理器必须先添加），并给出通则——中间件几乎总应在设置路由之前调用。

### 3.1 典型顺序约定

```
CORS → 请求日志 / 链路追踪 → 鉴权与审计 → 限流与配额 → 业务路由
```

内在逻辑：CORS 需最先响应预检请求，故位于最外层；日志与追踪需覆盖尽可能完整的链路（含被后续中间件拒绝的请求），故紧随其后；鉴权必须在任何业务语义产生前完成；限流置于鉴权之后，以便按身份而非仅按 IP 计量。

## 4. 常见中间件类型

| 类型 | 代表实现 | 职责 |
|------|----------|------|
| 跨域 | Starlette `CORSMiddleware` | 为出站响应添加 CORS 头；自定义响应头需通过 `expose_headers` 暴露才能被浏览器读取 |
| 安全加固 | `TrustedHostMiddleware` | 校验 `Host` 头，防范 HTTP Host Header 攻击，不合规返回 400 |
| 传输优化 | `GZipMiddleware` | 对含 `gzip` 的 `Accept-Encoding` 请求压缩响应，支持标准与流式响应 |
| 强制跳转 | `HTTPSRedirectMiddleware` | 强制请求使用 `https` 或 `wss` |
| 体积限制 | `RequestBodyLimitMiddleware` | 限制入站请求体总字节数（含 multipart 开销），超限返回 413 |
| 日志与追踪 | Morgan、OpenTelemetry ASGI 中间件 | 访问日志、TraceID 注入与 span 产出 |
| 鉴权 | `AuthMiddleware`、Passport | 身份核验与上下文注入 |
| 限流 | 各类 rate limiter | 配额控制，宜置于鉴权之后 |
| 错误处理 | Express 四参数中间件、Gin `Recovery()` | 兜底捕获异常并统一响应格式 |
| 内置解析 | `express.json`、`express.static` | 请求体解析与静态资源服务 |

## 5. 四类陷阱

### 5.1 顺序错误

已在第 3 节详述。缓解手段是**将访问控制下沉到路由或业务层，不把中间件当作唯一边界**。CVE-2025-29927 的教训正在于此：当单一机制承担全部安全责任时，该机制的一个实现缺陷就是整个系统的沦陷。

### 5.2 吞掉异常

中间件捕获异常后既不重抛也不记录，导致异常在指标层完全消失。表现为：用户侧报错，监控大盘一切正常。

Django 的 `process_exception()` 规定：若异常中间件返回了响应，则位于其之上的中间件的 `process_exception` 将不再被调用。这是一种**隐式的异常截断**，排障时容易误判为"没有异常发生"。

### 5.3 阻塞式中间件拖垮异步

这是 Python 异步服务中最隐蔽的性能陷阱。FastAPI 处理函数的 `def` 会被放入外部线程池执行，而 `async def` 直接运行于事件循环。若在中间件中调用 `requests` 等同步阻塞库，或在 `async def` 中执行 CPU 密集计算，整个事件循环被独占，该进程内所有并发请求同时停滞。

### 5.4 在中间件里做重 I/O

中间件对每个请求执行，其内部的远程调用（如每次请求都去鉴权服务校验 Token）会线性放大为上游压力，且无法通过业务层缓存复用。

工程对策是本地校验优先（如 JWT 无状态验签），必须远程校验时配套缓存。

### 5.5 Starlette BaseHTTPMiddleware 的已知限制

Starlette 官方记录：使用 `BaseHTTPMiddleware` 会导致 `contextvars.ContextVar` 的修改**无法向上传播**——在端点中设置的 `ContextVar`，在中间件中读到的不是该值。更关键的是，若它位于栈中较前的位置，会破坏后续依赖 `contextvars` 的纯 ASGI 中间件的传播。官方建议改用**纯 ASGI 中间件**规避。

需要说明的检索边界：社区中长期流传"BaseHTTPMiddleware 会破坏流式响应与后台任务"的说法。本次抓取的 Starlette 官方中间件文档中，Limitations 小节**仅记录了 contextvars 一项**，未提及流式响应或后台任务。故此处不作断言。

## 6. AI Agent 场景下的注意点

### 6.1 流式响应与中间件改造的冲突

任何需要读取完整响应体才能工作的中间件（压缩、内容审计、响应改写），都会破坏 SSE 的分块语义或引入不可接受的延迟。

`GZipMiddleware` 虽官方声明支持流式响应（对每个 chunk 压缩后立即发出），但实践中流式接口更常见的做法是**关闭压缩**——gzip 需要攒够数据块才能产生有效压缩比，与"来多少发多少"的目标相悖。

### 6.2 鉴权与限流的位置需要重新权衡

Agent 的一次会话可能持续数分钟并消耗数百次模型调用，按请求数限流失去意义。应改用按 token 或按计算时长的配额模型，并置于鉴权之后按用户身份计量。

### 6.3 追踪中间件必须位于最外层

这样才能覆盖被限流拒绝、被鉴权拒绝的请求，使"拒绝率"这一关键指标可观测。借助 FastAPI"后添加者为最外层"的规则，通过 `add_middleware` 注入的 OTel 中间件天然满足该要求。

### 6.4 断连感知应作为中间件职责统一实现

将客户端断连检测与资源回收封装为中间件，可避免在每个流式接口中重复处理。这一条在 Agent 服务中价值极高，因为流式接口往往有十几个。

### 6.5 不在中间件中执行任何模型侧调用

中间件是高频路径，其延迟直接叠加到每一个请求的首字节时间上。内容安全审核、意图路由等涉及模型的逻辑，应置于业务层并异步化，中间件只负责承载其结果的传递。

## 7. 自测问题

1. 洋葱模型中，短路发生在某一层时，内层和外层分别会怎样？
2. FastAPI 与 Django 的中间件顺序表述有何差异？
3. 为什么限流中间件应放在鉴权之后？
4. 中间件吞掉异常会造成什么后果，为什么监控系统发现不了？
5. 在异步服务中，一个中间件调用了同步阻塞库，影响范围有多大？
6. 流式接口为什么要关闭 gzip 压缩？
7. 追踪中间件应放在栈的什么位置，为什么？

## 8. 参考来源

1. FastAPI — Middleware，https://fastapi.tiangolo.com/tutorial/middleware
2. FastAPI — Advanced Middleware，https://fastapi.tiangolo.com/advanced/middleware/
3. Django documentation — Middleware，https://docs.djangoproject.com/en/6.0/topics/http/middleware/
4. Django 文档（中文）— 中间件，https://docs.djangoproject.com/zh-hans/6.0/topics/http/middleware/
5. Express.js — Using middleware，https://expressjs.com/en/guide/using-middleware.html
6. Gin Web Framework — Custom Middleware，https://gin-gonic.com/en/docs/middleware/custom-middleware
7. Starlette — Middleware，https://starlette.dev/middleware/
8. Next.js Middleware Bypass Vulnerability（CVE-2025-29927），https://aardwolfsecurity.com/?p=3799
9. Hidden in the Middleware: 企业 Java 中间件漏洞链，https://undercodenews.com/hidden-in-the-middleware-how-12-enterprise-java-vulnerabilities-can-lead-to-full-remote-code-execution/
