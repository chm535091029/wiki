---
aliases: [Claude Code Harness, Harness 工程, 挽具工程, Harness Engineering, Agent 多层约束]
tags: [Harness, Agent, Claude-Code, Hooks, Permission, TodoWrite, Plan-Mode, Subagent, Defense-in-Depth]
related:
  - "../context-engineering/claude-code-context-and-rules.md"
  - "./hook.md"
  - "./harness-engineering.md"
---

# Claude Code 的 Harness 设计方法论

> 调研对象：Claude Code 的"harness（挽具）"工程。聚焦"如何让 Agent 在多轮、长上下文、跨会话的项目中持续遵循规则、维持规划、做出符合预期行为"。
>
> 本文是方法论提炼，**不涉及具体实现细节**，重点在思路、原则和模式。

---

## 目录

1. [核心心法：不要寄希望于"模型记住规则"](#1-核心心法不要寄希望于模型记住规则)
2. [总体框架：8 层叠加的"约束 + 提醒"系统](#2-总体框架8-层叠加的约束--提醒系统)
3. [第 1 层：系统提示词静态段——"行为宪法"](#3-第-1-层系统提示词静态段行为宪法)
4. [第 2 层：Rules 注入——每轮可热加载的项目指令](#4-第-2-层rules-注入每轮可热加载的项目指令)
5. [第 3 层：Permission 模式——Tool 执行的"守门员"](#5-第-3-层permission-模式tool-执行的守门员)
6. [第 4 层：Hooks 拦截器——规则可编程的扩展点](#6-第-4-层hooks-拦截器规则可编程的扩展点)
7. [第 5 层：TodoWrite / Plan Mode——让规划变成状态机](#7-第-5-层todowrite--plan-mode让规划变成状态机)
8. [第 6 层：Per-Turn 动态附件——"实时提醒"系统](#8-第-6-层per-turn-动态附件实时提醒系统)
9. [第 7 层：压缩后规则再激活——让压缩不丢约束](#9-第-7-层压缩后规则再激活让压缩不丢约束)
10. [第 8 层：Subagent 隔离——以子代理为单位的规则分舱](#10-第-8-层subagent-隔离以子代理为单位的规则分舱)
11. [贯穿：每轮 iteration 的"全量再注入"管线](#11-贯穿每轮-iteration-的全量再注入管线)
12. [关键设计模式与不变量](#12-关键设计模式与不变量)
13. [可借鉴的工程原则](#13-可借鉴的工程原则)

---

## 1. 核心心法：不要寄希望于"模型记住规则"

Claude Code 在 harness 上的根本认识是：

> **不要把"agent 会不会遵守规则"押在模型的"记忆"上。** 模型的注意力、记忆都是不可靠的；规则必须在结构上就位、每轮都重新"推"到模型面前。

由此推导出三个基本动作：

1. **规则多处冗余表达**：同一约束在 system prompt、user message、attachment、tool 行为、permission 规则、hook 等多个地方独立表达——任何一处失效都有其他地方兜底。
2. **每轮重新注入**：所有"长期有效"的内容，每轮 iteration 都重新走一遍"组装"流程，而不是依赖上下文里的"残留"。
3. **硬约束与软约束分层**：模型"答应做"是软约束（不可靠），Tool 直接被拦截是硬约束（可靠）。能上硬约束的绝不留给软约束。

---

## 2. 总体框架：8 层叠加的"约束 + 提醒"系统

Claude Code 的 harness 由 8 层相互补偿的机制组成。每一层都有明确的"何时触发 / 作用于哪个环节 / 谁来维护"。

### 2.1 8 层一览

| 层 | 名称 | 作用 | 触发时机 |
|----|------|------|---------|
| L1 | 系统提示词静态段 | 不可变的行为宪法 | 每次调 API 前重新组装，但内容 byte-stable → 跨 session 缓存 |
| L2 | Rules 注入 | 每轮可热加载的项目指令 | 每轮 query 入口重新加载（`/clear`、`/compact` 时刷缓存）|
| L3 | Permission 模式 | Tool 执行的"守门员" | 每个 `tool_use` 块前必走 canUseTool 拦截 |
| L4 | Hooks 拦截器 | 27 个生命周期事件，规则可编程 | 每个生命周期事件都允许外部脚本介入 |
| L5 | TodoWrite / Plan Mode | 显式规划 + 进度追踪 | 模型自驱 + 系统引导（plan 模式守卫）|
| L6 | Per-Turn 动态附件 | 行为 nudge 系统 | 每轮 query 末尾拼到 messages 头部，token 级精度 |
| L7 | 压缩后规则再激活 | auto-compact 不丢失行为约束 | autoCompact 触发的 boundary 之后立刻重新注入 |
| L8 | Subagent 隔离 | 以子代理为单位的规则分舱 | subagent 拥有独立 message / system prompt / permission mode |

### 2.2 一个总图

```
                      Harness 多层架构（自上而下）

  ┌─────────────────────────────────────────────────────────────────┐
  │  Layer 8  Subagent 隔离                                          │
  │  AgentTool → runAgent() → 独立 system prompt / 独立 message stream│
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 7  压缩后规则再激活                                        │
  │  autoCompact → boundary + summary + 重新注入 hooks/attachments   │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 6  Per-Turn 动态附件（nudge 系统）                        │
  │  todo_reminder / plan_mode_reminder / verify_plan_reminder / etc. │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 5  显式规划 + 进度追踪                                     │
  │  TodoWriteTool / EnterPlanMode / ExitPlanMode                   │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 4  Hooks 拦截器（27 个生命周期事件）                       │
  │  PreToolUse / PostToolUse / Stop / SubagentStop / PreCompact ...  │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 3  Permission 模式（tool 执行的"守门员"）                  │
  │  default/plan/acceptEdits/bypassPermissions/dontAsk/auto         │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 2  Rules（CLAUDE.md）注入                                  │
  │  5 层加载：Managed → User → Project → Local → AutoMem            │
  ├─────────────────────────────────────────────────────────────────┤
  │  Layer 1  系统提示词静态段（不可变的行为宪法）                      │
  │  intro / system / doing tasks / actions / using your tools       │
  └─────────────────────────────────────────────────────────────────┘
```

### 2.3 关键认识

- **没有任何一层是"独立负责"的**——每一层都假设其他层会失效，并相互补偿。
  - Rules（L2）可能因压缩丢失 → L7 负责"压缩后立刻重新注入"
  - UserPromptSubmit hook（L4）可能被禁用 → L5 提供 TodoWrite 让模型自驱
  - plan mode 守卫（L5）可能不小心退出 → L6 的 plan_mode_reminder 每 5 轮提醒

- **规则"强度"在 harness 中是一组递进的概念**：
  - 软约束（system prompt、Rules）：模型"应该"遵守
  - 工具引导（TodoWrite/Plan 工具的 prompt）：模型"被建议"使用
  - 强制流程（每轮 prependUserContext、canUseTool）：不可绕过
  - 硬约束（Permission deny、Hook deny、preventContinuation）：模型绝对无法绕过

- **"规则"和"规划"是同一种东西的不同强度**：
  - 规则 = "你必须永远这样做"
  - 规划 = "你这次必须这样做"
  - 实现机制高度同构（system prompt 注入 + tool gate + per-turn attachment）

---

## 3. 第 1 层：系统提示词静态段（行为宪法）

### 3.1 作用

把"AI 的身份、行为规范、工具使用偏好、风险行动边界"用**字节稳定**的字符串写到 system prompt 中，跨 session 跨 turn 缓存，是 harness 体系的"宪法层"。

### 3.2 关键设计

- **静态段 vs 动态段分离**：通过一个 BOUNDARY 标记把 system prompt 切成两段。
  - 静态段 = byte-stable，可以跨 session 命中缓存
  - 动态段 = per-turn 重算（运行时的 env info、MCP 指令等）
- **缓存策略**：静态段打上"跨 session 缓存"标记；动态段打"每次唯一"标记。

### 3.3 静态段通常承载什么

| 段 | 内容 |
|----|------|
| intro | AI 身份、URL 生成禁令 |
| system | 工具执行权限模式说明、`<system-reminder>` 标签说明、prompt injection 防御、上下文压缩说明 |
| doing tasks | 编码风格（不过度抽象、不加不必要功能、不预测时间、报错诚实）|
| actions | 风险行动确认（删除、强制推送、CI/CD 修改、发消息、共享状态）|
| using tools | 优先专用工具而非 Bash、必须用 TodoWrite 拆解任务、并行调用原则 |
| agent tool | subagent 使用指引 |

### 3.4 这层的局限

- 只能承载"普适规则"，不能承载"本项目本任务的特殊规则" → 用 L2 Rules
- 不能拦截危险操作（"agent 答应不删库"是无约束的）→ 用 L3/L4
- 无法在 agent 走偏时实时提醒 → 用 L6 nudge
- 无法在 agent 退出规划时挡住 → 用 L5 plan 模式

### 3.5 方法论价值

> **把"行为宪法"做成 byte-stable 静态段**，是整个 harness 能"低成本地每轮强制重新声明规则"的物理基础——因为缓存命中，每轮 iteration 都不需要重新计算或重新传输这部分内容。


### 1. System Prompt 结构（按 `getSystemPrompt()` 拼接顺序）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  System Prompt = asSystemPrompt([staticSections..., boundary?, dynamicSections]) │
│  (由 prompts.ts:560-576 串行拼接，null 项 filter 掉)                       │
│                                                                              │
│  ┌───────────────────── 静态段（global cache，跨 session）────────────────┐  │
│  │ ① getSimpleIntroSection()                                              │  │
│  │    "You are an interactive agent that helps users with software        │  │
│  │     engineering tasks. Use the instructions below and the tools        │  │
│  │     available to you to assist the user."                              │  │
│  │    + CYBER_RISK_INSTRUCTION（cyber 风险声明）                          │  │
│  │    + 禁猜 URL 警告                                                       │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ② getSimpleSystemSection()  → "# System"                             │  │
│  │    • 工具外文本显示规则                                                 │  │
│  │    • 权限模式 + 用户批准/拒绝处理                                       │  │
│  │    • <system-reminder> 等标签说明                                       │  │
│  │    • 提示词注入检测指引                                                  │  │
│  │    • getHooksSection()（hooks 启用时）                                  │  │
│  │    • 自动压缩说明                                                       │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ③ getSimpleDoingTasksSection()  → "# Doing tasks"                    │  │
│  │    [conditional: outputStyleConfig === null || keepCodingInstructions] │  │
│  │    • 软件工程任务定义                                                   │  │
│  │    • 不假手于非授权修改                                                  │  │
│  │    • 不创建不必要文件                                                   │  │
│  │    • 不给时间估算                                                       │  │
│  │    • 失败先诊断再换策略                                                  │  │
│  │    • 安全编码原则（OWASP top 10）                                        │  │
│  │    • 代码风格子项（不加多余功能/注释/abstraction）                       │  │
│  │    • + ant-only: 默认不写注释等                                          │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ④ getActionsSection()  → "# Executing actions with care"              │  │
│  │    • 可逆 vs 不可逆操作的区分                                            │  │
│  │    • 高风险操作（删除/强推/外发消息）必须先确认                          │  │
│  │    • 用户单次授权不延伸至所有上下文                                      │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑤ getUsingYourToolsSection(enabledTools)  → "Using your tools"        │  │
│  │    • 优先用专用工具而非 Bash                                             │  │
│  │    • 并行调用独立工具                                                    │  │
│  │    • 用 Task/Todo 工具管理任务                                           │  │
│  │    • AskUserQuestion 工具指引                                            │  │
│  │    • Agent/Explore/Plan 工具指引                                        │  │
│  │    • [conditional] SkillTool 工具指引                                   │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑥ getSimpleToneAndStyleSection()  → "# Tone and style"               │  │
│  │    • 不用 emoji（除非用户要求）                                          │  │
│  │    • 引用代码用 file_path:line 格式                                     │  │
│  │    • 工具调用前不冒号                                                    │  │
│  │    • GitHub 引用格式                                                    │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑦ getOutputEfficiencySection()  → "Output efficiency" /              │  │
│  │    "Communicating with the user"                                       │  │
│  │    • 直奔主题，最简方案优先                                              │  │
│  │    • 倒金字塔结构                                                       │  │
│  │    [ant-only] 给出更详细的沟通指引                                        │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ★ SYSTEM_PROMPT_DYNAMIC_BOUNDARY  [conditional: shouldUseGlobalCache] │  │
│  │    （1P 切分 static/global 与 dynamic/null 的分界点）                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌────────────── 动态段（systemPromptSection 缓存，per-session）──────────┐  │
│  │ ① 'session_guidance'  [首调后缓存]                                    │  │
│  │    getSessionSpecificGuidanceSection(enabledTools, skillToolCommands) │  │
│  │    • AskUserQuestion 工具使用指引                                       │  │
│  │    • [非交互] ! cmd 提示                                                │  │
│  │    • [conditional] Agent/Explore/Plan 工具指引                          │  │
│  │    • [conditional] SkillTool 工具使用 + skill 元数据列表               │  │
│  │    • [conditional] DiscoverSkills 工具指引（EXPERIMENTAL_SKILL_SEARCH） │  │
│  │    • [ant-only] Verification Agent 契约                                 │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ② 'memory'  → loadMemoryPrompt()                                      │  │
│  │    [conditional: hasAutoMemPathOverride / MEMORY path 配置]            │  │
│  │    AutoMem 系统使用说明（写 MEMORY.md 等）                              │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ③ 'ant_model_override'  [ant-only]                                    │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ④ 'env_info_simple'  → computeSimpleEnvInfo()                        │  │
│  │    • CWD（当前工作目录）                                                │  │
│  │    • git status（branch / main / status / recent log）                  │  │
│  │    • Platform / OS / Shell                                              │  │
│  │    • Model name + knowledge cutoff                                     │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑤ 'language'  → getLanguageSection(settings.language)                 │  │
│  │    [conditional: 用户设了非空 language]                                 │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑥ 'output_style'  → getOutputStyleSection()                           │  │
│  │    [conditional: 启用了非默认 output style]                              │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑦ 'mcp_instructions'  → DANGEROUS_uncached                           │  │
│  │    [conditional: 非 DELTA 模式]                                        │  │
│  │    每轮重算：MCP 服务器 connect/disconnect 状态可能变 → 故意破坏 cache  │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑧ 'scratchpad'  → getScratchpadInstructions()                          │  │
│  │    [conditional: SCRATCHPAD feature 启用]                              │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑨ 'frc'  → getFunctionResultClearingSection(model)                    │  │
│  │    函数结果自动释放机制说明（按模型不同）                                │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑩ 'summarize_tool_results'                                            │  │
│  │    SUMMARIZE_TOOL_RESULTS_SECTION 静态常量                              │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑪ 'numeric_length_anchors'  [ant-only]                                │  │
│  │    "keep text between tool calls ≤25 words, final ≤100 words"         │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑫ 'token_budget'  [conditional: TOKEN_BUDGET feature]                 │  │
│  │    用户指定 token 目标时的连续执行规则                                    │  │
│  ├───────────────────────────────────────────────────────────────────────┤  │
│  │ ⑬ 'brief'  [conditional: KAIROS / KAIROS_BRIEF feature]               │  │
│  │    KAIROS 任务简报指引                                                   │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  拼接引擎：asSystemPrompt() 把数组转 SystemPrompt 类型；buildSystemPromptBlocks│
│  按 cacheScope 切分为 attribution + prefix + static(global) + dynamic(null) │ │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

### 2. User Message 最终结构（每轮 messages[1:]，按追加顺序）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  userContent: messages[1..N]  （messages[0] 是 prependUserContext 注入的） │
│  由 processUserInput + query.ts:1715-1727 (M 阶段) 拼回                       │
│                                                                              │
│  ┌─ A. 真实用户输入（turn 1 由 processUserInput 注入）────────────────────┐  │
│  │  • 真实文本 "请阅读 src/api.ts..."                                       │  │
│  │  • 用户拖入的 <image> base64                                            │  │
│  │  • <file_content path="...">  （用户在文本里 @file 引用）                  │  │
│  │  • hook 注入：<hook_context source="UserPromptSubmit">                   │  │
│  │  • <local_command_stderr> 标记（来自本地 bash 命令）                     │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌─ B. 上一轮 assistant 的 tool_result（每轮 M 阶段追加）─────────────────┐  │
│  │  • user(tool_result 块)  ← StreamingToolExecutor / runTools 产生的     │  │
│  │  • [conditional] 若超 50K 预算 → 已是 preview 形式：                       │  │
│  │    "<persisted-output> Output too large (X KB). Full output saved to:  │  │
│  │     /path/tool-results/tu_1.txt                                        │  │
│  │     Preview (first 2 KB):                                              │  │
│  │     ... </persisted-output>"                                           │  │
│  │  • [conditional] 若 60min 无活动 → 已被 Time-based MC 清成：            │  │
│  │    "[Old tool result content cleared]"                                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ┌─ C. 附件 messages（每轮末尾 getAttachmentMessages 注入）────────────────┐  │
│  │  • memory  / nested_memory              （AutoMem 路径、子目录 CLAUDE.md）│  │
│  │  • conditional_rules                   （本轮涉及新路径 → paths glob 匹配）│  │
│  │  • skill_discovery / skill_listing      （EXPERIMENTAL_SKILL_SEARCH）     │  │
│  │  • agent_listing_delta                  （AgentTool 变更时）              │  │
│  │  • mcp_instructions_delta                （MCP 客户端变化时）               │  │
│  │  • deferred_tools_delta                 （新工具加载时）                 │  │
│  │  • edited_text_file / edited_image_file （文件操作后变更摘要）            │  │
│  │  • todo_reminder / plan_mode_reminder   （状态提醒）                    │  │
│  │  • max_turns_reached / queued_command   （控制信号）                   │  │
│  │  • hook_additional_context               （hook 注入的附加上下文）        │  │
│  │  • brief                                （KAIROS 简报）                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  ──────────────────────────────────────────────────────────────────────────  │
│  拼接完毕 → normalizeMessagesForAPI：                                        │
│    1) 过滤掉 progress / 通用 system / synthetic api error / isVirtual         │
│    2) 合并相邻 user 消息（Bedrock 兼容）                                       │
│    3) 合并相邻同 id assistant 块（流式分片合并）                              │
│    4) 规范化 tool_use input（strip swarm fields、ExitPlanModeV2 fields）       │
│    5) 过滤 trailing thinking / whitespace-only / 孤立 thinking-only         │
│    6) [HISTORY_SNIP] 附加 [id:xxx] tag                                       │
│  → ensureToolResultPairing（补 orphan / 删 orphan）                            │
│  → stripAdvisorBlocks / stripExcessMediaItems                               │
│  → 交给 SDK                                                                  │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

### 3. messages[0]：prependUserContext 注入（每轮 API 调用前都执行）

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  messages[0] = createUserMessage({ isMeta: true, content: ... })  (api.ts:449)│
│                                                                              │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │ <system-reminder>                                                      │  │
│  │ As you answer the user's questions, you can use the following        │  │
│  │ context:                                                              │  │
│  │ # claudeMd                                                            │  │
│  │ <CLAUDE.md 内容：五层加载 Managed → User → Project → Local →         │  │
│  │   AutoMem 的合并结果>                                                  │  │
│  │ # currentDate                                                         │  │
│  │ Today's date is 2026-06-10.                                          │  │
│  │                                                                       │  │
│  │ IMPORTANT: this context may or may not be relevant to your tasks.   │  │
│  │ You should not respond to this context unless it is highly relevant   │  │
│  │ to your task.                                                        │  │
│  │ </system-reminder>                                                     │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  关键：isMeta: true → 不写回 state.messages → 不进 REPL UI 历史 →          │
│        只作为 API 调用参数，每轮重新 prepend                                   │
└──────────────────────────────────────────────────────────────────────────────┘
```
---

## 4. 第 2 层：Rules 注入（每轮可热加载的项目指令）

### 4.1 加载入口

- 通过 `getMemoryFiles()` 加载 `CLAUDE.md` 和 `.claude/rules/*.md` 文件
- 5 层优先级：Managed → User → Project → Local → AutoMem（后续覆盖前序）
- 通过 `prependUserContext()` → **每轮 API 调用的第一条 isMeta user message** 注入

### 4.2 Rules 的"持续起作用"机制

**核心不变量**：Rules 不进 system prompt（dynamic 段也只放元数据），而是作为**每轮 API 调用的第一条 user 消息（isMeta=true）**注入。

```text
每轮 query() iteration 的 messages 结构：

[0] {isMeta: true,  type:'user', content: <system-reminder>...Rules...</system-reminder>}
[1] {isMeta: false, type:'user', content: [本轮真实用户输入 / slash command 展开]}
[2..N] assistant / tool_result 历史
```

**为什么这样设计而非放进 system prompt？**：

1. Rules 内容可能很长（最大 40000 字符/文件），塞进 system prompt 的"静态段"会破坏 byte-stable 缓存
2. Rules 不进 REPL UI（isMeta），用户看到的对话里没有 Rules
3. Rules 不被写回 mutableMessages，所以不会污染历史——但下一轮 iteration 仍会被重新注入

> **这种"每轮重新注入 + 不进历史"的设计 = 规则在多轮中"永久在场"的机制。**

### 4.3 缓存失效与重载触发点

| 触发点 | 行为 |
|--------|------|
| `/clear` | 整体清空，Rules 缓存重置 |
| `/compact` | 压缩后重置 Rules 缓存 + 触发 `InstructionsLoaded` hook |
| 工作树切换 | 重置缓存 |
| 设置同步 | 清缓存 |
| **每轮 query() 入口** | 不重置，但**重新走 prependUserContext** 把 Rules 拼到 messages 头部 |

### 4.4 Conditional Rules（路径条件规则）

`.claude/rules/*.md` 的 frontmatter 可声明 `paths: "src/**/*.ts"`。这类规则：

- **不直接注入** system prompt
- 通过 `getAttachmentMessages()` 在每轮根据"本轮 Read/Write/Edit 涉及的路径"匹配激活
- 匹配失败 → 不消耗 context
- 匹配成功 → 作为附件注入到本轮

**关键设计价值**：让"规则"在多轮中既**始终可用**（用户写一次就行）又**按需激活**（不污染全局 context）。

### 4.5 Nested Memory（子目录规则）

- 在子目录里放 `CLAUDE.md` 或 `.claude/rules/*.md` → 当 agent 通过 Read/Edit 进入该子目录时自动注入
- **这让"项目级规则"和"子目录级规则"形成分层体系**，跨轮次跨层级都保持可用

---

## 5. 第 3 层：Permission 模式（Tool 执行的"守门员"）

### 5.1 作用

在每个 `tool_use` 块执行前，`canUseTool()` 必须返回 allow/deny/ask。这是**唯一硬性的运行时拦截**，对规则的执行强度从"软约束"提升到"硬约束"。

### 5.2 六种 Permission Mode

| Mode | 行为 | 适用场景 |
|------|------|---------|
| `default` | 每个非读工具都需要用户确认 | 通用 |
| `plan` | 禁止写操作，只能跑只读工具 | 规划阶段（EnterPlanMode 后）|
| `acceptEdits` | 自动批准 Edit/Write；其他需用户确认 | 高效编码 |
| `bypassPermissions` | 自动批准所有操作 | CI/脚本 |
| `dontAsk` | 拒绝非白名单操作 | 严格环境 |
| `auto` | 由 transcript classifier 决定 allow/ask/deny | 智能体自动模式 |

### 5.3 判定栈（每个 tool_use 必走）

```
每个 tool_use 进入执行前
    ↓
[1] Hook permission result （Layer 4）
    ├─ allow → 走 [3] 但跳过 user prompt
    ├─ deny  → 直接拒绝
    └─ ask   → 走 [2] 但带 hook 提供的 reason
    ↓
[2] Tool.requiresUserInteraction() ？
    └─ 是（plan mode、AskUserQuestion）→ 弹 dialog
    ↓
[3] settings.json 规则匹配
    ├─ 命中 allow 规则 → 跳过 user prompt
    ├─ 命中 deny 规则 → 拒绝
    ├─ 命中 ask 规则 → 弹 dialog
    └─ 都不命中 → 看当前 mode
    ↓
[4] Mode 默认行为
    ├─ default 模式 → 弹 dialog
    ├─ acceptEdits 模式 → Edit/Write 自动通过
    └─ bypassPermissions → 全自动通过
    ↓
[5] Classifier（auto mode 才走）
    └─ 调 transcript classifier → allow/ask/deny
```

### 5.4 关键设计

- **会话级持久**：mode 存 `appState.toolPermissionContext.mode`，每次 `query()` iteration 都会传给 `toolUseContext`
- **plan mode 守卫**：`isPlanModeRequired()` 在 AgentTool 里检查，"in plan mode but try to write" → throw
- **prePlanMode 状态机**：`toolPermissionContext.prePlanMode` 记录进入 plan 之前的 mode，ExitPlanMode 时恢复——**保证"进入 plan → 写 plan → 退出 plan"是一个封闭状态机**

### 5.5 方法论价值

> Layers 1/2 的"规则"在这一层被强制执行——用户在 CLAUDE.md 写"不要删库"，如果没有 deny 规则，模型还是能删；但只要 settings.json 加一条 `"deny": ["Bash(rm:*)"]`，就硬性阻止了。

**关键启示**：把"软约束"翻译为"硬约束"的能力，是 harness 真正能让规则"起作用"的关键。规则的可执行性不靠模型自觉，而靠 Tool 层的拦截。

---

## 6. 第 4 层：Hooks 拦截器（规则可编程的扩展点）

### 6.1 作用

把"用户/组织/插件的规则"以**外部脚本**的形式注入到 agent 生命周期的 27 个事件点上。这层把 harness 从"项目内置约束"扩展到"可由用户/插件自定义"。

### 6.2 27 个 hook 事件

按"何时触发"分类：

- **工具相关**：PreToolUse、PostToolUse、PostToolUseFailure
- **会话相关**：SessionStart、SessionEnd、Setup
- **用户输入**：UserPromptSubmit
- **停止/继续**：Stop、StopFailure、SubagentStart、SubagentStop
- **压缩相关**：PreCompact、PostCompact
- **权限相关**：PermissionRequest、PermissionDenied
- **任务相关**：TaskCreated、TaskCompleted、TeammateIdle
- **环境/配置**：CwdChanged、FileChanged、ConfigChange
- **MCP**：Elicitation、ElicitationResult
- **Git 工作树**：WorktreeCreate、WorktreeRemove
- **指令加载**：InstructionsLoaded

### 6.3 Hook 的三种实现方式

| 实现方式 | 适用场景 | 例子 |
|---------|---------|------|
| **command** | 任何可以用 shell 表达的逻辑 | `python3 lint_check.py` |
| **prompt** | 用 LLM 做分类决策 | PermissionRequest hook 用 prompt 决定 allow/deny |
| **http** | 调外部服务 | webhook 通知、远程审计 |
| **callback** | 进程内异步函数 | plugin 用 |

### 6.4 关键的 5 个事件

#### PreToolUse（工具执行前）

能做什么：
- 返回 `{permissionDecision: 'allow'|'deny'|'ask'}` → 覆盖 L3 的判定
- 返回 `{updatedInput: {...}}` → **改写工具参数**（如自动注入路径前缀）
- 返回 `{additionalContext: '...'}` → 作为 `hook_additional_context` 附件注入（**多轮中"动态增量注入规则"的标准通道**）
- 返回 `{continue: false}` → **阻止 agent 继续**

典型用例：
- 自动拒绝 `rm -rf` 之类的危险命令
- 自动给所有 Bash 命令注入 `--strict-mode`
- 在每次 Edit 之前自动跑 linter
- 自动重写 git commit message 格式

#### PostToolUse（工具执行后）

能做什么：
- `additionalContext` 注入到下一轮（"你刚才的 Edit 触发了 X 个 lint warning"）
- `updatedMCPToolOutput` 改写 MCP 工具的输出
- `preventContinuation` 阻止 agent 继续（"测试失败，回去改"）

#### UserPromptSubmit（用户消息提交）

能做什么：
- 注入 `additionalContext` → 作为该轮的第一条 user 消息

典型用例：自动给每条用户消息追加项目级 caveat

#### Stop（agent 想要停止）

能做什么：
- `continue: false` → 阻止 agent 停止（强制继续，比如"还有任务没完成"）
- `stopReason: '...'` → 注入阻断说明

**这是"规则持续遵循"的最后一关**：agent 走完一轮想停下时，hook 还能强制它继续。

#### PostCompact（压缩后）

能做什么：
- `additionalContext` 注入到新 context boundary 之后的第一轮

**这是 L7 "压缩后规则再激活"的标准机制**。

### 6.5 Hook 的信任模型

- **每轮 iteration 都重新跑**：hooks 在 Pre/Post ToolUse 中被调用，每个 tool_use 都跑一次
- **不依赖 prompt cache**：hooks 的输出以 `hook_additional_context` 附件形式注入到 messages，独立于 system prompt
- **trust 模型**：必须 workspace trust 才能跑 hook——不信任的工作区不跑 hooks（安全防御）
- **超时控制**：Tool hook 默认 10 分钟，Session end hook 默认 1.5 秒

### 6.6 Hook 与 Permission 的协作（防御纵深）

> **Hook 的 `allow` 不能绕过 settings.json 的 `deny` 规则**。这是防御纵深。

具体协作逻辑：
- Hook 决定 allow
- 但 settings.json 的 deny 规则仍然生效（不绕过）
- 也就是说 deny > hook allow

### 6.7 方法论价值

> **Hook 体系是 harness 真正"可扩展"的关键**。所有的项目级规则、组织级规则、插件规则，都通过 hook 注入。用户不需要改 CLI 源码就能扩展 harness。

---

## 7. 第 5 层：TodoWrite / Task V2 / Plan Mode（让规划变成状态机）

### 7.1 作用

让模型**自驱地拆解任务、追踪进度、保持规划意识**。这是把"规划"从"提示词里的口号"变成"模型必须持续维护的状态机"。当前系统同时维护两套平行的任务跟踪系统：

```
isTodoV2Enabled()
  ├─ true  → Task V2（TaskCreate / TaskUpdate 工具 + 文件持久化）
  └─ false → TodoWrite V1（TodoWrite 工具 + AppState 运行时内存）
```

两套系统通过附件系统 (`attachments.ts`) 统一路由提醒机制的入口，在函数内部根据 feature flag 分路。

### 7.2 V1: TodoWrite（deferred tool + AppState 内存状态）

#### 核心数据结构

```typescript
// src/utils/todo/types.ts
TodoItem {
  content: string      // 命令式描述，如 "Run tests"
  status: 'pending' | 'in_progress' | 'completed'
  activeForm: string   // 现在进行时描述，如 "Running tests"
}
TodoList = TodoItem[]  // 由 AppState.todos[agentId] 持有
```

每个待办项包含 content、status、activeForm 三个字段。整个列表通过 AppStateStore 的 `todos: { [agentId: string]: TodoList }` 字段持有。

#### TodoWrite 工具设计

TodoWrite 是一个 **deferred tool**（通过 `shouldDefer: true` 标记），意味着它不会阻塞主执行循环：

```
模型调用 TodoWrite({ todos: [...] })
  → checkPermissions() 直接允许（无权限检查）
  → call() 执行核心逻辑:
    1. 从 AppState 获取当前 agent 的 todo 列表
    2. 如果所有项都 completed，清空列表
    3. 更新 AppState.todos[agentId]
    4. 返回 oldTodos + newTodos
  → mapToolResultToToolResultBlockParam() 生成返回消息:
     - "Todos have been modified successfully..."
     - 如果完成 3+ 项但没有验证步骤，自动提醒使用验证 agent
```

**关键设计点**：
1. **按 agentId 隔离**：每个 subagent/主线程有独立的 todo 列表
2. **自动清理**：所有项完成时自动清空列表（避免 stale state）
3. **验证 nudge**：完成 3+ 项且没有验证步骤时，自动推荐使用验证 agent
4. **非阻塞**：`shouldDefer: true`，不中断主执行循环

#### V1 状态存储

存在 `AppStateStore` 中的 `todos: { [agentId: string]: TodoList }` 字段。这是一个**运行时状态**，不持久化到磁盘——session 重启后通过 `extractTodosFromTranscript()` 从 transcript 中恢复。

#### V1 提醒机制

提醒配置参数：

```typescript
TODO_REMINDER_CONFIG = {
  TURNS_SINCE_WRITE: 10,         // 距离上次 TodoWrite 10 轮后触发
  TURNS_BETWEEN_REMINDERS: 10,   // 距离上次提醒 10 轮后再提醒
}
```

触发逻辑：

```
每个用户消息提交时，getAttachments() 被调用
  → maybe('todo_reminders', ...) 尝试生成提醒
    → 检查 TodoWrite 工具是否在当前 tool set 中
    → 检查是否在 Brief/SendUserMessage 模式下（不提醒）
    → getTodoReminderTurnCounts(messages):
       从后往前扫描消息列表:
         - 统计 assistant 消息数 (跳过 thinking)
         - 找到最近的 TodoWrite tool_use → 记录位置
         - 找到最近的 todo_reminder attachment → 记录位置
       返回: turnsSinceLastTodoWrite, turnsSinceLastReminder
    → 只有两个条件都满足才生成提醒:
       turnsSinceWrite >= 10 && turnsSinceReminder >= 10
    → 从 AppState.todos[agentId] 取出当前 todos
    → 生成 { type: 'todo_reminder', content: todos, itemCount } attachment
```

提醒渲染为 system-reminder 样式的元消息：

```
case 'todo_reminder':
  → 格式化: "1. [pending] task1\n2. [in_progress] task2\n..."
  → 生成 meta user message:
     "The TodoWrite tool hasn't been used recently..."
     + (如果有 todo 项) "Here are the existing contents..."
  → 包装为 system-reminder 样式消息注入到对话中
```

提醒被注入为 **系统级别的元消息**（`isMeta: true`），模型能看到但用户界面不直接显示。不进 REPL UI、不进 mutableMessages。

### 7.3 V2: Task 系统（文件持久化）

`src/utils/tasks.ts` 提供的 V2 系统由 **4 个工具 + 1 个存储引擎** 组成。每个工具都是 `shouldDefer: true`（非阻塞，不影响主执行循环）。

#### 文件存储架构

每个任务以独立 JSON 文件存储在磁盘上：

```
~/.cline/tasks/{taskListId}/
  ├── 1.json        # 任务 #1
  ├── 2.json        # 任务 #2
  ├── .lock         # 任务列表级锁文件（防止并发写入冲突）
  └── .highwatermark  # 最高 ID 记录（防止被删除的 ID 被重用）
```

**taskListId 的解析优先级**：
1. `CLAUDE_CODE_TASK_LIST_ID` 环境变量
2. 进程内 teammate → 使用 team name
3. `CLAUDE_CODE_TEAM_NAME`
4. Leader 的 team name（由 TeamCreate 设置）
5. 回退到 session ID

#### 工具 1：`TaskCreate` — 创建任务

**输入：**
```json
{
  "subject": "实现用户注册功能",
  "description": "需要包含表单验证、密码加密、数据库存储",
  "activeForm": "实现用户注册功能中",
  "metadata": { "priority": "high" }
}
```

**后端执行流程：**
```
TaskCreateTool.call()
  → getTaskListId() → 解析出 taskListId
  → createTask(taskListId, data)
      → 获取列表级文件锁 (~/.cline/tasks/{taskListId}/.lock)
      → findHighestTaskId() → 取磁盘文件最大ID + high water mark 最大值
      → 设新ID = maxId + 1
      → 写文件 {taskListId}/{newId}.json（含 id/subject/description/activeForm/status/blocks/blockedBy/metadata）
      → 释放锁
      → notifyTasksUpdated() → 通知 UI 刷新
  → 执行 TaskCreated hooks（如审计日志）
  → 自动展开 UI 任务面板
```

**返回（模型看到的 tool result）：**
```
Task #1 created successfully: 实现用户注册功能
```

#### 工具 2：`TaskGet` — 查看单个任务详情

**输入：** `{ "taskId": "1" }`

**后端执行流程：**
```
TaskGetTool.call({ taskId: "1" })
  → getTaskListId() → "my-session-123"
  → getTask("my-session-123", "1")
      → readFile(~/.cline/tasks/my-session-123/1.json)
      → JSON 解析
      → 状态迁移（旧的 open→pending, resolved→completed 等）
      → Zod schema 验证
      → 返回 Task 对象
```

**返回：**
```
Task #1: 实现用户注册功能
Status: pending
Description: 需要包含表单验证、密码加密、数据库存储
```

#### 工具 3：`TaskList` — 查看所有任务

**输入：** 空对象

**后端执行流程：**
```
TaskListTool.call()
  → getTaskListId()
  → listTasks("my-session-123")
      → readdir(~/.cline/tasks/my-session-123/)
      → 过滤出 *.json 文件
      → 并行读取每个 JSON 文件
      → 过滤掉 metadata._internal 的内部任务
  → 对每个任务构建摘要: { id, subject, status, owner, blockedBy }
  → 过滤掉已完成的 blockedBy 引用（已完成的不算阻塞）
```

**返回：**
```
#1 [pending] 实现用户注册功能
#2 [pending] 实现用户登录功能 (alice)
#3 [in_progress] 编写单元测试 (bob)
#4 [pending] 实现密码重置功能 [blocked by #1]
```

#### 工具 4：`TaskUpdate` — 更新任务（核心工具）

支持 6 种操作类型，均通过同一工具的不同输入参数实现：

##### 操作类型 1：标记任务状态
```json
{ "taskId": "1", "status": "in_progress" }
```
后端：→ getTask → 比较状态变更 → swarm 模式自动设 owner → 文件锁 → 合并写入。

##### 操作类型 2：标记任务完成（含 hook 执行）
```json
{ "taskId": "1", "status": "completed" }
```
后端：→ 执行 TaskCompleted hooks（可阻塞，如通知外部系统）→ 写入文件 → 如果所有任务都完成且 3+ 项且无 verification 步骤 → 自动追加验证 nudge 提示。

**返回：**
```
Updated task #1 status
Task completed. Call TaskList now to find your next available task or see if your work unblocked others.

NOTE: You just closed out 3+ tasks and none of them was a verification step. Before writing your final summary, spawn the verification agent.
```

##### 操作类型 3：删除任务（硬删除）
```json
{ "taskId": "3", "status": "deleted" }
```
后端：→ 先更新 high water mark（防止 ID 重用）→ unlink 删除 JSON 文件 → 遍历所有其他任务清除对 #3 的依赖引用。注意这是**硬删除**（unlink 文件），不是软标记。

##### 操作类型 4：修改任务描述信息（增量更新）
```json
{
  "taskId": "2",
  "subject": "实现手机号登录功能",
  "description": "改为使用手机号+验证码方式",
  "activeForm": "实现手机号登录中"
}
```
后端：→ getTask → 逐个字段比较 → 只发送有变化的字段 → 文件锁 → 合并写入。返回列出了具体更新的字段名。

##### 操作类型 5：设置任务依赖
```json
{ "taskId": "4", "addBlockedBy": ["1", "2"] }
```
后端：→ 对每个 blocker ID 调用 `blockTask()` → 双向更新：blocker 的 `blocks` 加 `"4"`，被阻塞者 `blockedBy` 加 `"1"/"2"`。

##### 操作类型 6：分配 owner
```json
{ "taskId": "4", "owner": "alice" }
```
后端：→ 更新 owner 字段 → swarm 模式下自动 `writeToMailbox("alice", task_assignment)`。

#### 完整的生命周期示例

```
=== 阶段 1：创建任务 + 设置依赖 ===
模型:
  → TaskCreate("实现用户注册")        → #1 created
  → TaskCreate("实现文章发布")        → #2 created
  → TaskCreate("实现评论功能")        → #3 created
  → TaskCreate("编写测试")           → #4 created
  → TaskUpdate({ id:2, addBlockedBy:["1"] })
  → TaskUpdate({ id:3, addBlockedBy:["1","2"] })
  → TaskUpdate({ id:4, addBlockedBy:["2","3"] })

  磁盘文件状态:
    #1 [pending] 实现用户注册
    #2 [pending] 实现文章发布 [blocked by #1]
    #3 [pending] 实现评论功能 [blocked by #1, #2]
    #4 [pending] 编写测试 [blocked by #2, #3]

=== 阶段 2：开始执行 + 中途插入新需求 ===
模型:
  → TaskUpdate({ id:1, status:"in_progress" })  → 开始编码
  → 用户:"加一个文章分类管理功能"
  → TaskCreate("实现文章分类管理")  → #5 created
  → TaskUpdate({ id:5, addBlockedBy:["2"] })

=== 阶段 3：修改/删除任务 ===
模型:
  → TaskUpdate({ id:3, subject:"一级评论（简化）", description:"..." })
  → 用户:"测试先不写"
  → TaskUpdate({ id:4, status:"deleted" })  ← 磁盘 4.json 被 unlink

=== 阶段 4：完成→流转到下一个 ===
模型:
  → TaskUpdate({ id:1, status:"completed" })
      ← "completed. Call TaskList to find next task..."
  → TaskList() → #2 的 blockedBy 变空了 → 可以做了
  → TaskUpdate({ id:2, status:"in_progress" })
```

#### V2 变更机制的 5 个要点

| # | 能力 | 怎么做 | 工具 |
|---|------|--------|------|
| 1 | **新增任务** | 随时创建新任务，自动分配自增 ID | `TaskCreate` |
| 2 | **修改未开始的任务** | 改标题/描述/activeForm，swarm 模式还能分配 owner | `TaskUpdate` |
| 3 | **删除不需要的任务** | 硬删除（unlink 文件），自动清除依赖引用 | `TaskUpdate({ status:"deleted" })` |
| 4 | **建立/修改依赖** | 双向设置谁阻塞谁，TaskList 显示时自动过滤已完成的 blocker | `TaskUpdate({ addBlockedBy })` |
| 5 | **当前执行不变** | 所有 task 工具都是 `shouldDefer: true`，不阻塞主循环 | 架构层保证 |

#### V2 提醒机制

V2 提醒走相同的架构入口，在 `getAttachments()` 内根据 `isTodoV2Enabled()` 分路：

```
getAttachments()
  → isTodoV2Enabled()
    ? getTaskReminderAttachments()  // V2 路径
    : getTodoReminderAttachments()  // V1 路径
```

V2 提醒触发条件与 V1 相同（10 轮未使用 + 10 轮未提醒），但扫描的是 TaskCreate/TaskUpdate 工具调用而非 TodoWrite。提醒内容格式化输出当前所有任务摘要。

### 7.4 Desktop/Tauri 集成

`desktop/src/stores/chatStore.ts` 中通过两种方式获取任务数据：
1. **实时监听**：检测 TodoWrite tool_use（V1）/ TaskCreate/TaskUpdate tool_use（V2），直接从工具输入参数中提取任务列表
2. **历史提取**：从消息历史中反向提取最近的 TodoWrite/Task 调用，用于展示 task 面板

```typescript
// V1: 监听 TodoWrite
if (toolName === 'TodoWrite' && Array.isArray(msg.input?.todos)) {
  useCLITaskStore.getState().setTasksFromTodos(msg.input.todos)
}
// V2: 监听 Task 工具
if (['TaskCreate', 'TaskUpdate'].includes(toolName) && msg.input?.taskId) {
  // 从文件系统读取最新任务列表
}
```

### 7.5 V1 Todo 状态生命周期

```
┌─────────────────────────────────────────────────────────────┐
│                   消息循环 (query.ts)                         │
│                                                              │
│  1. getAttachments()  → 可能附加 todo_reminder               │
│  2. buildAttachmentMessages() → 转为 API 消息                 │
│  3. 发送到 API → 模型看到提醒                                 │
│  4. 模型选择:                                                │
│     ├─ 忽略提醒 → 继续执行                                    │
│     └─ 调用 TodoWrite → TodoWriteTool.call()                  │
│                        → context.setAppState() 更新 todos     │
│                        → AppStateStore 更新                   │
│  5. 下一轮循环 → 重新检查 TURNS_SINCE_WRITE                   │
└─────────────────────────────────────────────────────────────┘
```

### 7.6 V1 vs V2 核心对比

| 维度 | V1 TodoWrite | V2 Task |
|------|-------------|---------|
| 工具数量 | 1 个（TodoWrite）| 4 个（TaskCreate / TaskGet / TaskList / TaskUpdate）|
| 存储方式 | AppStateStore 运行时内存 | 文件系统（独立 JSON 文件 + .lock + .highwatermark）|
| 状态恢复 | extractTodosFromTranscript()（依赖 transcript）| 文件系统读取（独立持久化）|
| 数据结构 | TodoItem { content, status, activeForm } | Task { id, subject, description, status, owner, blocks, blockedBy, activeForm, metadata } |
| 任务依赖 | 不支持 | 支持双向依赖（blocks / blockedBy）|
| 任务分配 | 不支持 | 支持 owner + swarm mailbox 通知 |
| 删除方式 | 清空列表（自动） | 硬删除（unlink 文件）+ 清除依赖引用 |
| 增量修改 | 全量替换 todos 数组 | 增量更新（仅发送变化的字段）|
| 桌面集成 | 监听 TodoWrite tool_use | 监听 TaskCreate/TaskUpdate + 文件系统读取 |
| 提醒周期 | 10+10 轮 | 10+10 轮（走相同入口，内部路由）|
| 切换条件 | isTodoV2Enabled() === false | isTodoV2Enabled() === true |

### 7.7 Plan Mode：进入/退出/验证的封闭状态机

**Plan 模式的三段式闭环**：

```
EnterPlanMode → 写 plan → ExitPlanMode（保存到文件）
    ↓
[实现阶段]
    ↓
VerifyPlanExecution → 确认完成（被 attachments 强制提醒 N 轮）
```

**关键设计点**：

- **进入 plan**：permission mode 切换到 `plan`，**禁止写操作**；prompt 文档里详尽列出"应该用 plan mode 的 7 种场景"和"不该用的 4 种场景"
- **退出 plan**：必须**写到 plan 文件**（持久化到 `~/.claude/plans/<plan-id>.md`）；同时记录 prePlanMode，退出时恢复
- **验证执行**：在 ExitPlanMode 之后，模型应该调用 `VerifyPlanExecutionTool` 来**确认自己真的按计划实现了**；每 N 轮 reminder 提醒一次

### 7.8 方法论价值

> **把"规划"从模型脑子里挖出来，放进 AppState 或文件系统**——这才是让规划"可被 harness 看见"和"可被强制提醒"的关键。如果规划只在模型脑子里，再好的 prompt 也救不了。

**协同关系**：
- L1（系统提示词）告诉 agent "用 TodoWrite"
- L5（TodoWrite 工具 + Task V2）让任务追踪真正发挥作用
- L6（nudge）会每 10 轮提醒 agent 更新 todo
- V2 文件持久化比 V1 AppState 更可靠（重启恢复不依赖 transcript）

### 7.9 提示词与 Task/Todo 系统的五层协同

系统提示词不是唯一的引导机制——它只是 **5 层协同体系**的第一层。整个系统从不同层面指导模型正确使用任务管理功能：

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. 系统提示词 (编译时)  ← 顶层引导                              │
│    "Break down and manage your work with the TaskCreate tool"   │
│    → 让模型知道有任务管理功能                                     │
├─────────────────────────────────────────────────────────────────┤
│ 2. 工具 Schema (运行时)  ← 工具级使用说明                        │
│    每个 Task 工具通过 prompt() 返回详细的使用文档                 │
│    → 告诉模型何时用、怎么用、参数含义                              │
├─────────────────────────────────────────────────────────────────┤
│ 3. 每轮消息自动注入 (按轮触发)  ← 被动提醒                       │
│    getTaskReminderAttachments()                                  │
│    → 10 轮没用过任务工具 → 注入系统级提醒                         │
│    + 列出当前所有任务                                             │
├─────────────────────────────────────────────────────────────────┤
│ 4. 工具执行结果 (工具返回)  ← 主动下一步引导                      │
│    TaskUpdate 完成时自动附带下一步提示                             │
│    "Call TaskList to find your next available task..."           │
├─────────────────────────────────────────────────────────────────┤
│ 5. 工具权限控制 (注册时)  ← 可见性控制                           │
│    V1/V2 互斥、异步 agent 只开放 TodoWrite                       │
│    进程内 teammate 全部 Task 工具可用                             │
└─────────────────────────────────────────────────────────────────┘
```

#### 第一层：系统提示词（主 Prompt）

位置：`src/constants/prompts.ts:269-314`，函数 `getUsingYourToolsSection()`。

**关键机制**：根据 V1/V2 动态选择工具名称 `find([TASK_CREATE_TOOL_NAME, TODO_WRITE_TOOL_NAME])`。生成的提示文本中只提一个名字（TaskCreate 或 TodoWrite），但其他工具（TaskUpdate、TaskList、TaskGet）不出现在顶层提示词——它们通过各自的工具 `description` 和 `prompt()` 方法注入到模型的 tool schema 中。

生成的提示内容（`# Using your tools` 段）：
```
 - Break down and manage your work with the TaskCreate tool.
   These tools are helpful for planning your work and helping the user
   track your progress. Mark each task as completed as soon as you are
   done with the task. Do not batch up multiple tasks before marking
   them as completed.
```

#### 第二层：每个工具自己的 Prompt

每个 Task 工具通过 `prompt()` 方法返回详细使用说明。

**TaskCreate**（`src/tools/TaskCreateTool/prompt.ts`）：
- 使用场景：复杂多步任务（3+ 步骤）、Plan mode、用户要求 todo、用户提供多项任务、收到新指令后立即创建、**开始做之前标记 in_progress**、完成后标记 completed
- 不适用场景：单一简单任务、琐碎无收益
- 字段：subject、description（必填）、activeForm（可选，给 spinner 用）
- 提示：创建后使用 TaskUpdate 设置依赖、先用 TaskList 检查避免重复

**TaskUpdate**（`src/tools/TaskUpdateTool/prompt.ts`）：
- 可更新字段：status（pending→in_progress→completed）、subject、description、activeForm、owner、addBlocks/addBlockedBy
- 提示：更新前先 TaskGet 获取最新状态
- 示例展示了全部 6 种操作

**TaskList**（`src/tools/TaskListTool/prompt.ts`）：
- 使用场景：查看可用任务（pending、无 owner、未阻塞）、检查整体进度、查找被阻塞的任务
- Teammate (swarm) 模式：完成后调用 TaskList 找活 → 选 pending 且未阻塞的任务 → 用 TaskUpdate 认领 → 如果被阻塞则通知 team lead

**TaskGet**（`src/tools/TaskGetTool/prompt.ts`）：
- 单个任务详情查看
- 提示：开始工作前检查 blockedBy 是否为空

#### 第三层：自动注入的提醒（Attachment 系统）

位置：`src/utils/attachments.ts:3371-3415`，函数 `getTaskReminderAttachments()`。

这是**最关键的配合机制**——不是提示词，而是每轮用户消息提交时自动注入的系统消息：

```
每轮用户消息提交时:
  → 检查 TaskUpdate 工具是否可用
  → 计算距离上次 TaskCreate/TaskUpdate 的助理轮数
  → 如果连续 10 轮没用过任务工具 → 自动注入提醒消息

提醒消息内容（isMeta: true，仅模型可见）:
  "The task tools haven't been used recently. If you're working on tasks 
   that would benefit from tracking progress, consider using TaskCreate to 
   add new tasks and TaskUpdate to update task status..."

  + (如果有任务):
    "Here are the existing tasks:
     #1 [in_progress] 实现用户注册 (alice)
     #2 [pending] 实现文章发布"
```

提醒包装为 `isMeta: true` 用户消息，每次提醒后冷却 10 轮，确保不过度打扰。

#### 第四层：工具执行结果的下一步引导

工具返回值本身也是引导的一部分。例如 TaskUpdate 标记完成时的返回：

```
Updated task #1 status
Task completed. Call TaskList now to find your next available task or see if your work unblocked others.

NOTE: You just closed out 3+ tasks and none of them was a verification step. Before writing your final summary, spawn the verification agent (subagent_type="verify"). You cannot self-assign PARTIAL by listing caveats in your summary — only the verifier issues a verdict.
```

这种"完成 → 推荐下一步"的模式是**主动引导**：不等待模型自己决策，而是工具返回直接告诉模型"接下来应该做什么"。

#### 第五层：工具可用性控制

**工具注册互斥**（`src/tools.ts:194-221`）：
```typescript
TodoWriteTool.isEnabled()  → !isTodoV2Enabled()
V2 工具.isEnabled()        → isTodoV2Enabled()  // 两者互斥
```

**异步 agent 限制**（`src/constants/tools.ts:55-71`）：
- 异步 agent **不包含** TaskCreate/TaskUpdate/TaskList/TaskGet
- 但包含 `TODO_WRITE_TOOL_NAME`（第 58 行）
- 原因：异步 agent 不能操作文件持久化的任务列表，但可以用内存 TodoWrite

**进程内 Teammate 限制**（`src/constants/tools.ts:77-88`）：
- 包含**全部** Task 工具
- 队友可通过 TaskList 找活、TaskUpdate 认领、TaskCreate 创建

#### 完整配合示例

```
用户: "帮我实现一个博客系统，需要注册、文章发布、评论功能"

模型看到的 5 层引导:
  1. 系统提示词: "Break down and manage your work with the TaskCreate tool"
  2. TaskCreate 工具描述: "创建任务，用于跟踪进度"
  
模型行为:
  → TaskCreate("实现用户注册")  → #1 created
  → TaskCreate("实现文章发布")  → #2 created
  → TaskCreate("实现评论功能")  → #3 created

  5 轮后（如没用过 TaskUpdate）:
  3. 自动提醒: "The task tools haven't been used recently..."
  
  完成用户注册后:
  → TaskUpdate({ id:1, status:"completed" })
  4. 工具返回: "Task completed. Call TaskList to find your next task"
  → TaskList()
  → TaskUpdate({ id:2, status:"in_progress" })

  用户中途说 "加分类管理":
  → TaskCreate("实现文章分类管理")  → #4 created

  用户说 "评论不需要":
  → TaskUpdate({ id:3, status:"deleted" })
```

**核心设计哲学**：系统不强制模型使用任务工具，而是通过**三层引导**（提示词 → 工具描述 → 自动提醒）逐步推动，同时在工具返回值中给出**下一步指引**，并在**工具注册层**控制不同 agent 类型的可见性。

---

## 8. 第 6 层：Per-Turn 动态附件（实时提醒系统）

### 8.1 作用

每轮 iteration 末尾，**根据"刚刚发生了什么"**动态生成若干 attachment，强制让模型注意到"你可能忘了的事"。这是 harness 的"实时提醒层"。

### 8.2 附件的种类

| 附件类型 | 触发条件 | 作用 |
|---------|---------|------|
| `todo_reminder` | TodoWrite 后 ≥N turns 没再写 | 提醒更新 todo |
| `plan_mode_reminder` | 在 plan mode 中持续 | 每 N turns 提醒"还在 plan mode" |
| `verify_plan_reminder` | plan 未验证 + ≥N turns | 提醒调用 VerifyPlanExecution |
| `auto_mode_reminder` | 在 auto mode | 持续提醒模式 |
| `max_turns_reached` | turnCount ≥ maxTurns | 通知到上限 |
| `compaction_reminder` | 对话已被压缩 | 提醒"上下文被压缩了" |
| `changed_files` | 本轮 git diff 变化 | 通知文件变更 |
| `nested_memory` | 进入新目录 | 注入子目录 CLAUDE.md |
| `relevant_memories` | AutoMem 路径 | 注入相关记忆 |
| `deferred_tools_delta` | 工具集变化 | 通知新工具 |
| `mcp_instructions_delta` | MCP 客户端变化 | 通知新 MCP 指令 |
| `teammate_mailbox` | teammate 模式 | 收件箱 |
| `queued_command` | 用户排队的 prompt | 注入待处理命令 |
| `date_change` | 日期变更 | 通知日期变了 |
| `hook_additional_context` | hook 触发 | hook 注入的上下文 |
| `brief` | 任务简报 | 任务简报 |
| `token_usage` / `budget_usd` | 配额监控 | 注入 token 消耗 |

### 8.3 Nudge 的核心算法

**核心思路**：

```text
1. 不发 nudge 的条件
   - 工具不可用 → return []
   - 简报工具优先 → return []
   - 距上次写入 < 阈值 → return []
   - 距上次提醒 < 阈值 → return []  # 不重复骚扰

2. 发 nudge
   return [{ type: 'todo_reminder', content: <当前 todo 列表>, itemCount: N }]
```

**关键设计**：
- 不仅提醒"该写 todo 了"，还把**当前 todo 列表**作为内容回显给模型 → "你忘了这些事"
- 整个算法**只读 messages**，因此**compact 后自然重置**（旧 todo_reminder 已经被 compact 抹掉）

### 8.4 方法论价值

> **"实时提醒"是 harness 把"软约束"持续注入到模型注意力的关键机制**。模型会"忘记"，harness 就周期性"重新提醒"。

要点：
- **去重逻辑**：同一类型 nudge 有最小间隔（如每 10 轮），避免每轮刷屏
- **不污染 prompt cache**：attachments 写在 messages 头部（[0..N]），跟 system prompt 分开
- **基于"刚刚发生了什么"**：每轮的 nudge 都是由"前 N 轮的事件"触发的，不是固定模板

---

## 9. 第 7 层：压缩后规则再激活（让压缩不丢约束）

### 9.1 作用

auto-compact 会丢弃大量历史（用 summary 替代），但**规则的"在场"不能因此中断**。本层负责在 compact boundary 之后**立刻重新注入**所有 layers 的内容。

### 9.2 重新注入的具体机制

1. **compact_boundary attachment**：标记压缩点 + 触发 splice 清空 boundary 之前的内容
2. **summary messages**：fork agent 生成的总结（替换掉被压缩的旧 messages）
3. **hook 重新触发**：
   - `PostCompact` hook 被调用
   - 所有 hook 返回的 `additionalContext` 重新拼到 boundary 之后
4. **attachments 重新计算**：
   - `getAttachmentMessages` 在新 messages 上重新跑
   - 重新决定 plan_mode_reminder / todo_reminder / verify_plan_reminder / 等
5. **Skills / Rules 重新加载**：cache 失效后下次 query 入口重新走 prepend

### 9.3 各种行为约束在压缩后如何"恢复"

| 行为约束 | 压缩后如何恢复 |
|---------|--------------|
| 系统提示词静态段 | **本来就在 cache 里**（global scope），无影响 |
| CLAUDE.md Rules | 重新走 prependUserContext，拼到 boundary 后的第一条 message |
| Permission mode | `appState.toolPermissionContext.mode` 跨 compaction 持久 |
| Hooks 配置 | 持续监听配置文件（bootstrap） |
| TodoWrite 状态 | `appState.todos` 跨 compaction 持久 |
| plan mode state | `appState.toolPermissionContext.mode === 'plan'` 跨 compaction 持久 |
| 附件（plan_mode_reminder 等）| 在新 messages 上重新计算 |
| `prePlanMode` | 持久（`appState.toolPermissionContext.prePlanMode`）|

### 9.4 reactive compact（API 错误抢救）

当 API 返回 `413 prompt-too-long` 时，reactive compact 会**在用户不知情的情况下**自动压缩并重试。**规则在场机制与 autoCompact 完全一致**。

### 9.5 关键不变量

> **compact 永远不能消除"规则"**——所有规则都通过 L1/2/3/4/5/6 重新表达，compact 抹掉的只是"已发生的对话"，**不会抹掉约束**。

> **boundary 是"信任锚点"**：boundary 之后的所有内容都被认为"是新的、可信的、需要重新遵守规则"。

### 9.6 方法论价值

> **压缩不仅是"释放空间"，更是"重新建立约束"**。把"压缩后立刻重做 L1-L6 的所有再注入"作为强制流程，是 harness 不会因长会话而"飘掉"的关键。

---

## 10. 第 8 层：Subagent 隔离（以子代理为单位的规则分舱）

### 10.1 作用

当主 agent 把任务委派给 subagent 时，subagent 拥有**独立**的 system prompt、message stream、permission mode、todo 列表。**harness 不是全局唯一的，而是每个 subagent 一份**。

### 10.2 Subagent 的独立状态

| 状态 | 主 agent | Subagent |
|------|---------|---------|
| system prompt | 主 agent 的 | subagent 自己的 |
| messages stream | 共享 REPL | 独立的 message stream |
| permission mode | 主 agent 的 mode | worker 的 mode（默认 acceptEdits）|
| tool pool | 主 agent 的 | 独立组装（可能比主 agent 少）|
| todo list | `appState.todos[mainSessionId]` | `appState.todos[agentId]` |
| todo reminder 触发 | 是 | 是（独立计数）|
| hooks | 共享 | 共享（但 `agent_id` 字段区分）|
| abort controller | 共享 | 独立（background agents 独立）|

### 10.3 SubagentStart / SubagentStop hooks

- `SubagentStart`：subagent 启动时 → 可以 inject additionalContext
- `SubagentStop`：subagent 完成时 → 可以 `continue: false` 阻止主 agent 接受结果

**这是"subagent 质量控制"的标准机制**——主 agent 不需要盲目相信 subagent 的结果。

### 10.4 Fork subagent（cache-identical 路径）

`isForkSubagentEnabled()` 时，`AgentTool` 走 fork 路径：
- 继承父 system prompt（cache-identical API request prefix）
- prompt messages 包含父的全部 assistant + placeholder tool_results + 指令

**关键设计**：fork child **继承父的全部历史**（messages）+ 父的 system prompt，所以**子代理在主代理"看着"的所有规则下运行**——harness 不会因为 fork 而丢失。

### 10.5 关键设计：subagent 的 tools 是独立组装的

subagent 的 worker permission context 是独立构造的（默认 `acceptEdits`）。这意味着：
- subagent 的可用工具**可能比主 agent 少**（如 `permissionMode: 'plan'` 时 subagent 没有写工具）
- **harness 的规则通过工具的可见性下沉到 subagent**

### 10.6 方法论价值

> **harness 应该是"可分割"的**——把任务委派给 subagent 时，规则、责任、状态都跟着分割，不能"全局唯一"地耦合。这让多 agent 协作成为可能。

---

## 11. 贯穿：每轮 iteration 的"全量再注入"管线

把 8 层放在一次 iteration 的时间线里看：

```
QueryEngine.submitMessage() — 用户一轮入口
  → query() 进入 while(true) 循环
       ↓
[A] fetchSystemPromptParts() — L1+L2 加载
    并行：
    ├─ getSystemPrompt()      → [静态段] + [动态段] (L1)
    └─ getUserContext()       → { claudeMd, currentDate } (L2)
       ↓
[B] processUserInput()
    ├─ 解析 slash command
    ├─ 解析 @file / image attachment
    └─ getAttachmentMessages() — L6 加载
        ├─ nested_memory (L2/conditional rules)
        ├─ changed_files
        ├─ skill_discovery
        ├─ todo_reminders (L6 nudge)
        ├─ plan_mode / auto_mode reminders (L6 nudge)
        ├─ verify_plan_reminder (L6 nudge)
        └─ hook_additional_context (L4 from earlier hook runs)
       ↓
[C] normalize + prependUserContext
    ├─ prependUserContext(messages, userContext) → 第一条 isMeta user msg
    │   包含 <system-reminder>Rules + date</system-reminder>
    └─ 各 messages 已经被 microCompact / snipCompact 收缩（L7 配合）
       ↓
[D] callModel → Anthropic API
    system: [static global-cache] [BOUNDARY] [dynamic]
    messages: [Rules isMeta user] [attachments] [real user] [history]
    tools: [filteredTools]
       ↓
[E] 流式接收 assistant 响应
    每个 tool_use 块到达时：
    ├─ runPreToolUseHooks() (L4) — 收集所有 hook 的 permissionBehavior
    ├─ canUseTool() (L3) — 走 hook 决议 + rules + mode 判定
    ├─ 工具执行
    ├─ runPostToolUseHooks() (L4) — additionalContext / block / etc.
    └─ tool_result 拼回 messages
       ↓
[F] assistant 响应完整
    ├─ needsFollowUp ?
    │   ├─ yes → 拼回 messages，回到 [B]（下一圈）
    │   └─ no  → 走 stop hooks (L4 Stop)，若 continue=false 则继续
    ├─ runStop / runSubagentStop hooks
    └─ turnCount++, 检查 maxTurns (L6 max_turns_reached)
       ↓
[G] submitMessage 结束
    state = { messages, toolUseContext, turnCount, ... }
    mutableMessages 也同步更新
    → 下一轮 submitMessage 从这里开始
```

### 关键观察

- L1 **只在 fetchSystemPromptParts 加载一次**，但通过 global cache 跨 turn 复用
- L2 / L6 **每轮都重新走一遍** getUserContext / getAttachmentMessages
- L3 / L4 **每个 tool_use 都走一遍**
- L5 状态在 `appState` 中**跨 iteration 持久**
- L7 在 autoCompact 触发时**插入到流程中**
- L8 是**独立的状态机**（独立的 system prompt / messages / mode），但与主 agent **共享 hooks 配置和 AppState**

---

## 12. 关键设计模式与不变量

### 12.1 8 层"纵深防御"

```
                     ┌───────────────────────┐
  Layer 1            │ 静态 system prompt    │ ◄─ 永远在场（cache）
                     ├───────────────────────┤
  Layer 2            │ Rules（CLAUDE.md）    │ ◄─ 每轮重新注入
                     ├───────────────────────┤
  Layer 3            │ Permission 模式       │ ◄─ 每个 tool_use 必走
                     ├───────────────────────┤
  Layer 4            │ Hooks (27 events)     │ ◄─ 每个 lifecycle 事件
                     ├───────────────────────┤
  Layer 5            │ TodoWrite/Plan        │ ◄─ 模型自驱 + 系统强制
                     ├───────────────────────┤
  Layer 6            │ Per-Turn Nudges       │ ◄─ 实时行为提醒
                     ├───────────────────────┤
  Layer 7            │ Compact 重新激活      │ ◄─ 压缩不丢约束
                     ├───────────────────────┤
  Layer 8            │ Subagent 隔离         │ ◄─ 委派时规则分舱
                     └───────────────────────┘
```

**不变量**：任何单层失效，其他层都能继续工作。
- Rules 被压缩 → L7 重新激活
- Permission mode 被改 → L4 hook 可以 deny
- TodoWrite 忘了写 → L6 todo_reminder 提醒
- Plan mode 退出 → L6 plan_mode_reminder 提示还在 plan
- Subagent 跑偏 → L4 SubagentStop hook 可阻止主 agent 接受

### 12.2 共同的"per-turn 再注入"模式

所有"在多轮中持续起作用"的机制都遵循同一种模式：

1. **状态写在 AppState 或 sessionState**（跨 iteration 持久）
2. **每轮 query() 入口重新加载**（per-turn 重新激活）
3. **通过 prependUserContext / getAttachmentMessages 拼到 messages 头部**（不破坏 prompt cache）
4. **压缩后从 AppState 恢复**（L7 重新激活）

### 12.3 prompt cache 友好性

| 数据 | 缓存策略 |
|------|---------|
| 系统提示词静态段 | global（跨 session）|
| 系统提示词动态段 | null（per-call）|
| Rules (CLAUDE.md) | null（per-call）|
| Tools schema base | session-stable base + per-request overlay |
| Tool result 替换 | byte-identical（永不重写）|
| 附件 (nudges) | 进 messages 头部，per-turn 重算 |
| Todo 状态 | appState 跨 iteration，不进 messages |
| **Snip/Collapse 短 ID** | REPL state 保留原始内容，API 只发短 ID（零 cache 影响）|

> 关于**投影（Projection）**——即 snip 投影、context collapse 投影和替换的完整概念辨析、具体例子和可逆性对比，见 [Claude Code 上下文工程文档](../context-engineering/claude-code-context-engineering.md#5-投影-vs-替换-vs-压缩三种收缩手段) 第 5 章。下文 "每轮 shrink to fit" 管线中步骤 ②~④ 就对应于投影/替换/压缩。

### 12.4 信任模型

- **Hook 必须 trust workspace**——不可信工作区不跑任何 hook
- **Hook 的 allow 不能绕过 deny 规则**——防御纵深
- **Subagent 的 mode 默认 acceptEdits**（不继承主 agent 的 bypass）——防御纵深
- **Plan mode 状态机封闭**（prePlanMode 记录+恢复）——防止 plan 退出后状态泄漏
- **MCP instructions 强制 uncached**（不进 global cache）——防止 MCP 改变行为契约

### 12.5 "规则强度"分类

| 类型 | 机制 | 强度 |
|------|------|------|
| **硬约束** | Permission deny 规则 | 模型绝对无法绕过（tool 直接被拒）|
| **硬约束** | Plan mode mode 切换 | 写工具直接不可见 |
| **硬约束** | Hook deny | tool 直接被拒 |
| **硬约束** | Hook preventContinuation | agent 直接被阻止继续 |
| **硬约束** | SubagentStop hook continue=false | 主 agent 看不到结果 |
| **软约束** | 系统提示词静态段 | 模型"应该遵守"，但无 enforcement |
| **软约束** | Rules（CLAUDE.md）| 模型"应该遵守"，但无 enforcement |
| **软约束** | TodoWrite / Plan mode prompt | 模型"应该使用"，但无 enforcement |
| **软约束** | Per-turn nudges | 模型"应该看到"，但无 enforcement |
| **强制流程** | Compact 重新激活 | 不可绕过，压缩后自动重做 |
| **强制流程** | 每轮 prependUserContext | 不可绕过，每轮自动重做 |
| **强制流程** | 每个 tool_use 走 canUseTool | 不可绕过（API 层强制）|

> **harness 的精髓**：**用"软约束"（prompt）引导模型"主动遵循规则"，用"硬约束"（permission/hook）作为最后防线，用"强制流程"（per-turn 重新注入）保证约束不会因上下文压缩而丢失**。

---

## 13. 可借鉴的工程原则

把上面所有内容提炼成 10 条工程原则：

### 原则 1：纵深防御，别寄希望于单点

不要把"agent 是否会遵守规则"押在单一机制上。把同一个规则在多个层级独立表达：system prompt 一份、Rules 一份、permission 一份、hook 一份。任何一处失效都有其他兜底。

### 原则 2：per-turn 再注入，而非 per-session 一次性

所有"长期有效"的内容，每轮 iteration 都重新走"组装"流程，而不是依赖上下文里的"残留"。**这是"多轮遵循规则"的物理基础。**

### 原则 3：静态/动态分离，是缓存友好的前提

把 system prompt 切成"byte-stable 静态段"和"per-turn 动态段"两段，静态段走跨 session 缓存，动态段每次重算。**这是"低成本地每轮强制重新声明规则"的前提。**

### 原则 4：软约束靠 prompt，硬约束靠 Tool 拦截

能在 Tool 层拦截的，绝不只靠 prompt。模型"答应不删库"是软约束（不可靠），`Bash(rm:*)` 走 deny 规则是硬约束（可靠）。**规则的强度和可执行性必须匹配。**

### 原则 5：Hook 是 harness 的"扩展点"

通过 20+ 个生命周期事件 hook，把 harness 从"项目内置约束"扩展为"可由用户/插件自定义"。**用 hook 体系做规则的可编程化。**

### 原则 6：把"规划"从模型脑子里挖出来

让 TodoWrite/PlanMode 落到 AppState 里，**让规划成为可见、可追踪、可被 harness 强制提醒的状态**。如果规划只在模型脑子里，再好的 prompt 也救不了。

### 原则 7：基于"刚刚发生了什么"动态提醒

每轮的 nudge 都由"前 N 轮的事件"触发，不是固定模板。**实时行为提醒**比静态规则更能保证"当下注意力"。

### 原则 8：压缩后必须重做所有"再注入"

把"压缩后立刻重做 L1-L6 的所有再注入"作为强制流程。**compact 永远不能消除"规则"**。

### 原则 9：Harness 是"可分割"的

把任务委派给 subagent 时，规则、责任、状态都跟着分割。harness 不能"全局唯一"耦合。**这让多 agent 协作成为可能。**

### 原则 10：硬约束的优先级要明确（防御纵深）

> **Hook 的 `allow` 不能绕过 settings.json 的 `deny` 规则**——deny 规则 > hook allow。

类似地，plan mode > 默认 mode，permission > 工具的 default。所有"硬约束"之间必须定义优先级，否则多 layer 协作时会出现规则冲突。

---

## 总结：方法论的三层抽象

读完 Claude Code 的 harness，可以把它的设计思路抽象为三层：

**第一层：规则表达的多样性**
- 同一规则可以用 prompt、permission、hook、tool、state 等多种方式表达
- 表达方式的选择决定了规则的"强度"和"可执行性"

**第二层：执行时机的多样性**
- 同一约束可以在启动时、每轮、每个 tool、每条消息、压缩后等不同时机被重申
- 时机的选择决定了"模型在什么时刻会注意到这个约束"

**第三层：信任边界与防御纵深**
- workspace trust、hook allow vs deny、subagent 隔离、plan mode 状态机
- 信任边界的设计决定了"在什么情况下规则会被强制执行 vs 让步"

**最上层的认知**：

> **harness 的本质不是"训练马怎么想"，而是"用缰绳和围栏确保它不跑偏"**。harness 工程的难度不在"让模型知道规则"，而在"让规则在多轮、长上下文、跨会话中持续生效，且不破坏性能"。
