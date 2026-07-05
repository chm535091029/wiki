# CygCode 上下文管理机制

**核心思路**：每轮 LLM API 调用并不是简单的「System Prompt + 历史消息」拼接，而是一套**多阶段构建、按模型动态重建、双层防御式截断**的精密流水线。核心在于：System Prompt 每轮完整重建、User Message 分层追加、ContextManager 独立负责压缩与去重。

---

## 整体架构设计

上下文管理分为三大层次，每轮遍历一次：

```
┌─ Task 启动层 ─────────────────────────────────────┐
│  startTask() / resumeTaskFromHistory()              │
│  → 清空历史 → 构建初始 userContent → 调用循环      │
│    (Hook: TaskStart / UserPromptSubmit / TaskResume) │
└────────────────────────────────────────────────────┘
                        ↓
┌─ 任务循环层（每轮一次） ──────────────────────────┐
│  recursivelyMakeClineRequests()                     │
│    ① 判断是否需要压缩 (shouldCompact)              │
│    ② loadContext() → @提及解析 + /命令处理          │
│    ③ 追加每轮固定三段（★ 2026-06-17 重排）：       │
│       1. <environment_details>（精简版）            │
│       2. FocusChain todo list（条件性，interval门控）│
│       3. <explicit_instructions>（可选，独立注入）   │
│       4. <workflow_execution_override>（可选，最后） │
│       5. <summarize_task>（可选）                   │
│    ④ addToApiConversationHistory()                  │
│    ⑤ attemptApiRequest() → 构建完整请求发送给 LLM   │
└────────────────────────────────────────────────────┘
                        ↓
┌─ ContextManager 层（消息裁剪） ────────────────────┐
│  ① 检查上一轮 token 是否超阈值                      │
│  ② 优先尝试 file read 去重优化                      │
│  ③ 按策略截断（half/quarter）                        │
│  ④ 插入截断通知                                     │
│  ⑤ 修复 tool_use/tool_result 配对                    │
└────────────────────────────────────────────────────┘
```

**关键设计原则**：
- System Prompt **不缓存**，每轮完整重建（保证规则/技能/终端状态实时生效）
- Rules 和 Skills 内容**每轮重新读取**
- 消息裁剪决策**基于上一轮真实 token 消耗**，构成自适应反馈循环

---

## System Prompt 构建方式

System Prompt 采用**组件化模板引擎**构建，每个 section 是一个独立函数：

```
             ┌─────────────────────────────────────────┐
             │  PromptBuilder.build() 流程               │
             │                                          │
             │  ① buildComponents()                     │
             │     → 按 componentOrder 串行执行各组件    │
             │     每个组件返回 string 或 undefined      │
             │                                          │
             │  ② preparePlaceholders()                 │
             │     → 合并三类占位符：                    │
             │       variant 自定义 / 标准(CWD等) / 运行时 │
             │                                          │
             │  ③ templateEngine.resolve()              │
             │     → 替换 baseTemplate 中的占位符        │
             │                                          │
             │  ④ postProcess()                         │
             │     → 清理空 section 和多余空行           │
             └─────────────────────────────────────────┘
```

**拼装顺序**（generic variant，由 `componentOrder` 决定）：

```
 ① {{AGENT_ROLE}}          "You are Cyg Code..."
 ② {{TOOL_USE}}            全部工具的 XML 调用格式
 ③ {{TASK_PROGRESS}}       task_progress 参数使用说明 [条件]
 ④ {{MCP}}                 已连接 MCP 服务器清单 [条件]
 ⑤ {{EDITING_FILES}}       write_to_file / replace_in_file 用法
 ⑥ {{ACT_VS_PLAN}}         ACT 与 PLAN 模式说明
 ⑦ {{CAPABILITIES}}        工具能力清单
 ⑧ {{SKILLS}}              可用技能元数据 [条件]
 ⑨ {{FEEDBACK}}            反馈引导
 ⑩ {{RULES}}               通用约束规则
 ⑪ {{SYSTEM_INFO}}         当前系统环境
 ⑫ {{OBJECTIVE}}           任务执行原则
 ⑬ {{USER_INSTRUCTIONS}}   用户自定义规则（8 类拼接）
```

**设计思路**：通过组件化和占位符机制，实现：
- 不同模型 variant 可以拥有不同的组件顺序和 baseTemplate
- 条件组件（MCP / SKILLS / TASK_PROGRESS）按上下文自动出没
- 用户规则（.clinerules / .cursorrules / .windsurfrules 等）集中注入在最后

---

## User Message 的构建与分层

每条 user message 不是一段文本，而是一个**多层追加的 content 数组**：

