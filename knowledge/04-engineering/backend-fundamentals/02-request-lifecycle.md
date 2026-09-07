---
title: 请求生命周期
category: engineering
parent: 后端服务基础
level: 应用
updated: 2026-09-04
---

# 请求生命周期

## 1. 概念定义

请求生命周期指一次 HTTP 请求从抵达网卡到响应发出的完整路径。把它拆成离散环节的价值在于：**每一环都是独立的故障面**。线上出问题时，"请求挂了"不是一个可用的描述，必须能回答"挂在哪一环"。

标准拆法为七环：

```
接收连接 → 中间件链 → 路由匹配 → 参数校验 → 业务逻辑 → 序列化 → 响应
```

### 1.1 更细的视角：十道可被掐断的关卡

七环是应用视角。若把网络与网关一并计入，一次请求实际上穿过十道"可以被掐断"的关卡，每道都有自己的超时语义：

| 关卡 | 该环节的超时语义 | 典型参数 |
|------|----------------|---------|
| 客户端（浏览器 / SDK） | 整体等待上限 | `fetch` AbortSignal、SDK `timeout` |
| DNS 解析 | 解析等待 | resolver timeout |
| CDN / 边缘 | 回源超时、边缘空闲超时 | 各家自定义 |
| 负载均衡（ALB / NLB / CLB） | **空闲**超时（非总时长） | `idle_timeout.timeout_seconds` |
| 反向代理（Nginx） | 连上游、读上游、发上游、读客户端 | `proxy_*_timeout` |
| 应用服务器（Uvicorn / Gunicorn） | 保活、优雅退出、worker 静默 | `--timeout-keep-alive`、`timeout` |
| 应用框架 | 业务内自设 deadline | `asyncio.wait_for` |
| 数据库连接池 | **等待借出连接**（不是查询耗时） | `pool_timeout` |
| 数据库语句 | 服务端执行上限 | `statement_timeout` |
| LLM / 外部 HTTP | connect、read、write 三类 | 客户端库参数 |

区分"连接池等待"与"语句执行"尤其重要：前者是排队，后者是干活。慢的时候必须分清是慢还是堵。

## 2. 逐环解析

### 2.1 接收连接：三段握手成本与两条队列

应用数据能发出去之前，必须先付掉三段"税"：DNS、TCP 握手、TLS 握手。TCP 三次握手消耗 **1 个 RTT**（客户端只有在发出第三个 ACK 时才能捎带应用数据）。TLS 叠加其上：

| 协议 | 完整握手 | 会话复用 | 说明 |
|------|---------|---------|------|
| TLS 1.2 | **2-RTT** | 1-RTT（Session ID / Session Ticket） | RFC 5246 |
| TLS 1.3 | **1-RTT** | **0-RTT**（PSK + early data） | RFC 8446，密钥交换参数前置到 ClientHello 的 `key_share` |

**TLS 1.3 的 0-RTT** 允许客户端在第一个报文里就带上加密的应用数据，省掉整个握手等待。代价来自 RFC 8446 明确记载的事实：**0-RTT 数据不提供重放保护**。因此 0-RTT 只应用于幂等请求（GET），不能用于 POST / PUT / DELETE 等改变状态的操作。

#### 2.1.1 SYN 队列与 accept 队列

自 Linux 2.2 起，监听套接字维护两条独立队列：

| 队列 | 别名 | 内容 | 长度上限 | 溢出行为 |
|------|------|------|---------|---------|
| SYN 队列 | 半连接队列 | 已收 SYN、已回 SYN-ACK，尚未收到第三次 ACK 的连接（`SYN_RECV`） | `net.ipv4.tcp_max_syn_backlog` | 丢弃新 SYN；若 `tcp_syncookies=1`（**默认值**）则改为下发 SYN cookie |
| accept 队列 | 全连接队列 | 三次握手已完成，等待应用 `accept()` 取走的连接（`ESTABLISHED`） | `min(listen(backlog), net.core.somaxconn)` | 由 `tcp_abort_on_overflow` 决定 |

内核文档对 `tcp_syncookies` 的定位措辞很重：**"syncookies is fallback facility. It MUST NOT be used to help highly loaded servers to stand against legal connection rate."** 即 SYN cookie 是抗 SYN Flood 的兜底，不是高并发调优手段；若日志里出现 SYN flooding 告警但流量都是合法连接，说明参数配置本身有问题。

`tcp_abort_on_overflow` 默认值是 **0（FALSE）**：溢出时内核静默丢弃第三次 ACK，客户端侧表现为 SYN-ACK 被重传、连接迟迟建不上，给应用 `accept()` 排空队列的时间（自愈）。设为 1 则直接回 RST，客户端立刻拿到 `Connection refused`，但内核文档警告"Enabling this option can harm clients of your server"，只应在确认守护进程无法调优时使用。

#### 2.1.2 backlog 与 somaxconn 的取小规则

全连接队列的实际生效值是 `min(应用程序 listen() 传入的 backlog, net.core.somaxconn)`。

- `net.core.somaxconn` 内核文档："Defaults to 4096. (Was 128 before linux-5.4)"。旧内核上仍是 **128**。
- Nginx 的 `listen` 指令：`backlog` 默认为 511（Linux）。

经典瓶颈场景：应用把 backlog 设成 65535，但宿主机内核低于 5.4，`somaxconn=128` 直接把队列锁死在 128。

#### 2.1.3 如何观测队列溢出

| 手段 | 读什么 | 含义 |
|------|-------|------|
| `ss -lnt` | LISTEN 行 `Recv-Q` / `Send-Q` | `Recv-Q` 为当前 accept 队列积压长度，`Send-Q` 为队列上限。若前者持续逼近后者，说明应用 `accept()` 跟不上 |
| `netstat -s` | `times the listen queue of a socket overflowed` | accept 队列溢出累计计数 |
| `netstat -s` | `SYNs to LISTEN sockets dropped` | SYN 队列溢出累计计数 |
| `nstat` | `TcpExtListenOverflows` / `TcpExtListenDrops` | 同上，字段化版本，便于采集 |

判定要点是看**计数是否持续增长**，而非绝对值。

#### 2.1.4 为什么 accept 队列溢出在日志里完全没有痕迹

连接是在"第三次握手收完、内核把它放入 accept 队列"这一步被丢弃的。此时：

1. 应用层尚未 `accept()` 该 socket，进程里不存在对应的文件描述符与连接对象；
2. Nginx 的 accept 事件从未触发，因此没有创建连接与请求对象，自然不会生成 access log（access log 在请求结束时才写）；
3. error log 也不会记录——内核丢弃 ACK 不产生任何用户态错误；
4. 但对客户端而言，服务端**已经回了 SYN 和 SYN-ACK**，握手看起来是"正常进行中"的。

这就是"健康检查全绿、QPS 曲线不抖、用户却大面积报超时"的根因。要抓它只能靠上一小节的计数。

### 2.2 连接复用与 HTTP 版本

#### 2.2.1 HTTP/1.0 与 HTTP/1.1 的持久连接语义差别

RFC 9112 §9.3 的规定是判定顺序式的：

