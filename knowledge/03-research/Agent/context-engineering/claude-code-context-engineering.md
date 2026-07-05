---
aliases: [Claude Code 上下文管理, Claude Code 规则体系, Context Engineering, Rules 与 Skills]
tags: [Context-Engineering, Agent, Claude-Code, Rules, Skills, Prompt-Caching, Context-Compression, Harness]
related:
  - "../harness-engineering/claude-code-harness.md"
  - "./memory/claude-code-memory.md"
  - "./memory/agent-memory-survey.md"
---

# Claude Code 上下文工程与用户规则体系方法论

> 调研对象：Claude Code 在多轮、长上下文、跨会话场景下的**上下文管理机制**和**用户规则/Skills 加载体系**。
>
> 本文档分两部分：
> - **第一部分：上下文工程**——管线、压缩、缓存、投影等"基础设施"
> - **第二部分：用户规则与 Skills 体系**——Rules/Skills/Commands 加载机制
>
> 本文是方法论提炼，**不涉及具体实现细节**，重点在思路、原则和模式。

---

## 目录

### Part 1: 上下文工程基础
1. [核心心法：上下文是被"组装"的，不是"累积"的](#1-核心心法上下文是被组装的不是累积的)
2. [两层主循环：turn vs query iteration](#2-两层主循环turn-vs-query-iteration)
3. [每轮 API 请求的拼装管线（核心）](#3-每轮-api-请求的拼装管线核心)
4. [system prompt 的"静态/动态分离"架构](#4-system-prompt-的静态动态分离架构)
5. [投影 vs 替换 vs 压缩：三种"收缩"手段](#5-投影-vs-替换-vs-压缩三种收缩手段)
6. [压缩栈：6 层递进的预算与回收](#6-压缩栈6-层递进的预算与回收)
7. [tool_result 的多层预算机制](#7-tool_result-的多层预算机制)
8. [每轮刷新的"全链路缓存策略"](#8-每轮刷新的全链路缓存策略)

### Part 2: 用户规则与 Skills 体系
9. [核心心法：规则体系的"在场但不污染"](#9-核心心法规则体系的在场但不污染)
10. [规则加载的三个维度](#10-规则加载的三个维度)
11. [Rules 体系：5 层优先级 + 项目级规则分层](#11-rules-体系5-层优先级--项目级规则分层)
12. [Rules 注入：每轮 prepend 的"隐身"机制](#12-rules-注入每轮-prepend-的隐身机制)
13. [Conditional Rules：按需激活的路径条件规则](#13-conditional-rules按需激活的路径条件规则)
14. [Nested Memory：子目录规则的"自动浮现"机制](#14-nested-memory子目录规则的自动浮现机制)
15. [Skills 体系：发现 + 执行 + 条件激活](#15-skills-体系发现--执行--条件激活)
16. [Skills 的"元数据 + 正文"分离原则](#16-skills-的元数据--正文分离原则)
17. [动态 Skill 发现：从"用户写好"到"系统找出来"](#17-动态-skill-发现从用户写好到系统找出来)
18. [Custom Commands：和 Skills 本质相同的遗留体系](#18-custom-commands和-skills-本质相同的遗留体系)
19. [三条路径的对比与协同](#19-三条路径的对比与协同)
20. [规则体系的缓存与失效策略](#20-规则体系的缓存与失效策略)

### Part 3: 综合
21. [可借鉴的工程原则（24 条）](#21-可借鉴的工程原则24-条)
22. [总结：上下文工程与规则体系的统一认知](#22-总结上下文工程与规则体系的统一认知)

---

# Part 1: 上下文工程基础

---

## 1. 核心心法：上下文是被"组装"的，不是"累积"的

Claude Code 在上下文工程上的根本认识是：

> **API 看到的 messages 不是"历史累积"，而是每轮重新"组装"出来的视图。** 真实的 REPL 状态可能很大，但每轮发给 API 的 messages 是经过多步"收缩"和"注入"之后的派生视图。

由此推导出三个基本动作：

1. **"组装"是显式的多步管线**：每轮发 API 之前，messages 走 6-10 个明确的处理步骤（filter、compact、collapse、normalize、inject、prepend）。
2. **每步都是为了解决一个具体问题**：压缩解决 token 不够用、cache 控制解决费用、normalize 解决协议兼容性、prepend 解决"规则在场"。
3. **REPL 状态 ≠ API 状态**：UI 上看到的是完整的，但 API 上看到的是收缩后的。这是上下文工程的根本张力。

### 1.1 一句话总结

> **上下文工程 = "把模型能看到的"和"模型实际想看/需要看"的差异，用工程化的方式管理起来。**

---

## 2. 两层主循环：turn vs query iteration

理解 Claude Code 上下文管理的第一个关键认识是：**用户视角的"轮次" ≠ 内部的 iteration**。

### 2.1 两者的区别

| 维度 | 用户视角的 "turn" | 内部的 "query iteration" |
|------|------------------|--------------------------|
| 触发者 | 用户输入 | query 主循环 |
| 一次有多少 | 1 | 1..N（典型 1，可能 5-20，长任务可能上百）|
| 一次有多少 API call | N | 1 |
| 包含什么 | 用户文本 + 助手最终消息 + 中间所有 tool 消息 | 一次完整的"准备→发→收→执行→拼回"|

### 2.2 一个完整的 turn 例子

```
turn 1: 用户消息"修一下 foo.ts 里的 bug"
  iter 1:  send {user, claudeMd_prefix}
            ← {assistant: "我看一下 foo.ts", tool_use(Read)}
            → execute(Read)
            → 拼回 tool_result
  iter 2:  send {user, claudeMd, ..., assistant, user(Read result)}
            ← {assistant: "问题是 X，我来改", tool_use(Edit)}
            → execute(Edit)
  iter 3:  send {..., Edit result}
            ← {assistant: "改完了,顺便跑一下测试", tool_use(Bash)}
            → execute(Bash)
  iter 4:  send {..., Bash result}
            ← {assistant: "测试通过"}         ← stop_reason !== tool_use
            → query() return { reason: 'completed' }
            → submitMessage() 结束
turn 2: 用户消息"再看看 bar.ts"
  ... 重新走一遍
```

### 2.3 方法论价值

> **一个用户消息可能产生 N 次 API 调用**。理解这一点对上下文工程至关重要：
> - 每次 API 调用都要重新"组装" messages
> - 每次 API 调用都要重新做"压缩 / 预算"检查
> - 任何一次失败（413、max_output_tokens）都需要保留恢复点

**核心动作**：
- 跨 turn 状态（turnCount、maxOutputTokensRecovery、hasAttemptedReactiveCompact 等）必须持久
- 单 turn 内的状态是临时的，结束后可以释放
- 跨 turn 状态都通过 `toolUseContext` 或 `appState` 传递，不依赖 messages 数组

---

## 3. 每轮 API 请求的拼装管线（核心）

### 3.1 整体数据流（10 步）

```
state.messages (REPL 真实历史)
   │
   │  ① getMessagesAfterCompactBoundary
   │     - 丢弃 compact boundary 之前的所有内容
   │     - 若 HISTORY_SNIP 开启：projectSnippedView 投影
   ▼
messagesForQuery (被 snip/MC/compact 缩小过)
   │
   │  ② applyToolResultBudget
   │     - 超出预算的 tool_result 持久化到磁盘 + 替换为预览
   ▼
messagesForQuery (tool_result 已收缩)
   │
   │  ③ snipCompactIfNeeded (HISTORY_SNIP 时)
   │     - 注入 [id:xxx] tag 到 user 消息末尾
   ▼
messagesForQuery (已带短 ID)
   │
   │  ④ microcompact (autoCompact 之前)
   │     - 条件触发 time-based / cached MC
   ▼
messagesForQuery (可清空的 tool_result 已清空)
   │
   │  ⑤ contextCollapse (CONTEXT_COLLAPSE 时)
   │     - 投影视图，去掉已 commit 的折叠
   ▼
messagesForQuery (视图进一步收缩)
   │
   │  ⑥ autocompact (可能)
   │     - 若超阈值，rebuild 为 [boundary, summary, ...]
   ▼
postCompactMessages (压缩后)
   │
   │  ⑦ normalizeMessagesForAPI
   │     - 12 步规范化（过滤、合并、规范化等）
   ▼
messagesForAPI
   │
   │  ⑧ ensureToolResultPairing
   │     - 补 orphan tool_use 的 synthetic tool_result
   │     - 删 orphan tool_result
   ▼
messagesForAPI
   │
   │  ⑨ stripAdvisorBlocks / stripExcessMediaItems
   ▼
messagesForAPI
   │
   │  ⑩ prependUserContext
   │     - 在最前面插入 isMeta 的 user 消息
   │       包含 <system-reminder> 包裹的 Rules + currentDate
   ▼
final messages 数组  (发给 SDK)
   │
   ▼
Anthropic SDK messages.create({ system, messages, tools })
```

### 3.2 每一步的目的

| 步骤 | 解决什么问题 |
|------|------------|
| ① getMessagesAfterCompactBoundary | 压缩过的旧内容不再发 |
| ② applyToolResultBudget | 单 message 体积不能太大 |
| ③ snipCompactIfNeeded | 长程历史的"投影" |
| ④ microcompact | 旧 tool_result 内容清空 |
| ⑤ contextCollapse | 单 tool_result 粒度的折叠 |
| ⑥ autocompact | 实在装不下了，summary 替代 |
| ⑦ normalizeMessagesForAPI | 协议兼容性、流式分片合并 |
| ⑧ ensureToolResultPairing | API 强制 tool_use ↔ tool_result 配对 |
| ⑨ stripAdvisorBlocks / stripExcessMediaItems | 减少不必要内容 |
| ⑩ prependUserContext | 把 Rules 注入到 messages 头部 |

### 3.3 方法论价值

> **每一步都对应一个具体的"上下文难题"**——没有一步是"无意义"的，每一步都在解决一个具体问题。理解这一点，设计自己的 agent 系统时就能"按问题找方法"，而不是"按方法找问题"。

---

## 4. system prompt 的"静态/动态分离"架构

### 4.1 静态段 vs 动态段

```
getSystemPrompt()
   │
   ├── [静态段] 不变 ⇒ 跨 session 缓存
   │   ├─ getSimpleIntroSection         ← 身份、URL 禁令
   │   ├─ getSimpleSystemSection        ← 权限模式、标签说明、prompt injection 防御
   │   ├─ getSimpleDoingTasksSection    ← 编码风格（不过度抽象、不加不必要功能）
   │   ├─ getActionsSection             ← 风险行动确认
   │   ├─ getUsingYourToolsSection      ← 优先专用工具、必须用 TodoWrite 拆解任务
   │   └─ (可选) getAgentToolSection
   │
   ├── [BOUNDARY MARKER]               ← 切分点
   │
   └── [动态段] 每轮可能变 ⇒ 不缓存
       ├─ session_guidance（skill 列表）  ← 动态
       ├─ memory（AutoMem 使用指引）        ← 半动态
       ├─ env_info_simple（cwd/git/平台）  ← 动态
       ├─ language（用户语言偏好）          ← 半动态
       ├─ output_style                     ← 半动态
       ├─ mcp_instructions（DANGEROUS）    ← 强制 uncached
       └─ scratchpad / frc / summarize...
```

### 4.2 关键认识

> **静态段被切出来打上"跨 session 缓存"标记；动态段打上"每次唯一"标记。**

- 归因头打"每次唯一"标记（避免重放）
- 静态段打"跨 session"标记（1P）或"组织级"标记（3P）
- 动态段打"每次唯一"标记

**这意味着**：跨 session、跨 turn，只要用户没改 system prompt，**所有"行为宪法"完全不需要重新计算或重新传输**。这是整个 harness 能"低成本地每轮强制重新声明规则"的物理基础。

### 4.3 静态段通常承载什么

| 段 | 内容 |
|----|------|
| intro | AI 身份、URL 生成禁令、cyber 风险声明 |
| system | 工具执行权限模式说明、`<system-reminder>` 标签说明、**prompt injection 防御**、上下文自动压缩说明 |
| doing tasks | 编码风格（不过度抽象、不加不必要功能、不预测时间、报错诚实）|
| actions | **风险行动确认**（删除、强制推送、CI/CD 修改、发消息、共享状态等）|
| using your tools | 优先专用工具而非 Bash + **必须用 TodoWrite/TaskCreate 拆解任务** + 并行调用原则 |
| agent tool | subagent 使用指引 |

### 4.4 方法论价值

> **静态/动态分离是"低成本地每轮重申规则"的前提**。如果不分离，每次修改任何一行 system prompt 都会让所有 cache 失效。

**设计原则**：
- "长期不变"的规则放静态段
- "运行时可能变"的放动态段
- "每次必须唯一"的（如 attribution header）放最前面
- 归因头永远不缓存（每次唯一避免重放）

---

## 5. 投影 vs 替换 vs 压缩：三种"收缩"手段

### 5.1 三个概念的根本区别

| 操作 | 数据在 REPL 还在吗？ | 数据在磁盘？ | 发给 API？ |
|------|------------------|----------|----------|
| **预算+替换**（applyToolResultBudget）| ✅（preview 字符串）| ✅（完整内容）| ✅（小预览）|
| **投影**（snip / collapse）| ✅（完整内容）| ❌ | ❌（短 ID 代替）|
| **压缩**（autoCompact）| ❌（被 splice 删除）| ❌（除非 session log）| ✅（summary）|

### 5.2 投影（Projection）—— 详解与具体例子

**核心思想**：REPL state 里**仍然保留**完整数据，但**这次不发**给 API。下次需要时再"投影回来"。

打个比方：你书架上有 1000 本书，但你现在写作只需要参考其中 50 本。你**没有把另外 950 本扔掉**（扔了就没了），只是**暂时从桌面上收起来**到看不见的柜子里。下次你要写另一章时，可能又需要那 950 本中的 200 本——你再把它们从柜子里拿出来放到桌面上。

**关键**：数据没有被修改或删除，只是"在这一次 API 调用中不发送"。

#### (a) Snip 投影 — "用短 ID 代替整段历史"

**场景**：你和模型已经聊了 30 轮，中间有大量文件读取结果（比如 `tu_2` 是一个 80KB 的 grep 结果）。对话还在继续，模型要写新代码，**不再需要**那个旧的 grep 结果了。

**Snip 投影做的事情**：

```
REPL state 实际内容（UI 上你看到的完整历史）：
  [u0, "帮我找所有 useState 用法", asst1, tu_grep(80KB 结果), asst2, tu_edit, asst3, ...]

                                        ↓
                              snip 工具标记 tu_2 为"可剪"

发给 API 的视图（投影后）：
  [u0, "帮我找所有 useState 用法", asst1, [id:abc123], asst2, tu_edit, asst3, ...]
   ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑  ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
   80KB 的 tu_2 不见了，替换为一个短 ID [id:abc123]
```

**此时**：
- REPL state 里 tu_2 仍然是完整的 80KB 内容（你在 UI 上翻到第 2 轮仍能看到它）
- 但这次 API 请求中，模型只看到 `[id:abc123]` 这个短 tag
- 如果模型说"等等，我刚才看到那个 grep 结果里有条记录"，系统可以把 `[id:abc123]` 展开回完整内容重新发给 API（因为 REPL 里还存着）

**类比**：你把一本不常用的书从书桌上放回书架，但书架上还留着——下次想查随时可以再拿下来。

#### (b) Context Collapse 投影 — "把单个大文件内容折叠"

**场景**：模型读了一个 80KB 的文件 `auth.ts`，然后做了 5 轮编辑操作。现在已经到第 15 轮了，上下文使用量到了 90%，需要释放空间。

**Context Collapse 做的事情**：

```
REPL state 实际内容：
  [u0, asst1, tu_readFile(auth.ts, 80KB), asst2, tu_edit1, asst3, tu_edit2, ...]

                                       ↓
                              上下文到 90%，触发 commit 折叠

发给 API 的视图（投影后）：
  [u0, asst1, [id:fold1], asst2, tu_edit1, asst3, tu_edit2, ...]
   ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑  ↑↑↑↑↑↑↑↑↑↑↑↑
   80KB 的 auth.ts 内容不见了，替换为 [id:fold1]

   但 asst2（"我看了 auth.ts，发现 login() 函数有问题"）和后续
   的编辑结果仍然完整——没有必要折叠它们，因为它们是"结论"
```

**此时**：
- REPL state 里 tu_readFile 仍然是 80KB 的完整内容
- API 只看到短 ID `[id:fold1]`
- 如果下一个工具需要再次 read 这个文件，`fileStateCache` 会从缓存中返回"Already read"（**不会**重新注入 80KB）
- 如果模型需要回顾文件细节，系统可以按需展开 `[id:fold1]` 回到 80KB

**类比**：你写了一篇文章，其中引用了一段很长的代码。写完分析后你觉得没必要每次审稿都带着这段代码——你把它折叠成一个"展开/折叠"按钮。编辑器里还在，但打印时只显示折叠标记。

#### (c) Compact Boundary 切片（类投影）

**注意**：这个严格来说是"切片"而不是"投影"，因为 splice 删除了旧数据，但它和投影共享"只发 API 所需部分"的思想。

**场景**：运行 auto-compact 之后，旧历史被总结成了一个 summary，BOUNDARY 之前的旧内容从 mutableMessages 中 splice 删除。

```
REPL state 实际内容：
  [u0, asst1, tu1, asst2, tu2, ..., asst30, BOUNDARY, summary, asst_after_1, ...]

                                       ↓
                              触发 auto-compact，fork agent 生成 summary

发给 API 的视图（切片后）：
  [BOUNDARY, summary, asst_after_1, ...]
   ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
   BOUNDARY 之前的旧历史全部不发了
   BOUNDARY 本身起到标记作用——告诉模型"之前的内容被压缩过"
```

**与投影的区别**：这里的旧数据从 mutableMessages 中被 splice 删除了（不可逆），但 transcript 文件（磁盘上的 session log）里仍然保留了完整的旧历史。所以如果需要，可以从 transcript 恢复——但成本比展开短 ID 高得多。

#### (d) 一个完整的流程例子：从"投影"到"需要时再展开"

```python
# 场景：模型在处理一个 20 轮的长对话
# 第 3 轮包含一个 80KB 的 grep 结果

# 第 5 轮 —— snip 投影触发
state.messages[3] = {type:'user', content: [/* 80KB grep 结果 */]}
# → projectSnippedView() 返回：
#   [u0, asst1, [id:s1], asst4, u5]
#   REPL state 不变，但 API 只看到 [id:s1]

# 第 10 轮 —— 模型说"等等，第 3 轮的 grep 结果里有个匹配..."
# 系统检测到模型引用 [id:s1]
# → 把 [id:s1] 展开回 80KB 完整内容
# → 下一轮 API 请求里，模型看到了完整内容：
#   [u0, asst1, (80KB 完整 grep 结果), asst4, ...]
#   ↑ 不需要重新 Read 磁盘文件，直接从 REPL state 取回
```

**这就是投影的核心优势**：数据在 REPL state 里随时可用，不需要额外的磁盘 I/O 就能重新展示给模型。

### 5.3 替换（Replacement）

替换是**真的改了 state**（不可逆），跟投影完全不同。

**关键点**：`applyToolResultBudget` 的"替换"是**单向、永久**的。一旦 tu_1 被替换成 preview：
- 之后每轮 iteration 都会从 `replacements.get('tu_1')` 取回**同样的字符串**塞回去
- 绝不会重新计算 preview（否则 prompt cache 会因为 byte mismatch 而 miss）

### 5.4 压缩（Compression）

**核心思想**：**真的把旧内容扔掉**，换成一段 summary。

```
turn 1: 读 5 个文件，REPL state 增长到 400KB
turn 2: 改文件
turn 3: 跑测试
...
turn 30: REPL state 累计 1MB, token 数 = 950K（假设窗口 1M）

→ tokenCountWithEstimation(messages) >= 980K 阈值
→ 触发 autoCompact：
   1) fork 一个临时 agent（独立 context）
   2) 把整个 messages 喂给它
   3) 让它生成一段"对话摘要"（~3-5K tokens）
   4) 拿到 summary 后，主循环 yield:
      - SystemMessage { type: 'compact_boundary', ... }
      - UserMessage { isCompactSummary: true, content: '<summary>' }
   REPL state 改造前后：
   改造前: [u0, asst1, tu1, asst2, tu2, ..., asst30]   ← 1MB
   改造后: [BOUNDARY, summary, asst30]                  ← 5KB
```

### 5.5 现实类比

| 机制 | 类比 |
|------|------|
| **投影** | 看书时把不相关的章节用书签夹起来放一边，没翻到就先不看 |
| **替换** | 翻拍一张照片存档，桌上只放小照片（原始细节在硬盘）|
| **压缩** | 写一份读书笔记，原始章节扔进废纸篓 |
| **预算** | 桌面上只允许摊开 5 本书，否则必须先把某本收起来 |

### 5.6 方法论价值

> **理解这三个概念的区别，是设计好 agent 上下文管理的关键**。新手经常把"投影"和"压缩"混为一谈——它们一个可逆一个不可逆，**这个区别决定了"模型下次还能不能看到旧内容"**。

---

## 6. 压缩栈：6 层递进的预算与回收

### 6.1 6 层全景对比

| 机制 | 触发条件 | 影响范围 | 持久性 | 风险/权衡 |
|------|---------|---------|--------|----------|
| **Tool Result Budget** | 每 message 工具结果 > 50K 字符 | 单个 user message | 持久化到磁盘；state frozen 跨轮 | 替换预览可能丢失细节 |
| **Time-based MC** | 距 lastAssistant > 60 min | 所有可压缩 tool_result | 清空 content（[Old tool result cleared]）| 模型看不到旧内容 |
| **Cached MC** | 累计数 > GrowthBook 阈值 | API 层删旧 tool | cache_edits 服务端做 | 服务端能力依赖 |
| **Context Collapse** | 90%/95% 上下文 | 按需 commit 单 tool | commit log 持久 | 单 tool 粒度 |
| **Snip Compact** | 由 snip tool 显式触发 | 整条 message 投影 | projection-based | 显式操作 |
| **Auto-Compact** | token > threshold - 13K | 整段历史 fork 总结 | splice mutableMessages | 损失细粒度 |
| **Reactive Compact** | API 返回 413 | 整段历史 | splice + retry | 抢救失败 turn |

### 6.2 6 层的执行顺序

```
每轮 iteration 顺序执行：

1. toolResultBudget  ──  超 50K/msg  → 持久化到磁盘
                                  (这层最细粒度、最先)
2. snip compact      ──  长程历史的 message 投影掉
3. microcompact      ──  旧 tool_result 清空（time-based）
                     ─  旧 tool_result 标记 cache_edits（cached）
4. context collapse  ──  按需 commit 单个 tool_result 折叠
5. auto-compact      ──  超 13K 缓冲   → fork agent 总结
                     (这层最重、最后)
```

**核心认识**：每一层都不重做上层的事；**越往上越暴力**。

### 6.3 Auto-Compact 详解

```text
触发条件: tokenCountWithEstimation(messages) - snipTokensFreed
          >= getAutoCompactThreshold(model)
阈值:    effectiveContextWindow - AUTOCOMPACT_BUFFER_TOKENS (13k)

流程:
1. 递归保护: querySource=='session_memory' 或 'compact' → 跳过
2. circuit breaker: 连续 3 次失败 → 跳过
3. !isAutoCompactEnabled() → 跳过
4. context collapse 模式 → 让 collapse 处理 → 跳过
5. reactive-only 模式 → 让 reactive 处理 → 跳过
6. tokenCount >= threshold → 触发
7. trySessionMemoryCompaction（feature flag 控制）
8. compactConversation → fork agent
   - strip images
   - strip reinjected attachments
   - 调用模型生成 summary
   - 若 summary 自身超限 → truncateHeadForPTLRetry 重试 3 次
9. 成功 → yield boundary + summary + 重新注入附件
10. 失败 → tracking.consecutiveFailures++
```

### 6.4 Reactive Compact（API 错误抢救）

当 API 返回 `413 prompt-too-long` 时，reactive compact 会**在用户不知情的情况下**自动压缩并重试。

**关键设计**：
- "withhold" pattern：API 返回 413 时不立即 yield 给用户，尝试 reactive 压缩。失败才显式 yield。
- `hasAttemptedReactiveCompact` 防止无限循环（一次 turn 内只尝试一次）
- **taskBudget carryover**：跨 compact boundary 累加 preCompact 的 finalContextWindow，保证 server-side 预算仍准确

### 6.5 Token Budget（5xx 任务限制）

- 触发：turn output tokens < budget × 0.9，**且** 不是 diminishing（连续 3 轮 < 500 tokens 增量）
- 行为：注入 `nudgeMessage`（如"you're at 60% of budget, keep going"）到 messages 末尾，continue 下一圈
- 终止条件：达到 90% 或 diminishing returns → 停止

### 6.6 方法论价值

> **6 层压缩栈是"多策略协同"的典型**——不同层解决不同问题（单 message 太大 vs 长程历史太多 vs 整体超过窗口），互不冲突、各司其职。设计自己的 agent 系统时，应该按"问题粒度"分层。

**设计原则**：
- **越细粒度的层越先执行**（预算保护优于整体压缩）
- **越暴力的层越靠后**（autoCompact 是最后手段）
- **每层都尽可能保持 prompt cache 命中**（microcompact 优先用 cache_edits 而非重写）

---

## 7. tool_result 的多层预算机制

tool_result 体积常常爆炸（Read 整个 src/、Bash 输出 100K 行），所以有**5 层递进的预算**。

### 7.1 5 层预算

#### 第 1 层：单工具自身的 `maxResultSizeChars`

每个工具在 Tool 接口里声明 maxResultSizeChars。例如 Read 是 Infinity（由 Read 自己的 maxTokens 控制），Bash 有具体上限。

#### 第 2 层：每 message 的总预算

```
每个 user message 内 所有 tool_result 块的总字符数
   > MAX_TOOL_RESULTS_PER_MESSAGE_CHARS (默认 50000 字符)
      → 选最大的 fresh tool_result 持久化到磁盘
      → 替换为 preview（"<persisted-output>\n... first 2KB ..."
                          + path hint\n...</persisted-output>"）
```

**关键设计**：
- **Stable 状态**：`ContentReplacementState`（seenIds + replacements）跨轮持久
  - 被替换过 → 之后每轮从 replacements.get(id) 重新 apply，**byte-identical**
  - 没被替换过 → 之后每轮都跳过（避免破坏 cache prefix）
- **Skip 集合**：`maxResultSizeChars = Infinity`（如 Read）的工具永远不被这一层持久化

#### 第 3 层：Time-based Microcompact

- 触发：`now - lastAssistantTimestamp > 60 min`（cache TTL 已冷）
- 效果：清空所有可压缩 tool_result（除了最近 keepRecent=5 个），content 设为 `"[Old tool result content cleared]"`

#### 第 4 层：Cached Microcompact

- **不修改 messages 本体**
- 在 API 调用时插入 `cache_reference` 和 `cache_edits` 块，让服务端删除旧 tool_result 而**保留 cache prefix**
- 触发阈值由 GrowthBook 配置

#### 第 5 层：Context Collapse

- **最细粒度**：可对单个 tool_result commit 折叠
- 投影视图：`projectView()` 在读时按需展开已折叠的内容
- 90% 上下文时 commit，95% 时 blocking spawn 折叠

#### 第 6 层：Auto-Compact（最重）

- 触发：token count ≥ effectiveContextWindow - 13K
- 流程：trySessionMemoryCompaction（优先）→ compactConversation（fork agent 生成 summary）

### 7.2 一个完整的例子

场景：Read 一个 80KB 文件，模型想知道完整内容。

```
Read(auth.ts) [第一次]
   ↓
   80KB tool_result (tu_1)
   ↓
   下一圈 applyToolResultBudget
   tu_1 80KB > 50K 阈值
   → 写入磁盘：~/.cline/.../tool-results/tu_1.txt
   → 替换为 2KB preview + 路径提示
   → seenIds.add('tu_1')，replacements.set('tu_1', preview)

模型想知道完整内容:
Read(/.../tool-results/tu_1.txt)
   ↓
   80KB tool_result (tu_2)
   ↓
   下一圈 applyToolResultBudget
   tu_2 的工具是 Read → 在 skipToolNames 里 → 跳过！
   80KB 完整传给模型 ✅
   
   # Read 工具的 maxResultSizeChars = Infinity（豁免）
   # 防止"压缩→读→再压缩"死循环
```

**关键设计**：Read 工具的 `maxResultSizeChars = Infinity`。如果 Read 工具自己的输出也被压缩，那"压缩→读 txt→再压缩→再读 txt"就成了**真正死循环**——模型永远看不到完整内容。

### 7.3 re-read 同一源文件：fileStateCache 短路

```
Read(auth.ts) [第二次]
   ↓
   fileState.get('/path/auth.ts') → 命中
   ↓
   返回简短 "Already read"
   不返回 80KB
```

`fileStateCache` 是 LRU 100 entries / 25MB，专门挡"读过的再读"。

### 7.4 方法论价值

> **5 层预算 + Read 工具豁免 + fileStateCache 短路 = 既保护了 prompt cache，又保证模型不会陷入"永远看不到完整内容"的死循环。**

**核心设计原则**：
- **预算是多层的**——单 message 50K、单工具 maxResultSizeChars、整体 90% token budget
- **替换是 byte-identical 的**——一旦替换过，之后每轮都从 cache 里取同样的字符串塞回去
- **豁免是有选择的**——Read 工具不被压缩，因为它自己就是"看完整内容"的工具
- **短路是 LRU 的**——同一文件再读不重新注入

---

## 8. 每轮刷新的"全链路缓存策略"

### 8.1 缓存策略总览

| 内容 | 缓存方式 | 刷新触发条件 |
|------|----------|-------------|
| **Rules (getMemoryFiles)** | memoize | `/clear`、`/compact`、工作树切换、设置同步 |
| **Rules → UserContext** | memoize (getUserContext) | 同 Rules 缓存清除时 |
| **Skills (getSkillDirCommands)** | memoize (by cwd) | `/clear`、`/compact`、动态发现、插件重载 |
| **Commands (loadAllCommands)** | memoize (by cwd) | 动态技能发现、插件变更 |
| **SkillToolCommands** | memoize (by cwd) | 同上 |
| **SystemPrompt 动态段** | Map 缓存 | 仅 DANGEROUS_uncached 类型每轮重算 |
| **Git Status** | memoize | 整个会话期间缓存 |

### 8.2 三类缓存失效的对比

```
● 启动时加载一次，会话期间缓存（memoize），/clear 或 /compact 时清除
  → Rules / Skills / Commands / UserContext / SystemContext
  → 影响：清缓存后下一轮重新走组装流程

■ 首次计算后缓存（systemPromptSectionCache），/clear 或 /compact 时清除
  → System Prompt 动态段
  → 影响：cache 命中时只走静态段，cache 失效时全部重算

◆ 每轮都重新计算（会 break prompt cache）
  → MCP instructions（故意的）
  → 各种 attachment（per-turn dynamic）
  → 影响：每次都不走 cache，但只影响"应该每次变"的部分
```

### 8.3 prompt cache 命中策略表

| 数据 | 缓存策略 | 失效时机 |
|------|---------|---------|
| System prompt 静态段 | `cacheScope='global'` 跨 session | DCE/growthbook flip |
| System prompt 动态段 | `cacheScope=null` 不缓存 | 每轮 |
| User context (Rules) | `cacheScope=null`（per-call）| `/clear`、`/compact` |
| Tools schema base | `toolSchemaCache` per session | per turn 重新组装 |
| Tool result 替换 | `replacements.get(id)` byte-identical | 永不 |
| Compact boundary 后 messages | 由 API 缓存自动管理 | 每次微调 |
| File state (Read 缓存) | `fileStateCache` LRU，per session | 100 entry / 25MB cap |

### 8.4 关键认识

> **prompt cache 是"前后一致"的奖励——你的代码里所有"按 string identity 保留不变"的设计，最后都会转化成 cache 命中率的提升。**

特别值得注意的细节：
- **Tool result 替换是 byte-identical**（绝不重写 preview）—— 破坏这个会浪费 cache
- **Tools schema 是 session-stable base + per-request overlay**——避免 mid-session GrowthBook flip 把整个 tools 数组重写
- **归因头永远不缓存**（每次唯一避免重放）

---

# Part 2: 用户规则与 Skills 体系

---

## 9. 核心心法：规则体系的"在场但不污染"

Claude Code 在规则体系上的根本认识是：

> **规则必须在多轮中持续被模型看到（在"场"），但又不能塞爆 context、不能写回历史、不能打扰用户阅读（不"污染"）。** 这是规则体系设计的根本张力。

由此推导出三个基本动作：

1. **"在场"靠"每轮重新注入"**：规则不进 system prompt 的静态段（会破坏缓存），而是作为每轮 API 调用的第一条 user 消息（isMeta=true）prepend 进去。
2. **"不污染"靠"isMeta + 不写回历史"**：标记 isMeta 的 user 消息不进 REPL UI，不被写回 mutableMessages，所以不污染用户看到的历史。
3. **"按需激活"靠"路径条件 + 子目录嵌套"**：不要一次性把所有规则都注入，按"本轮实际涉及什么"动态激活。

### 9.1 一个关键比喻

> **规则是"贴在每轮对话的便签纸"**——每轮开始时贴在 messages 头部，模型看到了，但用户看不到，便签本身也不进历史。下轮开始时再贴一张新的。

### 9.2 设计原则总结

| 原则 | 含义 |
|------|------|
| **In-Context** | 规则必须在模型能看到的地方 |
| **Not In-History** | 规则不能写回 messages 历史 |
| **Not In-UI** | 规则不能在用户看到的对话流里出现 |
| **Per-Turn Re-injection** | 每轮都重新注入（不依赖"残留"）|
| **On-Demand Activation** | 条件规则按需激活，不浪费 context |
| **Layered Priority** | 多层规则有明确的优先级覆盖关系 |

---

## 10. 规则加载的三个维度

Claude Code 的规则体系从**三个维度**来组织：

### 10.1 三个维度

| 维度 | 含义 | 例子 |
|------|------|------|
| **空间维度** | 规则放在哪里 | Managed / User / Project / Local / AutoMem |
| **形式维度** | 规则怎么写 | 单文件 CLAUDE.md / 多文件 .claude/rules/*.md / 嵌套子目录 |
| **激活维度** | 规则什么时候生效 | 无条件 / 路径条件 / 子目录条件 / 动态发现 |

### 10.2 三个维度的协同

```
空间维度：Managed（系统级）→ User（用户级）→ Project（项目级）→ Local（私有级）→ AutoMem（自动记忆）
  决定：哪些规则对当前 session 可见，以及它们的覆盖顺序

形式维度：单文件 vs 多文件 vs 嵌套子目录
  决定：规则的物理组织和可维护性

激活维度：每轮 prepend（无条件）vs 路径匹配（conditional）vs 子目录触发（nested）
  决定：每轮实际有多少规则真正进入 context
```

### 10.3 关键认识

> **三个维度是"正交"的**——它们可以独立组合。例如：
> - "Project 层的 .claude/rules/typescript.md，无条件每轮注入"
> - "User 层的 .claude/rules/secure-coding.md，路径匹配 `src/**` 才注入"
> - "子目录 auth/ 的 CLAUDE.md，agent 通过 Read 进入时自动注入"

---

## 11. Rules 体系：5 层优先级 + 项目级规则分层

### 11.1 5 层加载顺序

按**优先级从低到高**依次加载（后续覆盖前序）：

| 优先级 | 层级 | 路径 | 说明 |
|--------|------|------|------|
| 1（最低）| **Managed** | `/etc/claude-code/CLAUDE.md` + `.claude/rules/*.md` | 管理员强制策略，用户不可覆盖 |
| 2 | **User** | `~/.claude/CLAUDE.md` + `.claude/rules/*.md` | 用户个人全局指令，对所有项目生效 |
| 3 | **Project** | `CLAUDE.md`、`.claude/CLAUDE.md`、`.claude/rules/*.md`（从 CWD 向上遍历到根目录）| 签入代码库的项目指令 |
| 4 | **Local** | `CLAUDE.local.md`（从 CWD 向上遍历到根目录）| 私有项目指令（应在 .gitignore 中）|
| 5（最高）| **AutoMem** | `~/.claude/...` 下的 memory.md | 自动记忆系统（可选功能）|

### 11.2 项目级规则的"目录遍历"机制

Project 层的规则是**从 CWD 向上遍历到根目录**：

```
/home/user/projects/
  my-project/             ← 根目录（git 根）
    CLAUDE.md
    .claude/
      rules/
        typescript.md
        testing.md
    src/
      auth/
        CLAUDE.md         ← 子目录规则
        .claude/
          rules/
            api.md
      api/
        CLAUDE.md         ← 子目录规则
```

**机制**：
- 启动时遍历整个目录树，把所有 CLAUDE.md 和 .claude/rules/*.md 都收集
- 形成一个"项目级规则列表"
- 子目录的规则不立即激活，而是通过 nested memory 在 agent 进入时自动注入

### 11.3 @include 指令

Memory 文件支持通过 `@path` 语法引用其他文件：

```markdown
@path
@./relative/path
@~/home/path
@/absolute/path
```

**机制**：
- 仅 leaf text node 中生效（code block / code string 内部不解析）
- 被引用的文件会作为独立条目插入到引用文件之前
- 支持循环引用防护（processedPaths Set）
- 不存在的文件静默忽略
- 仅允许白名单中的扩展名（md/txt/json/yaml/py/js/ts/go/rs 等 60+ 种）

**关键设计价值**：
- 让大规则体系可以**模块化拆分**：把不同主题的规则放在不同文件，主文件用 `@include` 引用
- **避免单文件过大**：单文件最大 40000 字符的限制下，通过 include 可以构建任意大小的规则体系

### 11.4 Token 限制

- 单个 memory 文件最大字符数：`MAX_MEMORY_CHARACTER_COUNT = 40000`
- 超大文件会被标记为 "large" 并截断处理

### 11.5 方法论价值

> **5 层优先级 + 项目级目录遍历 = 一个完整的"组织级 → 用户级 → 项目级 → 私有级 → 自动级"规则分层体系**。这种分层让不同的人在不同的场景下贡献规则，且互不冲突。

**关键启示**：
- 管理员的"硬性规定"（Managed）用户在本地不可改
- 用户的"个人偏好"（User）所有项目都生效
- 项目的"团队约定"（Project）通过 git 共享给所有成员
- 私有指令（Local）只对当前开发者生效
- 自动记忆（AutoMem）从历史中自动学习

---

## 12. Rules 注入：每轮 prepend 的"隐身"机制

### 12.1 核心不变量

> **Rules 不进 system prompt**（dynamic 段也只放元数据），而是作为**每轮 API 调用的第一条 user 消息（isMeta=true）**注入。

### 12.2 每轮 messages 的结构

```
每轮 query() iteration 的 messages 结构：

[0] {isMeta: true,  type:'user', content: <system-reminder>...Rules...</system-reminder>}
[1] {isMeta: false, type:'user', content: [本轮真实用户输入 / slash command 展开]}
[2..N] assistant / tool_result 历史
```

### 12.3 为什么这样设计而非放进 system prompt？

| 放进 system prompt 的问题 | 放进 isMeta user 消息的好处 |
|--------------------------|---------------------------|
| Rules 内容可能很长（最大 40000 字符/文件）| 不受 system prompt 大小限制影响 |
| 塞进 system prompt 的"静态段"会破坏 byte-stable 缓存 | 完全不影响 system prompt 的缓存策略 |
| Rules 进 REPL UI 会干扰用户阅读 | isMeta 让 Rules 不进 UI |
| Rules 写回历史会污染 messages 长度 | 不被写回 mutableMessages |

**关键认识**：**"每轮重新注入 + 不进历史"的设计 = 规则在多轮中"永久在场"的机制**。

### 12.4 关键设计

```text
Rules 内容 = memoize 缓存（启动时 + 显式失效）
Rules 注入 = 每轮重新走 prependUserContext（per-call）
```

**何时失效**：

| 触发点 | 行为 |
|--------|------|
| `/clear` | 整体清空，Rules 缓存重置 |
| `/compact` | 压缩后重置 Rules 缓存 + 触发 `InstructionsLoaded` hook |
| 工作树切换 | 重置缓存 |
| 设置同步 | 清缓存 |
| **每轮 query() 入口** | 不重置，但**重新走 prependUserContext** 把 Rules 拼到 messages 头部 |

### 12.5 方法论价值

> **Rules 的设计是"在场但不污染"的典型例子**——它在每轮都被注入（保证在场），但又不写回历史（保证不污染），也不进 UI（保证不影响用户阅读）。这种"在场但隐身"的设计是规则系统的高级形态。

**关键启示**：
- 在场：每轮 prepend → 模型每轮都看到
- 不污染历史：isMeta → 不写回 mutableMessages
- 不污染 UI：isMeta → 不在用户对话流里显示
- 不破坏 cache：独立于 system prompt → cache 策略不受影响

---

## 13. Conditional Rules：按需激活的路径条件规则

### 13.1 核心设计

`.claude/rules/*.md` 的 frontmatter 可声明 `paths: "src/**/*.ts"`：

```markdown
---
paths: "src/**/*.ts"
---

# TypeScript 编码规范
- 严格类型
- 不使用 any
- ...
```

### 13.2 激活机制

这类规则：

- **不直接注入** system prompt
- 通过 `getAttachmentMessages()` 在每轮根据"本轮 Read/Write/Edit 涉及的路径"匹配激活
- 匹配失败 → 不消耗 context
- 匹配成功 → 作为附件注入到本轮

### 13.3 一个完整的例子

```markdown
.claude/rules/
  typescript.md          # paths: "**/*.ts" - TypeScript 规则
  python.md              # paths: "**/*.py" - Python 规则
  api-routes.md          # paths: "src/api/**/*.ts" - API 路由规则
  database.md            # paths: "**/migrations/**" - 数据库迁移规则
  security.md            # 无 paths - 全局安全规则
```

**执行流程**：
- 用户问"修一下 src/auth/login.ts 的 bug"
- agent Read/Edit 涉及 `src/auth/login.ts`
- 本轮 attachment 阶段匹配：
  - typescript.md 匹配 ✅
  - api-routes.md 不匹配（不是 src/api/）
  - security.md 无条件注入 ✅
  - python.md 不匹配
- 本轮注入：typescript.md + security.md
- 不注入：python.md、api-routes.md、database.md

### 13.4 关键设计价值

> **Conditional Rules 让"规则"在多轮中既"始终可用"（用户写一次就行）又"按需激活"（不污染全局 context）**。这是上下文工程的经典模式——不要把所有内容都"展开"给模型。

**关键启示**：
- 大型项目的规则体系（可能几十上百条）不需要全量注入
- 只需要把"本轮实际相关的"注入
- 极大降低 context 负担

---

## 14. Nested Memory：子目录规则的"自动浮现"机制

### 14.1 核心设计

在子目录里放 `CLAUDE.md` 或 `.claude/rules/*.md` → 当 agent 通过 Read/Edit 进入该子目录时自动注入。

### 14.2 触发机制

- **触发**：`toolUseContext.nestedMemoryAttachmentTriggers` 在 Read/Edit 工具里被 push
- **注入**：`getNestedMemoryAttachments()` 在每轮 attachment 阶段 yield

### 14.3 一个完整的例子

```
my-project/
  CLAUDE.md                       # 项目级规则
  src/
    auth/
      CLAUDE.md                   # auth 子目录规则
      .claude/
        rules/
          jwt.md                  # auth 子目录更细的规则
    api/
      CLAUDE.md                   # api 子目录规则
```

**执行流程**：
- agent 在 turn 1 处理 `src/auth/login.ts`
- Read `src/auth/login.ts` → 触发 `src/auth/` 子目录规则注入
- 本轮 attachment 阶段匹配：
  - 项目级 CLAUDE.md 注入（无条件）
  - `src/auth/CLAUDE.md` 注入（路径匹配）
  - `src/auth/.claude/rules/jwt.md` 注入（路径匹配）
- 不注入：`src/api/CLAUDE.md`（未涉及）

- agent 在 turn 2 处理 `src/api/users.ts`
- Edit `src/api/users.ts` → 触发 `src/api/` 子目录规则注入
- 本轮 attachment 阶段匹配：
  - 项目级 CLAUDE.md 注入（无条件）
  - `src/api/CLAUDE.md` 注入（路径匹配）
  - `src/auth/CLAUDE.md` 不再注入（不再涉及）

### 14.4 关键设计价值

> **这让"项目级规则"和"子目录级规则"形成分层体系**，跨轮次跨层级都保持可用。

**关键启示**：
- 大型 monorepo 里的不同子系统可以有各自的规则
- 模型在"进入"某个子系统时自动获得相关上下文
- 不需要在 prompt 里手动 include，避免规则混乱

---

## 15. Skills 体系：发现 + 执行 + 条件激活

### 15.1 Skills 的完整生命周期

```
┌─────────────────────────────────────────────────────────────────┐
│  阶段一：加载（应用启动时，memoize 缓存）                          │
│                                                                 │
│  getSkillDirCommands(cwd)                                       │
│   └─ loadSkillsFromSkillsDir(cwd)                               │
│        └─ loadMarkdownFilesForSubdir('skills', cwd)            │
│             ├─ 扫描目录: /etc/.claude/skills/, ~/.claude/skills/,│
│             │            .claude/skills/ (CWD→根遍历)             │
│             ├─ 读取 SKILL.md → parseFrontmatter()                │
│             └─ createSkillCommand() → loadedFrom='skills'        │
│                  │  包含：name, description, whenToUse（元数据）  │
│                  │         markdownContent（正文，暂存）          │
│                  └─ 返回 Command 对象 → 存入缓存的 Command[] 列表  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  阶段二：元数据注入（每轮 system prompt 组装，缓存复用）          │
│                                                                 │
│  getSystemPrompt()                                              │
│   ├─ getSkillToolCommands(cwd) → 从缓存获取 Command[] 列表       │
│   │   过滤出可被模型调用的                                       │
│   │                                                             │
│   └─ systemPromptSection('session_guidance')                     │
│        └─ getSessionSpecificGuidanceSection(enabledTools, ...)  │
│             │  注入 SkillTool 使用说明:                          │
│             │  "/<skill-name> is shorthand for users to          │
│             │   invoke a user-invocable skill. Use SkillTool    │
│             │   to execute them."                                │
│             │                                                   │
│             │  ⚠ 此时模型知道有 "deploy" 这个 skill、它的描述、  │
│             │    whenToUse 指导，但看不到 deploy.md 的正文！    │
│             │    正文只在模型实际调用 SkillTool 时才会展开！     │
│             └────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│  阶段三：正文展开（模型调用 SkillTool 时，每轮可能发生 0 或 1 次）│
│                                                                 │
│  模型输出: <skill_tool>{"skill": "deploy", "args": "staging"}  │
│   │                                                             │
│   └─ SkillTool 执行                                             │
│        │                                                         │
│        ├─ 根据 skill name 查找 Command 对象                      │
│        ├─ 调用 command.getPromptForCommand(args, context)       │
│        │   │  来自 createSkillCommand 中的闭包                   │
│        │   │                                                     │
│        │   ├─ 注入 baseDir 前缀                                  │
│        │   ├─ 替换 ${ARG_NAME} 占位符                            │
│        │   ├─ 替换 ${CLAUDE_SKILL_DIR} 为 skill 目录路径         │
│        │   ├─ 替换 ${CLAUDE_SESSION_ID} 为当前会话 ID            │
│        │   ├─ 执行 frontmatter shell 命令                        │
│        │   └─ 返回 [{ type: 'text', text: SKILL.md 完整正文 }]   │
│        │                                                         │
│        ├─ 将展开后的文本作为工具结果返回给模型                   │
│        └─ 模型将 SKILL.md 的内容作为新的上下文继续处理           │
└─────────────────────────────────────────────────────────────────┘
```

### 15.2 四种 Skill 来源

| 来源 | 实现 | 加载时机 |
|------|------|----------|
| **Bundled** | 代码编译进二进制 | 启动时 `initBundledSkills()` |
| **目录 Skills** | `~/.claude/skills/`、`.claude/skills/`、`/etc/...` | 启动时 + 动态发现 |
| **Plugin** | `loadPluginCommands` | 启动时 |
| **MCP** | MCP 服务器推送 | MCP 连接时实时推送 |

### 15.3 关键设计点

#### 元数据 vs 正文分离

- **元数据**（name、description、whenToUse）每轮注入到 system prompt 的 session_guidance 段
- **正文**（markdownContent）只在模型调用 SkillTool 时才展开

**关键认识**：
- 模型知道有"deploy"这个 skill、知道何时使用，但看不到 deploy.md 的完整正文
- 这种"按需展开"避免了"所有 skill 正文都进 context 爆炸"
- 同样适用于规则系统——不要把所有规则一次性塞给模型

#### Frontmatter 配置

`SKILL.md` 的 frontmatter 支持：
- `description` / `name` - 自动从 markdown 第一行提取
- `allowed-tools` - 允许使用的工具列表
- `argument-hint` - 参数提示
- `when-to-use` - 给模型的使用指导
- `version`、`model`、`disable-model-invocation`、`user-invocable`
- `hooks` - HooksSettings 配置
- `context: fork` - 在 fork sub-agent 中执行
- `paths` - 路径条件激活
- `effort` - 努力程度
- `shell` - 在展开 prompt 前执行 shell 命令

#### Prompt 展开机制

`createSkillCommand().getPromptForCommand`：
1. 如果有 `baseDir` → 前缀 `Base directory for this skill: <dir>`
2. 执行参数替换 `${ARG_NAME}`
3. 替换 `${CLAUDE_SKILL_DIR}` 变量
4. 替换 `${CLAUDE_SESSION_ID}` 变量
5. 执行 frontmatter `shell` 命令
6. 返回 `[{ type: 'text', text: finalContent }]`

### 15.4 关键设计价值

> **Skills 的"元数据 + 正文"分离是上下文工程的经典模式**。不要把所有内容都"展开"给模型——把"可被找到的"和"实际需要的"分开，是降低 context 负担的关键。

**核心启示**：
- 元数据：每轮在 system prompt 里告诉模型"有什么可用"
- 正文：模型调用时再展开
- 状态：知道"有"和"用了"是两步操作

---

## 16. Skills 的"元数据 + 正文"分离原则

### 16.1 为什么要分离？

如果不做分离，模型会看到"所有 skill 的所有正文"：

```text
# 假设项目有 50 个 skills，每个 SKILL.md 平均 200 行
全部展开 = 50 × 200 = 10000 行 ≈ 30000 tokens
每轮都把这些塞进 system prompt = 灾难
```

分离后：

```text
元数据 = 50 × (name + description + whenToUse) ≈ 50 × 50 = 2500 tokens
  → 每轮在 system prompt 里告诉模型有这 50 个 skill
  
正文 = 仅在调用某个 skill 时展开该 skill 的 200 行 ≈ 600 tokens
  → 按需注入
```

### 16.2 分离的两层含义

#### 第一层：元数据 vs 正文

- 元数据：每轮在 system prompt 注入（轻量）
- 正文：模型调用时展开（按需）

#### 第二层：缓存 vs 实际使用

- 元数据**缓存复用**（同一组 skills 会话期间不变）
- 正文**每次新生成**（调用时动态展开 + 参数替换 + shell 命令）

### 16.3 关键认识

> **"可被找到"和"实际需要"是两件事**。一个 skill 的存在性是"上下文相关"的（元数据帮助决策），但它的"详细内容"是"任务相关"的（只在需要时展开）。

---

## 17. 动态 Skill 发现：从"用户写好"到"系统找出来"

### 17.1 核心机制

在文件操作（Read/Write/Edit）后触发，发现嵌套的技能目录：

```
文件操作 (read/write/edit)
    │
    ▼
discoverSkillDirsForPaths(filePaths, cwd)
    │ 遍历文件路径的父目录，找 .claude/skills/
    │ 排除 gitignored 目录
    ▼
addSkillDirectories(dirs)
    │ 加载每个目录的技能
    │ 存入 dynamicSkills Map
    ▼
skillsLoaded.emit()
    │ 触发监听器清除命令缓存
    ▼
onDynamicSkillsLoaded → clearCommandsCache()
```

### 17.2 关键认识

> **Skill 发现不靠"用户提前告诉"，而是"系统根据行为推断"**——用户做了某事（比如 Read 一个新文件），系统就去看这个新文件所在目录有没有 skill，自动加载。

**关键启示**：
- 用户不需要手动注册 skill
- 项目可以"懒加载"skill 体系
- 适合"用户在工作中逐渐发现新工具"的场景

### 17.3 Conditional Skills（基于 paths 的条件激活）

类似 conditional rules，skill 的 frontmatter 可以声明 `paths` 字段。当文件操作涉及的路径匹配时激活：

```typescript
activateConditionalSkillsForPaths(filePaths, cwd): string[]
```

---

## 18. Custom Commands：和 Skills 本质相同的遗留体系

### 18.1 三层分类

```
所有命令
   │
   ├─ type: 'prompt' ──────────── 提示词展开型命令
   │   │
   │   ├─ source !== 'builtin' ─── 【Skills】✅ 模型可通过 SkillTool 调用
   │   │   ├─ .claude/skills/        → loadedFrom: 'skills'
   │   │   ├─ .claude/commands/      → loadedFrom: 'commands_DEPRECATED'
   │   │   ├─ bundled                → loadedFrom: 'bundled'
   │   │   ├─ plugin                 → loadedFrom: 'plugin'
   │   │   └─ MCP                    → loadedFrom: 'mcp'
   │   │
   │   └─ source === 'builtin' ──── 【Builtin Prompt】
   │       ├─ /init, /compact, /review, /pr_comments ...
   │       └─ ❌ 模型 SkillTool 不可调用
   │
   ├─ type: 'local' ───────────── 本地命令（直接操作 TUI 状态）
   │   ├─ /clear, /help, /doctor, /config, /cost, /usage ...
   │   └─ ❌ 模型完全不可调用
   │
   └─ type: 'local-jsx' ───────── 本地 JSX 命令（渲染 Ink UI 组件）
       ├─ /doctor（诊断界面）、/ide ...
       └─ ❌ 模型完全不可调用
```

### 18.2 各类命令的触发机制

| 命令类型 | `/xxx` 用户触发? | 模型 SkillTool 调用? | 作用机理 |
|----------|-----------------|---------------------|----------|
| **Skills** | ✅ | ✅ | 展开 `getPromptForCommand()` → prompt 正文注入 |
| **Builtin Prompt** | ✅ | ❌ | 同样是提示词展开，但模型不能自主调用 |
| **Local** | ✅ | ❌ | 直接修改 TUI 状态，不发 API 请求 |
| **Local-JSX** | ✅ | ❌ | 渲染 Ink UI 组件 |

### 18.3 关键认识

> **`.claude/commands/` 本质上就是 skills**——与 `.claude/skills/` 在代码层面完全等价，只是目录名和 `loadedFrom` 标记不同。

`.claude/commands/` 是个**遗留但完全可用**的目录。它与 `.claude/skills/` 一起在加载时合并，**`commands_DEPRECATED` 标记的优先级最高**（同名时 commands 目录的版本胜出）。

### 18.4 SKILL.md 特殊命名规则

`.claude/commands/` 目录中的一个特殊情况：

```text
如果某个目录下存在 SKILL.md 文件:
  → 该目录下的其他 .md 文件被忽略
  → 只有 SKILL.md 被加载，命令名 = 父目录名

例:
.claude/commands/
  my-feature/
    SKILL.md        ← 加载，命令名 = "my-feature"
    helper.md       ← 被忽略（因为 SKILL.md 存在）
  deploy.md         ← 正常加载，命令名 = "deploy"
```

### 18.5 方法论价值

> **不要被"命令名"和"目录名"迷惑——本质上看，所有"用户可调用 + 模型可调用"的命令都属于同一类**。把 Skills 和 Commands 视为两个不同的东西会过度复杂化设计。

**关键启示**：
- 一个项目里 "Skills" 和 "Commands" 实际上是同一类东西
- `userInvocable` 默认 `true`——所有 prompt 类命令都"用户可调用"
- 模型可调用的条件 = `type === 'prompt' && !disableModelInvocation && source !== 'builtin' && (...)`

---

## 19. 三条路径的对比与协同

### 19.1 Rules vs Skills vs Commands 对比

| 维度 | Rules | Skills | Commands |
|------|-------|--------|----------|
| **目的** | 告诉模型"应该怎么做" | 告诉模型"有这些工具可用" | 同 Skills（遗留）|
| **形式** | 自然语言 + frontmatter | 自然语言 + frontmatter | 同 Skills |
| **位置** | CLAUDE.md / .claude/rules/ | .claude/skills/ | .claude/commands/ |
| **注入方式** | 每轮 prepend messages[0] | 元数据进 system prompt，正文按需展开 | 同 Skills |
| **是否可被模型调用** | ❌（只是约束）| ✅（SkillTool）| ✅（同 Skills）|
| **是否可被用户调用** | ❌ | ✅（/skillname）| ✅（/commandname）|
| **是否消耗 context** | 每次都消耗（prepend）| 元数据消耗，正文按需 | 同 Skills |
| **优先级** | 5 层覆盖 | 后加载覆盖前加载 | 同 Skills |

### 19.2 三者的协同

```
Rules（行为约束）          Skills（动作能力）         Commands（用户快捷）
    │                         │                          │
    │  "不要删库"            │  "deploy 到生产"          │  /deploy staging
    │  "先写测试再重构"      │  "跑测试并报告"          │  /test
    │  "编码风格指南"        │  "review PR"              │  /review
    │                         │                          │
    └─────────────────────────┴──────────────────────────┘
                                  │
                                  ▼
                          共同组成 agent 的"行为空间"
```

### 19.3 设计原则

> **Rules 是"约束"，Skills 是"能力"，Commands 是"快捷方式"**。三者正交：
> - Rules 告诉模型什么能做、什么不能做
> - Skills 告诉模型能做什么（按需展开）
> - Commands 让用户能快速触发（和 Skills 共享底层）

---

## 20. 规则体系的缓存与失效策略

### 20.1 缓存策略总览

| 内容 | 缓存方式 | 刷新触发条件 |
|------|----------|-------------|
| **Rules (getMemoryFiles)** | memoize | `/clear`、`/compact`、工作树切换、设置同步 |
| **Rules → UserContext** | memoize (getUserContext) | 同 Rules 缓存清除时 |
| **Skills (getSkillDirCommands)** | memoize (by cwd) | `/clear`、`/compact`、动态发现、插件重载 |
| **Commands (loadAllCommands)** | memoize (by cwd) | 动态技能发现、插件变更 |
| **SkillToolCommands** | memoize (by cwd) | 同上 |

### 20.2 三类缓存失效的对比

```
● 启动时加载一次，会话期间缓存（memoize），/clear 或 /compact 时清除
  → Rules / Skills / Commands / UserContext / SystemContext
  → 影响：清缓存后下一轮重新走组装流程

■ 首次计算后缓存（systemPromptSectionCache），/clear 或 /compact 时清除
  → System Prompt 动态段
  → 影响：cache 命中时只走静态段，cache 失效时全部重算

◆ 每轮都重新计算（会 break prompt cache）
  → MCP instructions（故意的）
  → 各种 attachment（per-turn dynamic）
  → 影响：每次都不走 cache，但只影响"应该每次变"的部分
```

### 20.3 缓存失效的触发点

| 触发点 | 影响 | 原因 |
|--------|------|------|
| `/clear` | Rules / Skills / Commands 全部重新加载 | 整体清空 |
| `/compact` | Rules 重新加载 + 触发 `InstructionsLoaded` hook | 压缩是结构变更 |
| 工作树切换 | Rules 缓存重置 | 路径变了 |
| 设置同步 | 全部 cache 清 | 配置变了 |
| 动态 Skill 发现 | Commands 缓存清 | 新 skill 出现 |
| 插件重载 | Commands / Skills 缓存清 | 插件内容变了 |

### 20.4 关键认识

> **"什么该缓存、什么不该缓存"是规则体系的关键设计**。缓存让"规则在场但不浪费计算"，不缓存让"动态变化能及时反映"。

**核心设计原则**：
- **静态规则**（Managed、User、Project）→ 启动时加载一次，缓存
- **动态内容**（AutoMem、动态发现）→ 按需加载，不缓存
- **缓存失效要明确**：不要让 stale 规则影响 agent 行为

---

# Part 3: 综合

---

## 21. 可借鉴的工程原则（24 条）

把上下文工程和用户规则体系的所有内容提炼为 24 条工程原则：

### 21.1 上下文工程核心（12 条）

#### 原则 1：把"组装"显式化为多步管线
API 看到的 messages 不是"历史累积"，而是每轮重新"组装"出来的视图。把每步都做成显式函数：
- 过滤 isVirtual
- 合并相邻 user 消息
- 补 orphan tool_result
- 规范化 tool_use input
- prepend user context

**好处**：每步可测、可观测、可调优。

#### 原则 2：REPL 状态 ≠ API 状态
UI 上看到的是完整的，但 API 上看到的是收缩后的。**这是上下文工程的根本张力**。理解这一点，才能理解"为什么有这个函数而不是那个函数"。

#### 原则 3：静态/动态分离，是 cache 友好的前提
把 system prompt 切成"byte-stable 静态段"和"per-turn 动态段"。**这是"低成本地每轮重申规则"的前提**。

#### 原则 4：每条规则用合适的"表达方式"
同一规则可以用 prompt、permission、hook、tool、state 等多种方式表达。表达方式的选择决定了规则的"强度"和"可执行性"。

#### 原则 5：每轮重新注入 Rules
Rules 内容可能很长（最大 40000 字符/文件），不能塞进 system prompt。**每轮 prepend 一个 isMeta 的 user 消息**来"在场但隐身"。

#### 原则 6：Skills 的"元数据 vs 正文"分离
- **元数据**（name、description、whenToUse）每轮注入到 system prompt
- **正文**（markdownContent）只在模型调用 SkillTool 时才展开

**核心启示**：不要把所有内容都"展开"给模型——把"可被找到的"和"实际需要的"分开。

#### 原则 7：cache 友好性的极致追求
prompt cache 是"前后一致"的奖励。所有"按 string identity 保留不变"的设计，最后都会转化成 cache 命中率的提升：
- Tool result 替换 byte-identical
- Tools schema session-stable base
- 归因头每次唯一（避免重放）

#### 原则 8：6 层压缩栈按"粒度"分层
越细粒度的层越先执行，越暴力的层越靠后：
1. toolResultBudget（单 message 50K）
2. snip compact（长程历史投影）
3. microcompact（旧 tool_result 清空）
4. context collapse（单 tool 折叠）
5. auto-compact（fork agent 总结）

#### 原则 9：替换是不可逆的，投影是可逆的
理解"投影 vs 替换 vs 压缩"的根本区别：
- 投影：REPL 还在，发不发给 API
- 替换：REPL 已改为 preview，完整在磁盘
- 压缩：REPL splice 删除，换成 summary

**这个区别决定了"模型下次还能不能看到旧内容"**。

#### 原则 10：每层都有"豁免"和"短路"
不是所有内容都应该被压缩/替换/投影：
- **Read 工具豁免**（maxResultSizeChars = Infinity）—— 防止"压缩→读→再压缩"死循环
- **fileStateCache 短路**（LRU 100/25MB）—— 防止"重复读同一文件"
- **MCP 强制 uncached**（每次唯一）—— 防止 MCP 改变行为契约

#### 原则 11：每轮 iteration 都是"shrink to fit → send → grow back"
```
state.messages（原始 REPL 状态）
  ↓ ① applyToolResultBudget (替换)
  ↓ ② snip 投影（默认不启用）
  ↓ ③ microcompact（清空）
  ↓ ④ collapse 投影（ant-only）
  ↓ ⑤ autoCompact（不可逆）
  ↓ ⑥ normalizeMessagesForAPI（12 步规范化）
  ↓ ⑦ prependUserContext（Rules 注入）
  ↓ 发 API
```

#### 原则 12：turn vs iteration 是不同的"轮次"
一个用户消息可能产生 N 次 API 调用。理解这一点对上下文工程至关重要：
- 每次 API 调用都要重新"组装" messages
- 每次 API 调用都要重新做"压缩 / 预算"检查
- 任何一次失败（413、max_output_tokens）都需要保留恢复点
- 跨 turn 状态（turnCount、recovery、reactive 尝试）必须持久
- 单 turn 内的状态是临时的，结束后可以释放

### 21.2 用户规则体系核心（12 条）

#### 原则 13：在场但不污染
规则必须在场（模型能看到），但不污染（不写回历史、不进 UI、不破坏 cache）。**isMeta + per-turn prepend + 独立于 system prompt** 是经典实现。

#### 原则 14：分层优先级覆盖
规则体系从低到高有 5 层：Managed → User → Project → Local → AutoMem。**后续覆盖前序，且高级别不能绕过"用户可改"的限制**。

#### 原则 15：元数据 vs 正文分离
不要把"可被找到的"和"实际需要的"混为一谈。元数据每轮告诉模型有什么，正文按需展开。

#### 原则 16：条件激活优于全量注入
大型规则体系不要"全量每轮注入"——按路径、按子目录、按"刚刚发生了什么"动态激活。**Conditional Rules + Nested Memory** 是两种典型实现。

#### 原则 17：用户可调用 + 模型可调用
设计命令系统时，不要区分"用户命令"和"技能"——所有"prompt 类命令"既可被用户触发（`/xxx`），也可被模型调用（SkillTool）。**这是 Skills 和 Commands 本质相同的原因**。

#### 原则 18：动态发现优于静态注册
不要让用户手动注册 skill——根据"用户做了什么"（文件操作）自动发现新 skill。**discoverSkillDirsForPaths + clearCommandsCache** 是经典模式。

#### 原则 19：缓存与失效要明确
什么该缓存、什么不该缓存、什么时候失效，要**在代码里有显式的触发点**。不要让"stale 规则"影响 agent 行为。

#### 原则 20：@include 让规则可模块化
大规则体系不要"全放在一个文件"——用 `@include` 让主文件引用子文件，模块化拆分。**单文件 40000 字符限制下，可以构建任意大的规则体系**。

#### 原则 21：每轮重新注入是底线
不要依赖"规则已经在历史里"的假设——**每轮都重新走 prepend/refresh 流程**。这是"多轮遵循规则"的物理基础。

#### 原则 22：Rules 与规划同构
> 规则 = "你必须永远这样做"
> 规划 = "你这次必须这样做"
> 实现机制高度同构（都是 system prompt 注入 + tool gate + per-turn attachment）

设计规则系统时，可以借鉴规划系统的设计；反之亦然。

#### 原则 23：每条规则用合适的"强度"
- **软约束**（prompt）—— 模型"应该"
- **硬约束**（permission deny）—— 模型"必须"
- **强制流程**（per-turn prepend）—— 不可绕过

能用硬约束的，绝不留给软约束。

#### 原则 24：@include + 条件激活 = 大规则体系
```
@include
  ├── typescript.md         # 全局 TypeScript 规则
  ├── python.md             # 全局 Python 规则
  ├── api-routes.md         # paths: "src/api/**"
  ├── database.md           # paths: "**/migrations/**"
  └── security.md           # 无条件全局安全规则
```

- 用 @include 模块化
- 用 paths 条件激活
- 用 nested memory 处理子目录

**这是大型项目"规则可维护性"的关键**。

---

## 22. 总结：上下文工程与规则体系的统一认知

读完 Claude Code 的上下文管理与规则体系，可以把它的设计思路抽象为**两大原则**：

### 22.1 上下文工程的"五点核心"

**第一点：上下文是被"组装"的，不是"累积"的**
- 每轮 API 调用都是 6-10 步显式管线
- 每步解决一个具体问题
- REPL 状态 ≠ API 状态

**第二点：压缩是多层的，按"粒度"分层**
- 单 message 预算 → 单 tool 折叠 → 整体 fork 总结
- 越细粒度的层越先执行，越暴力的层越靠后
- 每层都尽可能保持 prompt cache 命中

**第三点：缓存友好性是"贯穿一切"的设计目标**
- 静态/动态分离
- 替换 byte-identical
- Tools schema session-stable base

**第四点：规则在场但不污染**
- Rules 注入：isMeta、每轮 prepend
- Skills 元数据：每轮注入 system prompt
- Skills 正文：按需展开

**第五点：每条规则、每个 tool、每种内容都有合适的"强度"**
- 软约束（prompt）—— 模型"应该"
- 硬约束（permission deny）—— 模型"必须"
- 强制流程（per-turn prepend）—— 不可绕过

### 22.2 用户规则体系的"五点核心"

**第一点：规则必须"在场但隐身"**
- 在场：每轮 prepend
- 隐身：isMeta、不写回历史、不进 UI
- 独立于 system prompt：不破坏 cache

**第二点：分层优先级是"多人协作规则"的基础**
- Managed（系统管理员）
- User（个人偏好）
- Project（团队约定）
- Local（私有指令）
- AutoMem（自动记忆）

**第三点：条件激活优于全量注入**
- Conditional Rules（路径匹配）
- Nested Memory（子目录触发）
- Dynamic Skill Discovery（行为推断）

**第四点：Skills 的"元数据 + 正文"分离**
- 元数据：每轮注入 system prompt（轻量）
- 正文：模型调用时展开（按需）
- 状态：知道"有"和"用了"是两步操作

**第五点：动态发现 + 命令统一 = 用户友好的规则系统**
- 用户不需要手动注册 skill
- Skills 和 Commands 本质相同
- 所有"用户可调用 + 模型可调用"的命令共享底层机制

### 22.3 统一的最高层认知

> **上下文工程的核心不是"如何塞更多内容给模型"，而是"如何让模型在每轮都看到'该看的内容'，且不破坏性能和成本"。** 它的难度不在"如何压缩"，而在"压缩多少、用哪种压缩、什么时候压缩、压缩后如何让模型继续工作"。

> **用户规则体系的设计核心是"平衡"**——既要让规则"始终在场"（用户写一次就生效），又要让规则"按需激活"（不污染 context）；既要让用户能"轻松调用"（`/xxx`），又要让模型能"智能选用"（SkillTool）；既要让规则"可缓存"（性能），又要让规则"可失效"（正确性）。

### 22.4 一句话总结两个体系的关系

> **上下文工程是"舞台"，规则体系是"演员"**——舞台负责把灯光、布局、幕布（管线、压缩、缓存）布置好，让演员（Rules、Skills、Commands）能在合适的时候、合适的位置、对合适的人（模型）说话。