```
┌─ A. 基础内容（任务/反馈阶段注入） ───────────────┐
│  • <task>原始任务</task>         首轮 startTask    │
│  • <user_message>用户反馈</user_message>  后续轮   │
│  • <file_content path="...">     @提及或拖入文件   │
│  • <image> base64                用户拖入图片       │
│  • <hook_context source="...">   hook 注入          │
│  └──── 由 startTask / ask 响应阶段注入 ──────────┘
│                                                    │
├─ B. loadContext 处理 ─────────────────────────────┤
│  • @file: → 解析为 <file_content path="...">       │
│  • /cmd   → 移除命令前缀，保留参数                   │
│     可能匹配 workflow 或内置命令                     │
│  └──── 每轮在 loadContext 中执行 ────────────────┘
│                                                    │
├─ C. ★ 每轮追加块（2026-06-17 重排） ─────────────┤
│  ★ 1. <environment_details>（精简版）  ★★★ 第 1 位   │
│     ├─ # Current Mode（ACT / PLAN）                  │
│     └─ {可选: # Workspace Roots（multi-root时）}     │
│        （其他字段已注释屏蔽）                         │
│                                                    │
│  ★ 2. FocusChain Todo List        [条件: interval]  │
│                                                    │
│  ★ 3. <explicit_instructions      [条件: workflow] │
│         type="<name>" priority="override">          │
│                                                    │
│  ★ 4. <workflow_execution_override> [条件: workflow]│
│        CRITICAL: ...（最后一条指令）                  │
│                                                    │
│  ★ 5. <explicit_instructions      [条件: auto-     │
│         type="summarize_task">        condense]     │
│  └──── 由 recursivelyMakeClineRequests 在末尾追加 ─┘
│                                                    │
└────────────────────────────────────────────────────┘
```

**核心设计思路**：
- 每层独立、按顺序追加，职责清晰
- `environment_details` **已精简为仅 Current Mode + Workspace Roots**，其他字段注释屏蔽
- `<explicit_instructions>` 作为独立字段（不再是 processedText 内嵌）
- `<workflow_execution_override>` 作为最后一条指令，模型回复前形成"最后提醒"
- Hook 注入机制让项目可以扩展自定义 context
- workflow 通过 user message 而非 system prompt 注入，便于临时覆盖

---

## <environment_details> 字段精简（★ 关键变更）

**当前环境**（2026-06-17 精简优化）：`<environment_details>` 块**仅保留两个有效字段**，其余已被**注释屏蔽**（保留旧代码但不再生效）：

```
<environment_details>
{# Current Mode}（ACT MODE / PLAN MODE）
{planModeInstructions 文本}（仅 PLAN 模式下追加）
</environment_details>
```

**已注释屏蔽的字段**：
- `# {platform} Visible Files`
- `# {platform} Open Tabs`
- `# Actively Running Terminals` / `# Inactive Terminals`
- `# Recently Modified Files`
- `# Current Time`
- `# Current Working Directory Files`
- `# Workspace Configuration`
- `# Detected CLI Tools`
- `# Context Window Usage`

> **区分**：System Prompt 中包含 `SYSTEM INFORMATION` 段（`system_info.ts`），提供 OS、IDE、Shell、Home Directory、CWD 等**静态环境信息**。这与 `<environment_details>` 的**动态模式指示**角色互补。

---

## 双层截断防御体系

为了解决长对话的 token 膨胀问题，设计了两层独立截断机制：

```
  Tool 执行结果
       ↓
  ┌─ Handler 层（按工具特性定制） ────────────────────┐
  │  read_file: 默认 1000 行，400KB 字节上限，20MB    │
  │             硬限制                                │
  │  list_files: 最多 200 个文件                      │
  │  MCP 工具/资源: 400KB 上限                       │
  │  Excel: 每 Sheet 50000 行                         │
  │  Subagent: 仅 .trim()，excerpt() 截断已移除      │
  │  └──── 在工具结果返回 messages 之前执行 ────┘     │
  └──────────────────────────────────────────────────┘
       ↓
  ┌─ ContextManager 层（消息级去重+截断） ────────────┐
  │  ① 找重复的 file read / write / @提及             │
  │     → 只保留最后一次，旧版本替换为 NOTE            │
  │  ② 如果节省 < 30%，仍触发截断                     │
  │  ③ 策略:                                         │
  │     half   → 删除一半 user-assistant pair          │
  │     quarter→ 删除 3/4 pair（激进）                 │
  │  ④ 替换首条 user 消息为简洁提示                   │
  │     + 首条 assistant 消息前插入截断通知            │
  │  ⑤ 修复 tool_use/tool_result 配对                 │
  └──────────────────────────────────────────────────┘
       ↓
  最终发给 LLM API
```