- **HTTP/1.1 默认持久**：只有当 `Connection` 中出现 `close` 选项时才关闭。
- **HTTP/1.0 默认关闭**：必须显式带 `keep-alive` 连接选项。
- 代理的强制约束：**"A proxy server MUST NOT maintain a persistent connection with an HTTP/1.0 client."** 这一条是 Nginx 与 upstream 之间必须显式配置 HTTP/1.1 的规范根源。

#### 2.2.2 TCP keepalive 与 HTTP keep-alive 是两件事

这是最高频的混淆点，两者不在同一层、解决不同问题：

| 维度 | TCP keepalive | HTTP keep-alive |
|------|--------------|-----------------|
| 层次 | 传输层（TCP 选项） | 应用层（HTTP 连接语义） |
| 作用 | 探测已建立但长期空闲的连接对端是否还活着 | 让一条 TCP 连接承载多个请求/响应 |
| 默认触发 | 空闲 **2 小时**（`net.ipv4.tcp_keepalive_time`） | Nginx 客户端侧 `keepalive_timeout 75s`；upstream 侧 `keepalive_timeout 60s` |
| 探测参数 | `tcp_keepalive_intvl` 默认 75s × `tcp_keepalive_probes` 默认 9 → 约 11 分钟后判定断开 | 超时后主动发 FIN 关闭 |
| 是否默认开启 | **否**，需 socket 设 `SO_KEEPALIVE` | HTTP/1.1 默认开启 |

关键推论：TCP keepalive 的 2 小时默认值意味着它**完全不能**用来快速发现断连。若 Agent 服务靠它检测客户端掉线，一个死连接要占着资源两个小时才被回收。

#### 2.2.3 Nginx 与 upstream 的连接复用三件套

Nginx 官方文档的原文要求："For HTTP, the `proxy_http_version` directive should be `1.1` ... and the `Connection` header field should be cleared."

| 指令 | 默认值 | 为什么不配就不复用 |
|------|--------|------------------|
| `keepalive N`（`upstream` 块） | 自 1.29.7 起默认 `keepalive 32 local;` | 决定**每个 worker** 缓存多少条空闲 upstream 连接。不配则连接处理完即关 |
| `proxy_http_version 1.1` | `1.1`（1.29.7 起；此前为 **1.0**） | 1.0 下无法协商持久连接 |
| `proxy_set_header Connection ""` | `proxy_set_header Connection close;` | 默认就往 upstream 发 `Connection: close`，即使 HTTP 版本是 1.1，upstream 也会在响应后关连接。置空字符串后该头不被传递 |

需要说明：Nginx ≥ 1.29.7 已把 `proxy_http_version` 默认为 1.1 并默认启用 upstream keepalive 缓存，但 `proxy_set_header Connection close` 的默认值仍在，因此存量环境（绝大多数低于 1.29.7）三件套必须显式配齐。

**不配的后果**：每个请求都要新建一条到 upstream 的 TCP 连接（含可能的 TLS 握手），请求结束由 Nginx 主动关闭 → **TIME_WAIT 堆积在 Nginx 侧**。

#### 2.2.4 TIME_WAIT 出现在哪一侧

- 只有**主动发起关闭（先发 FIN）的一方**进入 TIME_WAIT。Nginx 作为反向代理是 upstream 连接的主动关闭方，所以 TIME_WAIT 堆在 Nginx 机器上，而不是后端应用。
- 持续时长为 2×MSL；Linux 内核把 `TCP_TIMEWAIT_LEN` 硬编码为 `60*HZ`（60 秒），无法通过 sysctl 修改。
- 危害：每个 TIME_WAIT 套接字占住一个本地端口。`ip_local_port_range` 默认 `32768 60999`（约 2.8 万个可用端口），短连接速率一旦超过"可用端口 / 60s"，新连接就拿不到端口，报 `EADDRNOTAVAIL` 或 `ECONNREFUSED`。
- 官方建议的缓解次序：先做应用层连接复用（连接池、keepalive、HTTP/2），再考虑 `tcp_tw_reuse`（默认 2，即仅对 loopback 生效，内核文档明确不建议自行调整）。`tcp_tw_recycle` 已在内核 4.12 移除，不应使用。

#### 2.2.5 队头阻塞的两层含义

HTTP/1.1 的**应用层 HOL**：一条连接上请求与响应严格串行，前一个响应没回来，后一个请求发不出去（pipelining 因实现问题基本被废弃）。

HTTP/2 通过二进制分帧 + stream 多路复用解决了应用层 HOL，但它没有改传输层，仍是单条 TCP。RFC 9114 给出了最权威的描述：

> "because the parallel nature of HTTP/2's multiplexing is not visible to TCP's loss recovery mechanisms, a lost or reordered packet causes all active transactions to experience a stall regardless of whether that transaction was directly impacted by the lost packet."

这就是**传输层 HOL**——TCP 丢一个包，该连接上所有 HTTP/2 stream 一起卡住。

#### 2.2.6 HTTP/2 下 SSE 的注意事项

对 Agent 流式服务，这一节是刚需而非优化：

- **连接数限制**：非 HTTP/2 场景下 SSE 受"每浏览器 + 每域名 6 条连接"的限制（Chrome/Firefox 均标记为 Won't fix），开多个标签页尤其致命；**HTTP/2 下并发 stream 数由双方协商（默认 100）**，Nginx 侧对应 `http2_max_concurrent_streams`，默认 128。
- **`Transfer-Encoding` 在 HTTP/2 被禁用**：MDN 明确警告 "HTTP/2 disallows all uses of the `Transfer-Encoding` header... Usage of the header in HTTP/2 may likely result in a specific `protocol error`." 分帧由 HTTP/2 自己做，chunked 是 HTTP/1.1 概念。
- **gRPC 与 HTTP/2 的关系**：gRPC 直接构建在 HTTP/2 之上，四种方法（unary / server streaming / client streaming / bidirectional streaming）就是把 HTTP/2 的 stream 语义映射成 RPC 语义。gRPC 的流式天然复用 HTTP/2 分帧能力，不存在 SSE 那种 chunked 兼容问题，但完全继承了 TCP 传输层 HOL。

#### 2.2.7 HTTP/3 与 QUIC 的定位

QUIC 运行在 **UDP** 之上，把流多路复用与按流流控下沉到传输层：**"Streams are independent of each other, so one stream that is blocked or suffers packet loss does not prevent progress on other streams."** 这正是它相对 HTTP/2 的核心增量——消除传输层 HOL，尤其在弱网/高丢包场景。

两点约束：**强制加密**（QUIC v1 使用 TLS 1.3 或更高，通过 ALPN 令牌 `h3` 协商，不存在明文 HTTP/3）；UDP 被阻断则建连失败，生产环境需同时保留 TCP 通路。

### 2.3 网关转发与错误码判定

#### 2.3.1 499 Client Closed Request

499 **不是 HTTP 状态码**，RFC 9110 中没有它。它来自 Nginx 源码常量 `NGX_HTTP_CLIENT_CLOSED_REQUEST`——HTTP 协议没有为"客户端在处理过程中关闭连接"定义状态码，于是 Nginx 自己造了一个，仅用于写日志。

Nginx 核心开发者 Maxim Dounin 在官方邮件列表给出精确语义：

> "The `499` code means that nginx got a request, but wasn't able to send a response. That is, client closed connection before we started sending a response. This, in particular, may happen if a backend is slow and nginx isn't able to return a response before the client times out."