**阈值计算的 buffer 思想**：
- 64K context → 预留 27K（实际可用 37K）
- 128K context → 预留 30K（实际可用 98K）
- 200K context → 预留 40K（实际可用 160K）
- 预留空间用于 system prompt + 即将生成的输出

---

## Auto-Condense 机制（next-gen 模型默认）

对于 Claude 4+ / GPT-5 等新一代模型，采用更智能的压缩方式：

```
每次请求前:
  shouldCompact = isNextGenModel && (上轮 token ≥ 阈值)
       │
       ▼
  尝试 file read 去重
       │
       ├── 节省 ≥ 30% → skip auto-compact，靠去重就够
       │
       └── 节省 < 30% → 追加 <summarize_task> 指令
                          ↓
                LLM 调用 summarize_task 工具
                          ↓
                摘要内容注入下一轮作为 user message
                          ↓
                conversationHistoryDeletedRange 增 2
                （覆盖预摘要的 user+assistant 消息）
```

**对比旧版截断**：
- 旧版：直接删除中间消息，LLM 丢失上下文
- Auto-condense：由 LLM 自己生成摘要，保留关键信息

---

## Workflow 的触发与注入机制

Workflow 采用**不进入 System Prompt** 的设计，体现"临时覆盖"的哲学：

```
用户输入: /my-workflow 我想做 X
               │
               ▼
  parseSlashCommands()
    ① 识别 /my-workflow → 从 .clinerules/workflows/ 匹配
    ② 移除斜杠命令，保留 "我想做 X"
    ③ 返回 workflowInstructions
               │
               ▼
  在 userContent 末尾追加三段（★ 顺序已明确）:
    ① <environment_details>（精简模式，第 1 位）
    ② [FocusChain todo list]（条件性）
    ③ <explicit_instructions type="my-workflow.md"
       priority="override">
         {workflow 内容}
       </explicit_instructions>
    ④ <workflow_execution_override>
         CRITICAL: 正在执行该 workflow...
       </workflow_execution_override>
    ⑤ [summarize_task]（可选）
```

**设计意图**：Workflow 是"一次性"的覆盖指令，不应固化在系统角色中。全部使用 `priority="override"` 属性显式标记覆盖权限。

---

## Skills 的三层优先级

Skill 的加载和激活采用**就近优先、远程优先倒置**的合并策略：

```
加载顺序:  project skills → disk-global skills → remote skills
                     └── 都加入同一数组 ──┘

优先级解析（反序遍历，后加入的胜出）:
  remote skills（最高）> disk-global > project（最低）

System Prompt 中只出现:
  SKILLS
  Available skills:
    - "skill-name-1": description
    - "skill-name-2": description

  实际指令在 LLM 调用 use_skill 工具后才加载到 messages
```

**目的**：System Prompt 仅放元数据用于选择，详细指令延迟加载，节省 token。

---

## FocusChain Interval 门控与 tool 参数校验（★ 关键变更）

### Interval 门控机制

默认不再每轮强制要求 `task_progress`，而是在**到达 remindClineInterval（默认 6 轮）时**才进行强制校验：

```
reachedReminderInterval = apiRequestsSinceLastTodoUpdate >= 6
skipTaskProgress = !reachedReminderInterval
skipSkillWorkflow = skipTaskProgress  // 同一个布尔值控制两者
```

- `skipTaskProgress` 和 `skipSkillWorkflow` 使用**同一个布尔值**控制
- 当 `apiRequestsSinceLastTodoUpdate < 6` → 两者均跳过
- 当 `apiRequestsSinceLastTodoUpdate >= 6` → 两者均强制校验
- `apiRequestsSinceLastTodoUpdate` 在模型提交 `task_progress` 时重置为 0

### Todo 列表规则：结果标注要求

当前要求（来自 FocusChain prompts）：
```
- [ ] 每项在完成之后要在列表之后标注结果或发现
      示例: - [x] 创建组件 (用了 React.FC + TypeScript)
- [ ] todo 列表要参考 skill、rules 和 workflows 来写
- [ ] 使用 task_progress 参数时需包含完整 checklist
```

---

## Subagent 输出截断的移除与规则注入

### Subagent 输出截断已移除

Subagent 的 `excerpt()` 截断函数（原上限 1200 字符）**已不再被调用**（2026-06-17 起）。当前仅做 `.trim()` 空白清理，主 agent 能看到 subagent 的完整输出。

但 subagent 内部仍受保护：read_file / MCP 工具的 400KB 全局限制、read_file 行数限制 1000 行、list_files 200 文件限制仍然有效。

### Subagent 用户规则自动注入

Subagent 的 system prompt 同样通过 PromptRegistry 构建，componentOrder 中包含 USER_INSTRUCTIONS_SECTION，因此用户规则（`.clinerules/`, `.cursorrules`, `.agents/AGENT.md`, `.clineignore` 等）**自动注入到 subagent 的 system prompt** 中。无 `isSubagentRun` 过滤来排除规则，subagent 的 system prompt 结构与主 agent 几乎一致（仅通过 `SUBAGENT_SYSTEM_SUFFIX` 区分角色）。

---

## 提示词上下文的结构样式（完整示意图）

### 每轮 API 调用的完整结构

```
┌─────────────────────────────────────────────────────────────┐
│  api.createMessage(systemPrompt, messages, tools?)           │
│                            │            │          │         │
│               System Prompt│  Messages  │ Tools(可选)        │
│               (每轮完整重  │  (截断+    │ (仅 native          │
│                建)         │   去重后)  │  tool calls)        │
└─────────────────────────────────────────────────────────────┘

┌─ System Prompt ────────────────────────────────────────────┐
│  AGENT_ROLE → TOOL_USE → TASK_PROGRESS? → MCP? →          │
│  EDITING_FILES → ACT_VS_PLAN → CAPABILITIES → SKILLS? →  │
│  FEEDBACK → RULES → SYSTEM_INFO → OBJECTIVE →             │
│  USER_INSTRUCTIONS（8类规则固定顺序拼接）                   │
└────────────────────────────────────────────────────────────┘

┌─ Messages（数组） ────────────────────────────────────────┐
│  [历史消息]（ContextManager 截断+去重后）                   │
│                                                            │
│  + 当前 userContent（★ 2026-06-17 重排）：                 │
│    ┌──────────────────────────────────────────────────┐    │
│    │ <task>或<user_message>                           │    │
│    │ + [文件/图片]                                    │    │
│    │ + [hook 注入]                                    │    │
│    │ + [@提及解析/命令处理]                            │    │
│    │ + <environment_details>（精简版）   ★第1位       │    │
│    │ + [FocusChain todo list]          [interval门控] │    │
│    │ + <explicit_instructions>          [可选]        │    │
│    │ + <workflow_execution_override>   [可选，最后]   │    │
│    │ + [summarize 指令]                 [可选]        │    │
│    └──────────────────────────────────────────────────┘    │
│                                                            │
│  + LLM 响应（详见下节 Assistant 消息结构详解）                │
│  + tool_result（工具执行结果）                               │
└────────────────────────────────────────────────────────────┘

┌─ Tools（数组，可选） ──────────────────────────────────┐
│  按 variant + contextRequirements 动态过滤的工具描述      │
│  （仅 enableNativeToolCalls=true 时存在）                │
└────────────────────────────────────────────────────────────┘
```

### <environment_details> 内部结构（精简后）

```
<environment_details>
# Current Mode
ACT MODE 或 PLAN MODE
{planModeInstructions 文本}（仅 PLAN 模式下）
</environment_details>

注意：以下字段已注释屏蔽（保留旧代码但不再生效）：
  - Visible Files / Open Tabs / Terminals
  - Recently Modified Files / Current Time
  - CWD Files / Workspace Config
  - Detected CLI Tools / Context Window Usage
```

### 几处关键设计特点

| 特性 | 说明 |
|------|------|
| System Prompt 每轮重建 | 保证规则/技能/环境的实时性，不缓存 |
| USER_INSTRUCTIONS 是唯一规则注入点 | 8 类规则按固定顺序拼接，不会散落在别处 |
| Workflow 不在 System Prompt 中 | 通过 user message 的 `<explicit_instructions>` 注入 |
| Skills 仅元数据进入 System Prompt | 详细指令在调用 use_skill 后加载到 messages |
| environment_details 精简为仅 Current Mode | 其余字段转移或废弃，与 SYSTEM_INFO_SECTION 互补 |
| ContextManager 只处理 messages | 不影响 system prompt |
| Handler 截断 vs ContextManager 截断 | 前者按工具特性定制，后者做统一去重+压缩 |
| Auto-condense 是 next-gen 默认 | 旧模型走旧版消息删除，新模型走 LLM 自摘要 |
| FocusChain 默认 6 轮才强制校验 | Interval 门控减少每轮 token 开销 |

---

## Assistant 消息结构详解

### 概述