要点：

- **499 只出现在服务端 access log 里，永远不会发给客户端。** 客户端看到的是转圈、超时或自己主动取消。
- 与 400 的区别：400 表示"没收到合法请求"，499 表示"请求收到了，但响应还没生成出来客户端就断了"。
- **为什么长耗时 Agent 请求里 499 大量出现**：LLM 推理动辄数秒到数十秒，链条上任何一环（浏览器 / SDK / 上游 LB / CDN）的超时阈值只要小于总耗时，客户端就会先放手。典型误配是"外层超时短于内层"。
- **与 504 的根本区别是"谁先动手"**：499 = 客户端先放弃；504 = 网关先放弃。大量 499 往往出现在 502/504 之前，是最早的预警信号。

#### 2.3.2 502 / 503 / 504 的精确定义

| 状态码 | 定义 | 典型成因 |
|--------|------|---------|
| **502 Bad Gateway** | 网关**收到了来自上游的无效响应** | upstream 拒绝连接（`ECONNREFUSED`）；响应头非法或为空；upstream 提前关闭连接（进程被 OOM kill / 重启） |
| **503 Service Unavailable** | 服务器**尚未就绪处理请求** | 无可用 upstream（全部被 `max_fails` 摘除）；主动限流；维护模式。注意针对特定客户端的限流更应该用 429 |
| **504 Gateway Timeout** | **未能在时限内**从上游获得响应 | `proxy_connect_timeout` / `proxy_read_timeout` / `proxy_send_timeout` 触发（三者默认均为 60s） |

MDN 给出了一条关键判别规则，直接区分 502 与 504：

> "If the origin server sends a valid HTTP error response to the gateway, the response should be passed on to the client instead of a `502`... If the proxy or gateway did not receive **any** HTTP response from the origin, it instead sends a `504`."

即：**收到了但内容非法 → 502；压根没收到 → 504。**

#### 2.3.3 `proxy_next_upstream` 的重试陷阱

默认值是 `error timeout`，即只在"建连出错"和"超时"两类情况下换下一台，`http_500/502/503/504/403/404/429` **默认都不重试**，必须显式列出。

针对非幂等请求，官方文档原文：

> "normally, requests with a non-idempotent method (`POST`, `LOCK`, `PATCH`) are **not** passed to the next server if a request has been sent to an upstream server (1.9.13); enabling this option explicitly allows retrying such requests"

这是默认的安全行为。显式加 `non_idempotent` 才会放开——**对 Agent 场景尤其危险**：一次重试就是两次 LLM 调用，成本翻倍且可能产生重复的副作用（下单、写库、扣费）。正确做法是自己实现幂等键，而不是靠 Nginx 重试。

另外两条容易忽略的约束：

- **"passing a request to the next server is only possible if nothing has been sent to a client yet"** —— 响应一旦开始往客户端发（流式场景几乎必然），重试就不可能了。这正是 SSE 无法被 `proxy_next_upstream` 保护的原因。
- 重试次数由 `proxy_next_upstream_tries`（默认 0 = 不限）与 `proxy_next_upstream_timeout`（默认 0 = 不限）约束。不加约束时，一次慢请求可能打遍所有 upstream。

#### 2.3.4 错误码与排查方向对照表

| 观测到的码 | 第一排查方向 | 关键证据 |
|-----------|-------------|---------|
| 499 | 客户端 / LB / CDN 超时阈值 vs 实际耗时；画出超时阶梯 | `$request_time` 是否聚集在 30s / 60s / 100s 等整数（是 → 某层超时；分散 → 用户主动放弃） |
| 502 | upstream 是否活着、是否在重启、是否提前关连接 | error log 的 `connect() failed` / `upstream prematurely closed connection` |
| 503 | upstream 是否全被摘除；是否触发自身限流 | `max_fails` / `fail_timeout`；自身限流计数 |
| 504 | 是连不上还是读不到；总耗时 vs `proxy_read_timeout` | error log 的 `upstream timed out`，会区分 connect / read / send |
| 408 | 客户端发请求体太慢（`client_body_timeout`）或请求头发不全（`client_header_timeout`） | 上游网络质量、大请求体上传 |
| 413 | 请求体超过 `client_max_body_size`（默认 1m） | 上传 / 大 prompt 场景 |

### 2.4 中间件链

请求自最外层中间件逐层向内穿过，完成 CORS 预检、TraceID 注入、鉴权、限流等前置判断。详见 [[03-middleware]]。

### 2.5 路由匹配与参数校验

路由匹配与参数校验的机理（算法差异、Pydantic 校验与序列化）详见 [[01-framework-responsibilities]]。这里只强调它们在生命周期中的定位：

- **路由**：命中则得到处理函数与参数绑定，未命中在 FastAPI 侧产生 404。
- **校验**：这一环是**请求能否进入业务的闸门**，失败则短路为 4xx，业务逻辑完全不执行。

### 2.6 业务逻辑

含依赖注入、外部调用、事务。Agent 服务的耗时几乎全部集中于此，通常占整条链路的九成以上。

这一环有两个容易被忽略的耗时来源：

1. **连接池等待**。请求借不到数据库连接时，时间花在排队上而非执行上。观测口径上要与语句执行耗时分开统计。
2. **请求体读取**。见下。

#### 2.6.1 请求体：Content-Length 与 chunked

| 维度 | `Content-Length` | `Transfer-Encoding: chunked` |
|------|-----------------|---------------------------|
| 语义 | 声明消息体的精确字节数 | 把消息体切成若干带长度前缀的数据块，以零长度块终结 |
| 适用 | 长度事先已知 | 长度事先未知（流式生成、边查边吐） |
| 能否共存 | **不能**。MDN 对 chunked 的说明："The `Content-Length` header must be omitted" | 同左 |

两者同时出现是 HTTP 请求走私（CL.TE / TE.CL）的经典入口——所以**不要**在应用里手动同时设置这两个头。

另一个必须记住的性质：**`Transfer-Encoding` 是逐跳（hop-by-hop）头**。MDN 原文："applied to a message between two nodes, not to a resource itself. Each segment of a multi-node connection can use different `Transfer-Encoding` values." 因此 Nginx 完全可以在客户端侧用 chunked、在 upstream 侧用 `Content-Length`，反之亦然。

#### 2.6.2 请求体侧的 Nginx 参数

| 指令 | 默认值 | 超限 / 超时行为 |
|------|--------|---------------|
| `client_max_body_size` | `1m` | 超出返回 **413** |
| `client_body_timeout` | `60s` | 读不到数据返回 **408**。文档措辞："set only for a period **between two successive read operations**, not for the transmission of the whole request body"——是间隔超时，不是总时长超时 |
| `client_body_buffer_size` | `8k` / `16k`（两个内存页） | 请求体大于缓冲区时，"the whole body or only its part is **written to a temporary file**" |
| `client_header_timeout` | `60s` | 请求头未在时限内收全 → 408 |
| `large_client_header_buffers` | `4 8k` | 请求行超单缓冲 → 414；单头部字段超单缓冲 → 400 |

**大文件上传为什么会写磁盘**：请求体缓冲是内存常驻的，Nginx worker 进程若要为每个并发上传都预留完整请求体的内存，在 GB 级上传下会直接把内存打爆。所以设计上只给两个内存页做缓冲，超出即落临时文件（磁盘 I/O 换内存）。这也是为什么上传接口的上游磁盘 I/O 会成为隐藏瓶颈——它不一定来自业务代码。

#### 2.6.3 请求体流式读取的代价

`proxy_request_buffering` 默认 **on**，文档原文："the entire request body is read from the client before sending the request to a proxied server." 关掉则边收边发。

代价写在文档里：关闭后 "the request cannot be passed to the next server if nginx already started sending the request body"——**流式请求体与 `proxy_next_upstream` 重试不可兼得**。

另一条容易踩的规则："When HTTP/1.1 chunked transfer encoding is used to send the original request body, the request body will be buffered **regardless of the directive value** unless HTTP/1.1 or HTTP/2 is enabled for proxying." 即客户端用 chunked 发请求体、而 `proxy_http_version` 还是 1.0 时，缓冲区必然生效，怎么配 `off` 都没用。

### 2.7 序列化与响应

序列化机理详见 [[01-framework-responsibilities]]。这里只讲响应阶段的传输问题。

#### 2.7.1 响应侧 chunked 与 SSE

Nginx 在 HTTP/1.1 且响应长度未知时自动使用 chunked。这是 SSE 能工作的基础——**SSE 的每一条 `data:` 事件本质上就是一个 chunk**。

但 `proxy_buffering` 默认 **on**：Nginx 会尽快把 upstream 响应读进内存（`proxy_buffer_size` / `proxy_buffers`），装不下就写临时文件（`proxy_max_temp_file_size`）。开启缓冲时，一个持续数分钟的 SSE 流会被攒着，客户端要么长时间收不到数据，要么等上游结束才一次性拿到。

因此 **SSE 必须关闭响应缓冲**，两条等价手段：`proxy_buffering off;`，或让 upstream 回 `X-Accel-Buffering: no`（可用 `proxy_ignore_headers` 禁用该能力）。

#### 2.7.2 gzip 与流式的冲突

| 指令 | 默认值 | 对流式的影响 |
|------|--------|------------|
| `gzip_min_length` | `20` | 文档明确："The length is determined **only from the 'Content-Length' response header field**." 流式响应没有 `Content-Length`，该判定失效 |
| `gzip_buffers` | `32 4k` 或 `16 8k` | 压缩器要攒够一个 buffer 才会输出。对逐 token 生成的 SSE，单个 token 只有几字节，会被压在缓冲区里直到凑满 4k/8k——**首次可见延迟被人为拉长** |
| `gzip_types` | `text/html` | `text/event-stream` 不在默认列表内；但一旦加进去，上面两条问题就生效了 |

结论：**SSE / 流式接口应当显式关闭 gzip**。若确实需要压缩，SSE 的 token 流本身压缩收益低（文本重复度不高）而延迟代价高，不划算。

另外注意 `gzip_proxied` 默认 **off**，而对"是否为代理请求"的判定依据是**请求中是否有 `Via` 头**——在网关之后的二级 Nginx 上，不配 `gzip_proxied` 会导致压缩完全不生效。

#### 2.7.3 缓存响应头与 304

| 头 | 作用 |
|----|------|
| `Cache-Control: no-cache` | **不是"不缓存"**。MDN："the response can be stored in caches, but the response must be validated with the origin server before each reuse" |
| `Cache-Control: no-store` | 才是真正"任何缓存都不许存" |
| `ETag` / `If-None-Match` | 资源版本标识。弱校验器前缀 `W/`，"are far less useful for comparisons" |
| `Last-Modified` / `If-Modified-Since` | 基于时间戳的条件请求，精度只到秒 |
| `304 Not Modified` | 条件命中时"the server sends back a `304 Not Modified` status, **without a body**" |

**为什么 SSE 与动态接口必须显式声明 `Cache-Control: no-cache`**：MDN 给出的理由——"If you don't add a `Cache-Control` header because the response is not intended to be cached, that could cause an unexpected result. **Cache storage is allowed to cache it heuristically**"。即"不加头"并不等于"不缓存"，中间代理和 CDN 有启发式缓存的自由裁量权。对一个逐 token 变化的 SSE 流，一旦被启发式缓存，用户看到的将是被冻结的旧流。

## 3. 超时体系

### 3.1 三类超时语义的区分

- **connect（连接超时）**：建连（TCP / TLS）阶段的等待上限。requests 官方文档定义为"客户端与远端机器建立连接的秒数"。
- **read（读取超时）**：requests 官方文档明确定义为"客户端在服务器**发送的字节之间**等待的秒数"。这是**两次读之间**的间隔上限，不是整个响应体的下载时间。这一区别对流式响应至关重要：只要模型还在持续吐 token，read 超时就不会触发。
- **total（整体超时）**：从发起到收完的墙钟上限。

**"单一超时参数"的局限**：部分 LLM SDK 只暴露一个 `timeout`。若该值被实现为整体超时，则长输出（数千 token 的流式生成）会在中途被切断；若被实现为 read 超时，则对"服务端完全无响应"的挂死场景失去保护。工程上必须实测确认该参数映射到哪一档（此点为工程推演）。

### 3.2 收敛原则

**方向必须是：外层超时 > 内层超时（外层是内层的上界）。**

搞反后的具体表现：

1. **内层 > 外层**：外层先断连接，内层仍在计算。客户端已收到 499 / 504，服务端却继续占用 worker、GPU 显存与数据库连接，直到内层超时才释放。在 Agent 场景中，这意味着一次已经无人接收的 LLM 生成继续烧完 token 费用。
2. **连接被复用后污染**：外层断开但内层未感知，连接归还池中时可能残留未读完的响应体，导致后续请求读到错乱数据。
3. **重试风暴**：外层超时触发客户端重试，而内层任务仍在跑，形成"客户端重试 N 次、服务端执行 N 遍"的放大。

### 3.3 官方默认值清单

| 组件 | 参数 | 官方默认值 |
|------|------|-----------|
| Nginx | `proxy_connect_timeout` / `proxy_read_timeout` / `proxy_send_timeout` | 均为 `60s` |
| Nginx | `keepalive_timeout` | `75s` |
| Nginx | `client_body_timeout` / `client_header_timeout` / `send_timeout` | 均为 `60s` |
| Nginx | `lingering_timeout` | `5s` |
| Uvicorn | `--timeout-keep-alive` | `5` |
| Uvicorn | `--timeout-graceful-shutdown` | 源码 `Config` 中默认 `None` |
| Uvicorn | `--limit-concurrency` | 源码默认 `None`（不限制） |
| Uvicorn | `--backlog` / `--timeout-worker-healthcheck` | `2048` / `5` |
| Gunicorn | `timeout`（`-t`） | `30` |
| Gunicorn | `graceful_timeout` | `30` |
| Gunicorn | `keepalive` | `2` |
| Gunicorn | `worker_connections` / `max_requests` | `1000` / `0` |
| AWS ALB | `idle_timeout.timeout_seconds` | `60` 秒 |
| AWS ALB | `client_keep_alive.seconds` | `3600` 秒 |
| AWS ALB 目标组 | `deregistration_delay.timeout_seconds` | `300` 秒（范围 0–3600） |
| httpx | 默认超时 | 网络不活动 **5 秒**；支持 connect / read / write / pool 四类 |
| aiohttp | `ClientTimeout.total` | **300 秒（5 分钟）** |
| requests | 默认超时 | **无默认超时**，不显式设置即无限等待 |