Assistant 消息在完整 API 请求结构中位于 Messages 数组的末尾部分，包含 LLM 流式输出组装后的完整响应。其结构由四种 content 块组成，但**磁盘保存的内容与下一轮 API 发送的内容并不一致**——这是 Thinking/Reasoning 内容保存与发送不对称的核心问题。

### 消息组成

每轮结束后，流式响应被组装为 `assistantContent`，包含四种类型的块：

```
assistantContent = [
    ...redactedThinkingContent,       // ① redacted thinking 块（部分）
    { ...thinkingBlock },             // ② 完整 thinking 块（思考原文）
    {                                 // ③ 文本块
        type: "text",
        text: assistantTextOnly,
        reasoning_details: thinkingBlock?.summary,
        signature: assistantTextSignature,
    },
    ...toolUseBlocks,                 // ④ 工具调用块
];
```

#### 各块说明

- **① redactedThinkingContent**：提取自 thinking 块中的 `redactedThinking` 字段，放置于首部
- **② thinkingBlock**：完整的 thinking 原文，包含 `thinking` 字段（模型推理过程）、`signature`（签名，用于验证 thinking 完整性）、`summary`（推理内容摘要，DeepSeek 为空数组）
- **③ text 块**：模型最终输出的文本回复。其中的 `reasoning_details` 从 thinkingBlock 的 summary 复制而来，`signature` 用于后续验证
- **④ toolUseBlocks**：模型调用的工具块集合

### 保存 vs 发送的不对称

#### 磁盘保存（addToApiConversationHistory）

```
→ addToApiConversationHistory({ role: "assistant", content: assistantContent })
→ 磁盘 api_conversation_history.json 保存完整 thinking
```

磁盘 JSON 结构示例：
```json
{
  "role": "assistant",
  "content": [
    {"type": "thinking", "thinking": "完整思考过程...", "signature": "", "summary": []},
    {"type": "text", "text": "最终回复...", "reasoning_details": []}
  ]
}
```

完整 thinking 原文被持久化到磁盘，用于 resume 时恢复上下文。

#### API 发送（convertToOpenAiMessages）

下一轮 API 请求时，`convertToOpenAiMessages()` 的 reduce 逻辑将 assistant 消息按 content 类型分流：

```
reduce 逻辑：
  - tool_use 类型 → 放入 toolMessages（保留）
  - text / image 类型 → 放入 nonToolMessages（保留）
  - thinking 类型 → 不满足任何条件 → 被丢弃（过滤掉）
```

**thinking 类型被丢弃**——convertToOpenAiMessages 只处理 tool_use、text 和 image 三种类型，thinking 不在此列。

#### reasoning_details 的传递

文本块中的 `reasoning_details`（summary）通过 `@ts-expect-error` 附加到 OpenAI 消息：

```
openAiMessages.push({
    role: "assistant",
    content: finalContent,  // 只有 text，没有 thinking
    // @ts-expect-error
    reasoning_details: consolidatedReasoningDetails,
});
```

但 `reasoning_details` 是 OpenRouter 协议扩展（`REASONING_DETAILS_PROVIDERS = ["cline", "openrouter"]`），**DeepSeek API 不识别此字段**，实际发送时被忽略。

### Provider 差异对比

| Provider | thinking 保存到历史 | thinking 发送给 API | reasoning_details 发送 |
|---|---|---|---|
| **CygCode (DeepSeek)** | ✅ 保存 | ❌ 过滤掉 | ❌ 非标准字段被忽略 |
| **OpenRouter** | ✅ 保存 | ❌ 过滤掉 | ✅ OpenRouter 解析 |
| **Anthropic** | ✅ 保存 | ✅ 有 signature 时保留 | N/A |

### 影响

1. **Token 浪费**：完整 thinking 被持久化但不用，长思考模型（如 DeepSeek R1）可能数千 token
2. **截断计数不准**：ContextManager 基于消息数量截断，但包含 thinking 的消息被计数却不被发送
3. **上下文不一致**：resume 时加载完整 thinking 历史，但 API 请求时又被过滤

---

## 总结

```
每轮开始
   ↓
读取最新 Rules / Skills / 环境状态
   ↓
完整重建 System Prompt
   ↓
分层构建 User Message（基础内容 → 解析 → 环境(精简) → 补偿 → workflow → summarize）
   ↓
追加到对话历史
   ↓
ContextManager 决策：去重？截断？压缩？
   ↓
发送 API 请求
   ↓
处理响应 → 更新状态 → 下一轮
```

每一步都基于上一轮的真实状态（token 消耗、工具调用结果），不需要用户干预即可自动维持最优的 context window 利用率。

---

*最后更新：2026-06-17 · 新增 Assistant 消息结构详解（含 thinking 保存 vs 发送不对称分析）*