需要特别注意：ALB 的 60 秒是**空闲**超时而非总时长——只要连接上持续有字节流动就不会触发。但对"首字节迟迟不来"的请求，60 秒即断。

另需注意 `requests` 无默认超时这一条：不加 `timeout` 参数时，一个挂死的下游会让调用线程永久阻塞，这是生产事故的经典成因。

### 3.4 超时与重试的约束

约束式：**重试次数 × 单次超时上限 + 退避时间 < 外层超时**。

若违反，表现为：外层已在第 60 秒放弃，内层第 2 次重试才刚发出。结果既拿不到结果，又白跑一次。

### 3.5 Agent 场景的阶梯重设计

矛盾：单次 LLM 调用常达数十秒甚至数分钟，而 ALB 默认 60 秒、Nginx 默认 60 秒、Gunicorn 默认 30 秒。

建议阶梯（示例值，需按业务实测）：

| 层 | 建议值 | 说明 |
|----|--------|------|
| LLM 客户端 read | 依据 ITL 设定（如 30–60s） | 只约束"卡住不吐字" |
| LLM 客户端 total | 单次调用上限（如 120s） | 或改用异步任务彻底移除 |
| 应用层 deadline | > LLM total | 留出重试与降级时间 |
| Nginx `proxy_read_timeout` | > 应用层 deadline | 流式场景需配合 `proxy_buffering off` |
| ALB idle timeout | 调大或改用异步化 | 不能让网关成为最短板 |

## 4. 可观测：定位卡在哪一环

### 4.1 建立请求身份：W3C Trace Context

`traceparent` 格式为 `version-trace-id-parent-id-trace-flags`：

| 字段 | 十六进制位数 | 规则 |
|------|-------------|------|
| `version` | 2 | 当前规范为 `00`；`ff` 无效 |
| `trace-id` | 32 | 全零无效 |
| `parent-id` | 16 | 全零无效，即 span-id |
| `trace-flags` | 2 | 目前仅最低位 `sampled` 有定义 |

version `00` 时整串长度 55 字符。示例：`00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01`。

采样决策的传递：`sampled` 是 `trace-flags` 的**最低有效位**，必须用**位掩码**判断（`(flags & 0x01) == 0x01`），不能直接比较十六进制数值。规范规定 `sampled` **只能在 `parent-id` 被更新时**才能变更；其他 7 位保留且必须为 0。语义是"调用方可能已记录该 trace"，下游据此决定是否也记录。

`tracestate`：逗号分隔的 `key=value` 列表，最多 32 个成员，值最长 256 字符；新增或修改的条目应置于**最左**。解析 `traceparent` 失败时禁止解析 `tracestate`。

OpenTelemetry 的 FastAPI 埋点通过 `FastAPIInstrumentor.instrument_app(app)` 实现，其内部即调用 `app.add_middleware(...)`。依据 FastAPI"后添加者为最外层"的堆叠规则，埋点中间件位于栈的外侧，因而能覆盖包括其他中间件在内的全链路耗时——这正是"用追踪判断卡在哪个环节"的机制基础。该埋点支持 `excluded_urls` 排除健康检查端点，并支持通过 `server_request_hook` / `client_response_hook` 注入自定义属性。

### 4.2 Span 模型与 HTTP 语义约定

| 字段 | 必填性 | 说明 |
|------|-------|------|
| `name` | **必填** | 创建时唯一必需参数 |
| `kind` | 可选 | 默认 `INTERNAL` |
| `status` | 可选 | 默认 `Unset`（`Unset` / `Ok` / `Error`） |
| `attributes` | 可选 | 空集合 |
| `events` / `links` | 可选 | 空列表 |

重要约束：**采样器只能看到 Span 创建时已存在的 attributes 与 links**，因此规范建议 attributes 与 links 尽量在创建时传入。

SpanKind 五种取值与链路的对应：

| Kind | 方向 | 在链路中的对应 |
|------|------|--------------|
| `SERVER` | incoming | 网关、应用接收请求 |
| `CLIENT` | outgoing | 应用调用 LLM / DB |
| `PRODUCER` | outgoing | 投递任务到队列 |
| `CONSUMER` | incoming | 异步 Worker 消费 |
| `INTERNAL` | — | 纯应用内逻辑 |

HTTP 语义约定的要点：

- Span 名称应为 `{method} {target}`；Server 端 `{target}` 用 `http.route`，Client 端用 `url.template`。规范明确 **Instrumentation 不得默认使用 URI path 作为 target**（高基数问题）。
- Server Span 必填：`http.request.method`、`url.path`、`url.scheme`；`http.route` 为条件必填；`http.response.status_code`、`error.type` 为条件必填。
- 版本变更：自 semconv v1.20.0 起，新属性取代旧的实验性属性（`http.method` → `http.request.method`、`http.status_code` → `http.response.status_code`、`http.url` → `url.full`、`http.target` → `url.path`、`http.host` → `server.address`）。迁移需通过环境变量 `OTEL_SEMCONV_STABILITY_OPT_IN=http` 或 `http/dup` 双写过渡。

### 4.3 指标方法论：RED 与 USE

| | RED | USE |
|---|-----|-----|
| 提出者 | Tom Wilkie | Brendan Gregg |
| 面向 | **服务**（请求侧） | **资源**（机器侧） |
| 三项 | Rate（每秒请求数）、Errors（失败请求数）、Duration（耗时分布） | Utilization（忙碌时间占比）、Saturation（排队量）、Errors（错误计数） |
| 适用 | HTTP / gRPC 微服务、API | CPU、内存、磁盘、网卡、线程池、连接池 |

RED 可视为 Google 四黄金信号（Latency、Traffic、Errors、Saturation）去掉 Saturation。Brendan Gregg 原文强调："低利用率不等于没有饱和"——长周期平均会掩盖短时 100% 的突发。

**为什么分位数比平均值重要**：延迟分布是右偏的，平均值落在"几乎没有请求"的中间地带。Prometheus 官方文档直接给出两条结论：

- 对预计算分位数做聚合是错的：`avg(http_request_duration_seconds{quantile="0.95"})` 被官方标注为 **BAD**，因为 "averaging the quantiles yields statistically nonsensical values"。
- 正确做法是先聚合直方图桶再算分位数：`histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))`。

原因是 histogram 的 bucket 计数是**可加的**，而 quantile 不是。

### 4.4 日志

结构化日志建议字段：`timestamp`（ISO-8601 / RFC 3339，UTC）、`level`、`service`、`trace_id`、`span_id`、`message`，以及业务字段（`user_id`、`agent_run_id`、`model`、`prompt_tokens` 等）。

日志必须是"数据"而非"文本"：文本日志只能被人 grep，无法按维度聚合、无法与指标联动。级别约定建议：`ERROR` = 需要人介入；`WARN` = 已降级或接近阈值；`INFO` = 生命周期事件；`DEBUG` = 排障期临时开启。成本上，建议对 `DEBUG` / 高频 `INFO` 做采样，但**错误日志全量**。

（上述字段清单与级别约定为工程实践惯例，未找到唯一官方依据。）

三者通过 `trace_id` 关联：日志直接记录当前 span 的 `trace_id` 与 `span_id`；指标通过 **Exemplar** 关联——OTel 定义 Exemplar 为"将 OpenTelemetry 上下文关联到某个 metric event 的记录值"，包含可选的 `trace_id` / `span_id`。于是一个 P99 分位点可以直接跳到产生该值的那条 trace。

### 4.5 采样策略

| | 头部采样 | 尾部采样 |
|---|---------|---------|
| 决策时机 | Span **创建时**（SDK `ShouldSample`） | trace 基本完整后（Collector） |
| 实现 | `AlwaysOn` / `AlwaysOff` / `TraceIdRatioBased` / `ParentBased` | Collector 的 tail sampling processor |
| 代价 | 极低 | 需在内存缓冲 span |
| 能否按错误 / 慢请求决策 | 不能 | 能 |

OTel SDK 规范明确：采样发生在 Span 创建流程中，因此所有 SDK 内置采样器都是头部采样。默认采样器是 `ParentBased(root=AlwaysOn)`；`TraceIdRatioBased` 会**忽略父级 SampledFlag**，因此必须包在 `ParentBased` 里使用。

尾部采样（Collector `tailsamplingprocessor`）：默认 `decision_wait` 为 **30 秒**，`num_traces` 默认 50000；策略包含 `status_code`、`latency`、`probabilistic`、`and` / `not` / `drop` / `composite` 等。硬约束是**同一 trace 的所有 span 必须送达同一个 Collector 实例**。

Agent 场景考量：错误请求应全采（用 `status_code: ERROR` 策略），因为错误样本稀少且价值最高；高成本请求（token 消耗大、耗时长）建议按 `latency` 阈值与 `numeric_attribute`（如 prompt token 数）策略定向保留，而非提高全局采样率——后者会线性放大存储成本却未必覆盖长尾。

## 5. 慢请求排查判定树

**第一步：看分位数，不看平均值。** 若 P50 平稳而 P99 抬升，是个别请求慢（依赖抖动、GC、冷启动、长 prompt）；若 P50 与 P99 同步抬升，是全量慢（容量、下游整体劣化）。

**第二步：链路分段计时。** `curl -w` 可用变量：

| 变量 | 含义 |
|------|------|
| `time_namelookup` | 从开始到域名解析完成 |
| `time_connect` | 从开始到与远端完成 TCP 连接 |
| `time_appconnect` | 从开始到 SSL 等握手完成 |
| `time_pretransfer` | 从开始到文件传输即将开始 |
| `time_redirect` | 所有重定向步骤的耗时 |
| `time_starttransfer` | 从开始到第一个字节即将传输（即 **TTFB**） |
| `time_total` | 整个操作的总时长 |

由此可推导：DNS = `time_namelookup`；TCP 建连 = `time_connect - time_namelookup`；TLS = `time_appconnect - time_connect`；TTFB = `time_starttransfer`；内容下载 = `time_total - time_starttransfer`。

**第三步：对比网关日志与应用日志。** 若 Nginx `$upstream_response_time` 很小而 `$request_time` 很大，耗时在网关侧（客户端慢、读请求体、缓冲）；若 `$upstream_response_time` 本身就大，耗时在应用内。ALB 侧对应 access log 的 `request_processing_time` / `target_processing_time` / `response_processing_time`。

**第四步：应用内按 span 拆解。** 以 SERVER span 为根，按 CLIENT span 排序，找出最长子调用是 DB、LLM 还是内部计算。

**第五步：区分"慢"与"堵"。** 若子调用自身耗时正常但父 span 很长，说明时间在**排队**——连接池等待、线程池队列、vLLM 的 `num_requests_waiting`。可观测口径是：延迟看分位数，积压看队列长度。

## 6. AI Agent 场景下的注意点

Agent 请求把生命周期的多个环节同时推到极限，这是它与普通 Web 请求最本质的差别。

### 6.1 耗时模型：TTFB 与总时长

TTFB 是从发起到收到第一个字节的时间（对应 curl 的 `time_starttransfer`）；总时长包含后续全部内容传输。

用户感知的"响应快慢"几乎完全由 TTFB 决定：在流式输出场景中，首个 token 出现后用户已进入阅读状态，后续 token 只要在持续产出即可接受。**因此 Agent 产品的核心 SLO 应设在 TTFB 而非端到端时长。**

### 6.2 LLM 推理的两阶段

- **prefill**：处理整个输入 prompt，填充 KV cache，**计算密集**，直接决定 TTFT。
- **decode**：逐 token 生成，**内存带宽密集**（受 HBM 带宽约束），决定 TPOT / ITL。

vLLM 官方博客用 roofline 模型说明：在饱和批大小 `B_sat` 以下，step 时间由 HBM 带宽主导，step 延迟近乎平坦；超过 `B_sat` 后内核转为计算受限，step 时间随 batch 增长。这直接给出优化方向的差异：

| | prefill（降 TTFT） | decode（降 TPOT） |
|---|-------------------|------------------|
| 瓶颈 | 算力（FLOPs） | 显存带宽 |
| 手段 | prefix cache 命中、缩短 prompt、chunked prefill | 提高 batch 摊薄权重读取、量化、投机解码 |

### 6.3 推理侧的官方指标

Prometheus 侧（`vllm:` 前缀，均为 Histogram）：

| 指标 | 官方描述 |
|------|---------|
| `vllm:time_to_first_token_seconds` | Time to first token (TTFT) |
| `vllm:inter_token_latency_seconds` | Inter-token latency |
| `vllm:e2e_request_latency_seconds` | End-to-end request latency |
| `vllm:request_prefill_time_seconds` | Request prefill time |
| `vllm:request_decode_time_seconds` | Request decode time |
| `vllm:request_queue_time_seconds` | Queue time |

注意：`vllm:time_per_output_token_seconds` 已标注 **DEPRECATED**，官方建议改用 `vllm:inter_token_latency_seconds`。

基准测试侧（`vllm bench serve`，客户端测量）的官方定义：

- **TTFT**：从发送请求到收到其第一个流式输出的时间。
- **ITL**：相邻流式输出之间的时间间隔，统计时聚合所有成功请求的这些间隔。
- **TPOT**：先按每个请求计算（排除第一个 token），再跨请求聚合，公式为 `(end-to-end latency − TTFT) / (number of output tokens − 1)`。

标准解码下 ITL 与 TPOT 接近；投机解码下一个流式输出可能含多个 token，ITL 只记输出间隔、不补零，TPOT 则把解码时间摊销到每个 token 上——两者会出现明显差异。

### 6.4 长任务的异步化

| 进度获取方式 | 优点 | 缺点 | 适用 |
|-------------|------|------|------|
| 轮询（polling） | 实现最简单、可穿透任何代理 | 有延迟与空转请求 | 任务时长不可预测、客户端简单 |
| 回调（webhook） | 无空转、实时 | 需可达的回调地址与鉴权、失败重试复杂 | 服务间集成、后台批处理 |
| SSE 进度推送 | 实时、单向、天然穿透 HTTP | 需处理重连与代理缓冲 | 前端展示进度 / token 流 |

这是根本解法：HTTP 层只负责提交与查询进度，任务由独立 worker 池执行，从而彻底解除"连接生命周期"与"任务生命周期"的绑定。

### 6.5 SSE 断线重连

- 服务端每个事件可带 `id:` 字段，用于设置 `EventSource` 对象的 last event ID。
- 重连时浏览器通过 **`Last-Event-ID`** 请求头上报该值。HTML 规范定义：该 header 在用户代理重建连接时上报，值可以是任意 UTF-8 字符串，但不得含 U+0000 NULL、U+000A LF、U+000D CR。
- `retry:` 字段指定重连时间（毫秒），必须为整数，非整数则该字段被忽略。
- 重连间隔的初始值由规范定义为 **user-agent-defined**；流传的"默认约 3000ms"未找到权威官方依据，属实现细节。浏览器原生 `EventSource` 自动重连，`retry:` 是唯一的配置手段，且规范未提供内置的指数退避。

**为什么必须在应用层实现游标**：`Last-Event-ID` 只带回一个不透明字符串，浏览器不保证"断点处零丢失"——断连期间服务端已产出的事件若未持久化，重连后无从回放。应用层必须把事件以游标（自增序号 / 时间戳）持久化到 Redis 或 DB，重连时按 `Last-Event-ID` 做范围查询并补发，才能保证 at-least-once。同时客户端需自行去重。

### 6.6 服务端如何感知客户端断连

ASGI 规范：`http.disconnect` 是 `receive` 事件，在响应已发送之后、或 HTTP 连接被关闭后调用 `receive` 时会投递给应用，"主要用于长轮询，以便在连接提前关闭时触发清理代码"。

落地方式：

- Starlette 提供 `disconnected = await request.is_disconnected()`，用于长轮询或流式响应中判断客户端是否已断开。
- Starlette 的 `Request.stream()` 在收到 `http.disconnect` 时会置位 `_is_disconnected` 并抛出 `ClientDisconnect`。
- Gunicorn 自 25.0.0 起提供 `asgi_disconnect_grace_period`（默认 **3 秒**），即客户端断连后留给 ASGI 应用处理 `http.disconnect` 的清理宽限期，超时后请求任务被取消。

**为什么直接关乎成本**：Agent 的一次请求背后可能是一次持续数十秒、按 token 计费的 LLM 生成。若服务端浑然不觉客户端已离开，就会继续为无人接收的结果付费。在 SSE / 流式生成循环中周期性检查 `is_disconnected()` 并在断开时主动取消上游生成任务，是 Agent 服务最直接的省钱手段。

### 6.7 连接占用是容量约束

每个挂起的 Agent 请求持续占用一个连接、一个协程与一份会话状态。相关默认值：

- `--limit-concurrency` 超限时立即返回 503 而不排队（源码默认为 `None`，即不限制，需显式配置才有保护）。
- `--timeout-keep-alive` 默认 5 秒。
- `--backlog` 默认 2048（操作系统级 accept 队列，实际生效值还要与 `somaxconn` 取小）。
- `--timeout-graceful-shutdown` 控制优雅退出的最长等待。

这些值共同决定了高峰期是排队、拒绝还是静默断开，必须与网关侧策略一并设计。

## 7. 各环节耗时量级参考

**这张表的定位是建立"什么算慢"的量级直觉，不是基准。** 所有数值随硬件、地理距离、并发水位大幅波动。

| 环节 | 量级 | 依据强度 |
|------|------|---------|
| DNS 解析 | 命中缓存 < 1ms；未命中递归 10–100ms | 工程推演 |
| TCP 握手 | ≈ 1×RTT：同机房 < 1ms；同城 1–5ms；跨城 20–50ms；跨国 100–300ms | 协议定义成立，RTT 数值为工程推演 |
| TLS 1.2 全握手 | ≈ 2×RTT | RFC 5246 |
| TLS 1.3 全握手 | ≈ 1×RTT；会话复用 0-RTT | RFC 8446 |
| Nginx 转发（本机开销，不含后端） | 亚毫秒 ~ 1ms | 工程推演 |
| 框架路由 + 参数校验 | 0.1–5ms | 工程推演 |
| 数据库简单查询（主键/索引命中，同机房） | 0.5–5ms | 工程推演 |
| Redis 读写（同机房） | 亚毫秒。官方 `redis-benchmark` 给出 SET `p50=0.143 msec`、LPUSH `p50=0.135 msec` | 官方文档 |
| 同机房内网 HTTP 调用（含连接复用） | 1–5ms | 工程推演 |
| LLM 首 token（prefill / TTFT） | 数百毫秒 ~ 数秒，随 prompt 长度近似线性增长；长上下文（100K+）可达数秒至十秒级 | 行业观测，非厂商官方基准 |
| LLM 每 token 生成（decode / TPOT） | 约 10–50ms/token，即 20–100 tokens/s；专用推理硬件可到 200+ tokens/s | 行业观测，非厂商官方基准 |

使用建议：把这张表当**数量级标尺**而非 SLA。真正需要的是在自己环境里测出 P50 / P95 / P99，然后与量级表对照判断"慢在哪一环"——例如"Redis 读 8ms"在本表对照下明显异常，而"LLM 首 token 1.2s"在长 prompt 下完全正常。

## 8. 常见问题与排查

| 症状 | 根因 | 排查路径 |
|------|------|---------|
| 健康检查全绿但用户大面积超时 | accept 队列溢出 | `ss -lnt` 看 Recv-Q 是否逼近 Send-Q；`nstat` 看 `TcpExtListenOverflows` 是否持续增长 |
| 大量 499 | 客户端或外层 LB 超时短于实际耗时 | 用 `$request_time` 判断是否聚集在整数秒 |
| 502 与 504 分不清 | 未区分"收到非法响应"与"没收到响应" | 看 error log 是 `upstream prematurely closed` 还是 `upstream timed out` |
| Nginx 机器上大量 TIME_WAIT | 未配 upstream keepalive 三件套 | 补 `keepalive` + `proxy_http_version 1.1` + `Connection ""` |
| 多标签页下 SSE 卡死 | HTTP/1.1 每域名 6 连接限制 | 启用 HTTP/2 |
| SSE 一直 Pending | `proxy_buffering` 默认 on | `proxy_buffering off` 或 `X-Accel-Buffering: no` |
| SSE 首次可见延迟高 | gzip 缓冲区攒数据 | 该 location 关闭 gzip |
| POST 请求被重复执行 | `proxy_next_upstream` 对已发出的非幂等请求重试 | 自查是否加了 `non_idempotent`；改为实现幂等键 |
| 上传接口磁盘 I/O 高 | 请求体超出 `client_body_buffer_size` 落临时文件 | 调大缓冲区，或改用对象存储直传 |
| 流式响应被代理缓存冻结 | 未声明 `Cache-Control`，被启发式缓存 | 显式加 `Cache-Control: no-cache` |
| 客户端断开后仍在烧 token | 生成循环未检查断连 | 周期性 `await request.is_disconnected()`，断开即取消上游任务 |
| P99 高但 P50 正常 | 长尾请求（长 prompt、依赖抖动） | 按 span 拆解定位；不要看平均值 |
| 下游全部正常但接口整体变慢 | 排队而非执行慢 | 看队列长度指标（连接池、vLLM `num_requests_waiting`） |

### 8.1 关于中间件顺序的真实安全案例

- **CVE-2025-29927（Next.js 中间件绕过，CVSS 9.1）**：源于框架对内部请求头 `x-middleware-subrequest` 的无条件信任，攻击者可借此跳过中间件鉴权层。
- **Black Hat USA 2026 披露的企业 Java 中间件漏洞链**：当鉴权 Filter 与 Servlet 分发器对同一 URL 的解析结论不一致时，认证边界即被穿透。

这两个案例共同指向一条结论：**中间件不应作为唯一的访问控制边界**。鉴权判断应在业务层重复一次，或至少在路由层做显式声明。

## 9. 自测问题

1. 一次请求经过哪七个环节？把它扩展成十道关卡后，多了哪三道？
2. SYN 队列与 accept 队列的区别是什么？accept 队列溢出时为什么应用日志里完全没有痕迹？
3. `somaxconn` 与应用程序 `listen(backlog)` 如何共同决定队列长度？
4. TCP keepalive 与 HTTP keep-alive 有何本质区别？为什么前者不能用来快速发现断连？
5. Nginx 与 upstream 的连接复用三件套是什么？缺一会发生什么，TIME_WAIT 堆在哪一侧？
6. 什么是传输层队头阻塞？HTTP/2 解决了吗？HTTP/3 呢？
7. HTTP/2 下使用 SSE 有哪两个必须注意的点？
8. 499、502、503、504 各自的精确成因是什么？502 与 504 的判别规则是什么？
9. `proxy_next_upstream` 对非幂等请求的默认行为是什么？为什么在 Agent 场景下放开它很危险？
10. `proxy_read_timeout` 计量的是总响应时长还是读间隔？这个区别对流式意味着什么？
11. 超时的收敛方向是什么？搞反后的三种具体表现是什么？
12. requests 库的默认超时是多少？不设置会怎样？
13. `traceparent` 四个字段各占多少位？采样标志应如何判断？
14. 为什么不能对预计算分位数做平均？正确的 PromQL 写法是什么？
15. 头部采样与尾部采样的区别是什么？为什么错误请求应用尾部采样全采？
16. `curl -w` 中如何推导出 TTFB？如何用 Nginx 日志判断耗时在网关侧还是应用侧？
17. 为什么 Agent 产品的 SLO 应设在 TTFB 而非端到端时长？
18. prefill 与 decode 的性能瓶颈分别是什么？优化方向有何不同？
19. `Last-Event-ID` 机制为什么不足以保证断点处零丢失？应用层要做什么？
20. 服务端如何感知客户端断连？为什么这直接关乎成本？

## 10. 参考来源

**网络与协议**

1. Linux 内核文档 — `ip-sysctl.txt`，https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
2. RFC 9112（HTTP/1.1）§9.3 Persistence，https://httpwg.org/specs/rfc9112.html#persistent.connections
3. RFC 9114（HTTP/3 over QUIC），https://www.rfc-editor.org/rfc/rfc9114.html
4. MDN — Transfer-Encoding，https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Transfer-Encoding
5. MDN — Cache-Control，https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Cache-Control
6. MDN — Using server-sent events，https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events
7. gRPC 官方 — Core concepts，https://grpc.io/docs/what-is-grpc/core-concepts/
8. Cloudflare Blog — Introducing TLS 1.3，https://blog.cloudflare.com/introducing-tls-1-3/
9. ss(8) Linux manual page，https://man7.org/linux/man-pages/man8/ss.8.html

**Nginx 与网关**

10. Nginx — ngx_http_proxy_module，https://nginx.org/en/docs/http/ngx_http_proxy_module.html
11. Nginx — ngx_http_upstream_module，https://nginx.org/en/docs/http/ngx_http_upstream_module.html
12. Nginx — ngx_http_core_module，https://nginx.org/en/docs/http/ngx_http_core_module.html
13. Nginx — ngx_http_gzip_module，https://nginx.org/en/docs/http/ngx_http_gzip_module.html
14. Nginx — ngx_http_v2_module，https://nginx.org/en/docs/http/ngx_http_v2_module.html
15. Maxim Dounin 于 nginx-devel 邮件列表对 499 语义的解释，https://nginx.org/pipermail/nginx-devel/2015-June/007034.html
16. MDN — 502 / 503 / 504，https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/502

**服务器与客户端超时**

17. Uvicorn — Settings，https://raw.githubusercontent.com/encode/uvicorn/main/docs/settings.md
18. Uvicorn — Config 源码，https://raw.githubusercontent.com/encode/uvicorn/main/uvicorn/config.py
19. Gunicorn — Settings，https://gunicorn.org/reference/settings/
20. AWS ELB — Application Load Balancers，https://docs.aws.amazon.com/elasticloadbalancing/latest/application/application-load-balancers.html
21. httpx — Timeouts，https://www.python-httpx.org/advanced/timeouts/
22. aiohttp — Client Quickstart，https://docs.aiohttp.org/en/stable/client_quickstart.html
23. Requests — Advanced Usage（Timeouts），https://requests.readthedocs.io/en/latest/user/advanced/

**可观测**

24. W3C Trace Context Level 1，https://www.w3.org/TR/trace-context/
25. W3C Baggage，https://www.w3.org/TR/baggage/
26. OpenTelemetry Tracing API，https://opentelemetry.io/docs/specs/otel/trace/api/
27. OpenTelemetry Trace SDK（采样），https://opentelemetry.io/docs/specs/otel/trace/sdk/
28. OpenTelemetry Semantic Conventions: HTTP Spans，https://opentelemetry.io/docs/specs/semconv/http/http-spans/
29. OpenTelemetry Metrics Data Model（Exemplars），https://opentelemetry.io/docs/specs/otel/metrics/data-model/
30. OpenTelemetry Collector Tail Sampling Processor，https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/processor/tailsamplingprocessor/README.md
31. Prometheus — Histograms and summaries，https://prometheus.io/docs/practices/histograms/
32. Brendan Gregg — The USE Method，https://www.brendangregg.com/usemethod.html
33. OpenTelemetry — FastAPI Instrumentation，https://opentelemetry-python-contrib.readthedocs.io/en/latest/_modules/opentelemetry/instrumentation/fastapi.html
34. curl — Available --write-out variables，https://everything.curl.dev/usingcurl/verbose/all-variables.html

**Agent 场景**

35. vLLM — Benchmarking CLI（TTFT / ITL / TPOT 定义），https://docs.vllm.ai/en/latest/benchmarking/cli/
36. vLLM — Metrics（design），https://docs.vllm.ai/en/latest/design/metrics/
37. vLLM — Anatomy of a High-Throughput LLM Inference System，https://vllm-project.github.io/2025/09/05/anatomy-of-vllm.html
38. ASGI — HTTP & WebSocket Message Format（`http.disconnect`），https://asgi.readthedocs.io/en/latest/specs/www.html
39. Starlette — Requests（`is_disconnected`），https://www.starlette.io/requests/
40. HTML Living Standard — Server-sent events（`Last-Event-ID`），https://html.spec.whatwg.org/dev/server-sent-events.html

**基准与安全案例**

41. Redis — Benchmarks，https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/
42. Next.js Middleware Bypass Vulnerability（CVE-2025-29927），https://aardwolfsecurity.com/?p=3799
