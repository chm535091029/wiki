# CygCode Harness 工程详解 — 如何让 LLM 在多轮对话中不偏离规则和计划

> **本报告范围**：`CygCode (Cline Fork)` 项目中负责"让 AI Agent 始终按照用户与系统的约束执行任务"的全部工程化机制，统称 **Harness（驾驭/脚手架）**。它包含提示词工程、上下文治理、状态持久化、协议约束、扩展点等 10+ 个子系统。
>
> **配套文档**（建议同时阅读）：
> - `CygCodeFunctionIntroduction/FocusChain与TaskProgress提示词机制详解.md` — FocusChain 细节
> - `CygCodeFunctionIntroduction/Rules_Workflows_Skills加载机制详解.md` — 规则/工作流/技能加载细节
> - `CygCodeFunctionIntroduction/cygcode上下文管理` — 上下文治理与每轮消息拼装
>
> 本文聚焦在"**如何不偏离**"这一主题上，对上述三份文档进行**整合性、体系化**的视角重写，并补充它们之间如何协同工作的**全景图**。

---

## 目录

1. [核心问题：LLM 为什么会在多轮对话中"跑偏"](#1-核心问题llm-为什么会在多轮对话中跑偏)
2. [Harness 的"四道防线"模型](#2-harness-的四道防线模型)
3. [整体架构总览](#3-整体架构总览)
4. [第一道防线：System Prompt — 静态契约层](#4-第一道防线system-prompt--静态契约层)
5. [第二道防线：User Message — 动态状态注入层](#5-第二道防线user-message--动态状态注入层)
6. [第三道防线：Tool 协议 — 行动约束层](#6-第三道防线tool-协议--行动约束层)
7. [第四道防线：FocusChain — 计划与进度锚定层](#7-第四道防线focuschain--计划与进度锚定层)
8. [辅助防线 1：ContextManager 上下文治理](#8-辅助防线-1contextmanager-上下文治理)
9. [辅助防线 2：PLAN MODE / ACT MODE 双模式约束](#9-辅助防线-2plan-mode--act-mode-双模式约束)
10. [辅助防线 3：Hooks 扩展点（外部干预通道）](#10-辅助防线-3hooks-扩展点外部干预通道)
11. [辅助防线 4：Rules / Skills / Workflows 三层配置](#11-辅助防线-4rules--skills--workflows-三层配置)
12. [多轮不偏离的反馈闭环（核心结论）](#12-多轮不偏离的反馈闭环核心结论)
13. [关键源码索引](#13-关键源码索引)
14. [附录 A：Harness 关键简图汇总](#14-附录-aharness-关键简图汇总)
15. [附录 B：对照实验思考 — 如果去掉某道防线会怎样](#15-附录-b对照实验思考--如果去掉某道防线会怎样)

---

## 1. 核心问题：LLM 为什么会在多轮对话中"跑偏"

要理解 Harness 的设计动机，必须先理解 LLM 在多轮 Agent 场景中的**结构性弱点**：

```
┌────────────────────────────────────────────────────────────────────────┐
│  LLM 的 4 个固有弱点（在多轮 Agent 场景会被放大）                       │
├────────────────────────────────────────────────────────────────────────┤
│  ① 上下文衰减：随着对话增长，早期指令的"权重"相对降低，模型倾向         │
│     关注最近的内容（recency bias）                                       │
│  ② 指令漂移：模型在长任务中倾向于"自己找合理路径"，覆盖或忘掉           │
│     用户的特殊约束                                                       │
│  ③ 状态丢失：模型是"无状态"的，每轮只能看到 messages；                 │
│     没有"我刚才做到第几步了"的内部记忆                                   │
│  ④ 目标偏移：完成若干子目标后，模型容易"宣告完成"而非"继续检查"        │
└────────────────────────────────────────────────────────────────────────┘
```

**Harness 的使命**：用工程手段，**外化**这 4 个原本依赖模型自身能力的约束，变成由系统侧强制注入、强制校验、强制纠正的**可观测、可调整**机制。

---

## 2. Harness 的"四道防线"模型

将 CygCode 全部机制抽象为 4 道防线 + 4 个辅助防线：

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Harness 防御层次模型                              │
│                                                                          │
│  用户原始任务 ──▶  LLM  ◀── Harness 在每一层都强制约束                    │
│                     │                                                     │
│  ┌──────────────────┴──────────────────┐                                  │
│  │  ① System Prompt（静态契约）        │  ← 每次请求都重建的"宪法"     │
│  │     - 角色/能力/工具/规则/原则        │                                  │
│  │     - 不允许的 8 类用户规则在这里注入  │                                  │
│  └──────────────────┬──────────────────┘                                  │
│                     ▼                                                     │
│  ┌─────────────────────────────────────┐                                  │
│  │  ② User Message（动态状态）         │  ← 每次请求都重新计算的状态     │
│  │     - 当前任务、附件                 │                                  │
│  │     - <environment_details>          │                                  │
│  │     - Workflow / Condense 指令       │                                  │
│  └──────────────────┬──────────────────┘                                  │
│                     ▼                                                     │
│  ┌─────────────────────────────────────┐                                  │
│  │  ③ Tool 协议（行动约束）            │  ← XML 标签或原生 tool_calls   │
│  │     - 参数 schema 严格定义            │                                  │
│  │     - 工具执行前的用户审批/沙箱        │                                  │
│  │     - Tool result 自动回流给模型      │                                  │
│  └──────────────────┬──────────────────┘                                  │
│                     ▼                                                     │
│  ┌─────────────────────────────────────┐                                  │
│  │  ④ FocusChain（计划与进度）         │  ← 跨轮次的"任务状态机"        │
│  │     - 任务清单 + 完成度              │                                  │
│  │     - 每轮 re-inject 提醒更新         │                                  │
│  │     - 文件持久化 + 文件监听          │                                  │
│  └─────────────────────────────────────┘                                  │
│                                                                          │
│  辅助防线：                                                              │
│   • ContextManager：上下文长度治理（截断 + 去重 + 摘要）                  │
│   • PLAN/ACT MODE：双模式分离"想"与"做"                                  │
│   • Hooks：项目级外部干预通道                                            │
│   • Rules/Skills/Workflows：用户可配置的三层指令源                        │
└──────────────────────────────────────────────────────────────────────────┘
```

**核心思想**：每轮 LLM 调用时，Harness 都会**主动重建**这 4 道防线的内容，再发送出去。模型"看到"的上下文不是历史消息的简单拼合，而是**被 Harness 重新格式化、重新加权、重新过滤**的"受控上下文"。

---

## 3. 整体架构总览

### 3.1 单轮 API 调用的完整时序

```
  ┌───────────────────────────────────────────────────────────────┐
  │                 Task.recursivelyMakeClineRequests              │
  │  （每轮一次的主循环，由 initiateTaskLoop 驱动）                  │
  └──────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  Stage 1: shouldCompact 判断（auto-condense 决策）             │
  │   - 读取上一轮 token 报告                                       │
  │   - 决定是否需要触发 summarize_task                              │
  └──────────────────────┬────────────────────────────────────────┘
                         ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  Stage 2: loadContext（用户上下文构建）                          │
  │   - 解析 mentions（@file: → <file_content>）                   │
  │   - 解析 slash commands（/cmd → 内置/Workflow/MCP）            │
  │   - 并行：解析 content + 获取 environmentDetails               │
  │   - ★ 注入 FocusChain 指令（条件性）                            │
  └──────────────────────┬────────────────────────────────────────┘
                         ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  Stage 3: 追加尾部动态块                                         │
  │   ① <environment_details>...</environment_details>             │
  │   ② [workflow instructions] + <workflow_execution_override>   │
  │   ③ [summarize instructions]                                   │
  └──────────────────────┬────────────────────────────────────────┘
                         ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  Stage 4: attemptApiRequest（核心：构建完整 prompt）            │
  │   [A] 刷新所有 toggle：Rules / External / Workflows             │
  │   [B] 加载 7 类规则内容 + clineignore                           │
  │   [C] 加载 Skills（3 层优先级合并）                             │
  │   [D] 构建 promptContext                                       │
  │   [E] ★ getSystemPrompt(promptContext) 完整重建 system prompt  │
  │   [F] ContextManager.getNewContextMessagesAndMetadata()        │
  │       - file read 去重                                          │
  │       - 截断（none/lastTwo/half/quarter）                       │
  │       - tool_use/result 配对修复                                │
  │   [G] api.createMessage(systemPrompt, history, tools?)        │
  └──────────────────────┬────────────────────────────────────────┘
                         ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  Stage 5: 处理 LLM 响应                                          │
  │   - 流式 chunk 解析 → 文本 / tool_use                           │
  │   - tool_result 包装 → addToApiConversationHistory              │
  │   - FocusChainManager.updateFCListFromToolResponse(taskProgress)│
  │   - 决定下一步：是继续调用工具还是 attempt_completion           │
  └──────────────────────┬────────────────────────────────────────┘
                         │
                         └───────▶ 回到 Stage 1（下一轮）
```

### 3.2 Harness 各子系统的归属

| 子系统 | 防线层 | 关键源码 |
|--------|--------|----------|
| System Prompt 组件注册 | 第 ① 层 | `apps/vscode/src/core/prompts/system-prompt/` |
| User Message 构建（mentions / slash / environment） | 第 ② 层 | `apps/vscode/src/core/task/index.ts` 中 `loadContext` |
| Tool 定义 + Native Tool 模式 | 第 ③ 层 | `apps/vscode/src/core/prompts/system-prompt/components/tool_use/` |
| FocusChain Manager + 文件机制 | 第 ④ 层 | `apps/vscode/src/core/task/focus-chain/` |
| ContextManager 截断 + 去重 | 辅助 1 | `apps/vscode/src/core/context/context-management/ContextManager.ts` |
| Plan/Ask 双模式 + plan_mode_respond | 辅助 2 | `apps/vscode/src/core/prompts/components/act_vs_plan_mode.ts` + `PLAN_MODE` tool |
| Hooks（TaskStart/UserPromptSubmit/TaskResume/TaskCancel/PreCompact） | 辅助 3 | `apps/vscode/src/core/hooks/` |
| Rules / Skills / Workflows 加载 | 辅助 4 | `apps/vscode/src/core/context/instructions/user-instructions/` |

---

## 4. 第一道防线：System Prompt — 静态契约层

### 4.1 定位

System Prompt 是 LLM 看到的"宪法"。在 CygCode 中，**每轮 API 调用前都完整重建一次**（不缓存整个 prompt，但 component 函数内部可以缓存），保证：
- Rules 文件改动立即生效
- CWD、当前时间等动态信息总是最新的
- 任何 toggle 关闭都立即反映

### 4.2 12 个 Section 顺序（generic variant 视角）

```
┌──────────────────────────────────────────────────────────────────┐
│  System Prompt = baseTemplate + 12 section 占位符                │
│  （componentOrder 决定实际顺序，不同 variant 不同）               │
│                                                                  │
│  ① AGENT_ROLE      你是 Cyg Code 高级软件工程师                   │
│  ② TOOL_USE        工具定义 + XML 调用格式（最占空间）            │
│  ③ TASK_PROGRESS   task_progress 参数使用规范                     │
│  ④ MCP             [条件] 已连接 MCP server 时出现                │
│  ⑤ EDITING_FILES   write_to_file / replace_in_file 用法          │
│  ⑥ ACT_VS_PLAN     ACT vs PLAN 模式区分                          │
│  ⑦ CAPABILITIES    工具能力清单                                  │
│  ⑧ RULES           CWD / 工具约束 / 通用行为规范                  │
│  ⑨ SYSTEM_INFO     OS / IDE / Shell / CWD                       │
│  ⑩ OBJECTIVE       7 条任务执行原则                              │
│  ⑪ USER_INSTRUCTIONS  ← ★ 用户规则注入的唯一位置                 │
│  ⑫ SKILLS          [条件] Skills 元数据列表                      │
└──────────────────────────────────────────────────────────────────┘
```

### 4.3 对"不偏离"最关键的两个 Section

#### a) `OBJECTIVE_SECTION`（"宪法原则"）

位于 `apps/vscode/src/core/prompts/system-prompt/components/objective.ts`，是一段**不依赖任何外部文件**的硬编码文本，定义了 7 条**不可协商**的行为准则：

```typescript
const getObjectiveTemplateText = (context) => `OBJECTIVE

You accomplish a given task iteratively, breaking it down into clear steps and working through them methodically.

1. Analyze the user's task and set clear, achievable goals to accomplish it. Prioritize these goals in a logical order.
2. Work through these goals sequentially, utilizing available tools one at a time as necessary...
3. Remember, you have extensive capabilities with access to a wide range of tools that can be used in powerful and clever ways as necessary to accomplish each goal. Before calling a tool, do some analysis within <thinking></thinking> tags... BUT, if one of the values for a required parameter is missing, DO NOT invoke the tool (not even with fillers for the missing params) ${context.yoloModeToggled !== true ? "and instead, ask the user to provide the missing parameters using the ask_followup_question tool" : ""}.
4. Before using attempt_completion, verify the task requirements with available tools. Confirm required output files exist, required content/format constraints are satisfied, and no forbidden extra artifacts were introduced. If checks fail, continue working until the result is verifiably correct.
5. Once you've completed the user's task and verified the result, you must use the attempt_completion tool...
6. The user may provide feedback, which you can use to make improvements and try again. But DO NOT continue in pointless back and forth conversations, i.e. don't end your responses with questions or offers for further assistance.
7. **File path format**: When referencing file paths with line numbers...`
```

**关键设计**：
- 第 3 条强制模型在调工具前用 `<thinking>` 标签**显式推理**（提升 reasoning 质量，避免冲动调用）
- 第 3 条末尾 `yoloModeToggled` 条件渲染：YOLO 模式下**禁止**问问题，必须用工具推断
- 第 4 条强制**验证后再 attempt_completion**（防止"未完成就声称完成"的目标偏移）
- 第 6 条禁止"end with a question"（防止无意义的来回对话）

#### b) `RULES_SECTION`（"硬性行为规范"）

位于 `apps/vscode/src/core/prompts/system-prompt/components/rules.ts`，是**最重要**的"不偏离规则"区。包含：

- **CWD 约束**："你不能 cd 到其他目录"——强制模型用绝对路径
- **路径格式**："不要用 ~ 或 $HOME"——避免跨平台解析差异
- **搜索/编辑工具规范**：search_files 配合 read_file 的工作流
- **提问 vs 推断**：YOLO 模式与普通模式的条件分支
- **浏览器工具使用规则**：条件渲染（仅当 supportsBrowserUse）
- **CLI 验证规则**：条件渲染（仅当 isCliEnvironment）
- **核心禁令**：
  - "NEVER end attempt_completion result with a question"
  - "STRICTLY FORBIDDEN from starting your messages with 'Great', 'Certainly', 'Okay', 'Sure'"
  - "You do not need to display the changes before using the tool"（减少冗余输出）
  - "It is critical you wait for the user's response after each tool use"（强制串行）
- **replace_in_file 的 XML 格式硬性要求**（必填 SEARCH/REPLACE marker）

> **设计哲学**：把"模型容易犯的错"全部**显式**列在 system prompt 中，而非依赖"模型应该知道"。这是 harness 工程最朴素也最有效的做法。

### 4.4 User Instructions — 用户规则的"唯一注入点"

`USER_INSTRUCTIONS_SECTION`（`apps/vscode/src/core/prompts/system-prompt/components/user_instructions.ts`）的模板：

```
USER'S CUSTOM INSTRUCTIONS

IMPORTANT: The following instructions OVERRIDE any default behavior. You MUST follow them exactly as written.

{{CUSTOM_INSTRUCTIONS}}
```

按固定顺序拼接 8 类内容（详见 §11.1）：

```
preferredLanguage → globalClineRules → localClineRules
     → localCursorRules → localCursorRulesDir
     → localWindsurfRules → localAgentsRules → clineIgnore
```

**关键设计**：
- 顶部用大写 `IMPORTANT` + `MUST` 强调：**OVERRIDE 任何默认行为**
- 顺序固定（不可配置）—— 避免用户规则相互冲突时的歧义
- 每条规则**文件路径作为标题**（如 `# .clinerules/general.md`）—— 让 LLM 知道这条规则来自哪里，便于 debug

### 4.5 条件渲染与 Variant 系统

CygCode 不是一个"放之四海而皆准"的 system prompt，而是**按模型/Provider 动态选 variant**：

```
ProviderInfo + ModelId ──▶ PromptRegistry ──▶ 匹配第一个满足的 Variant
                                                      │
                       ┌──────────────────────────────┼──────────────────┐
                       ▼                              ▼                  ▼
                   generic                        next-gen               xs
              (fallback, 全工具)             (Claude 4+, GPT-5 等)    (极小模型)
                       │                              │                  │
                       ▼                              ▼                  ▼
              componentOrder 不同              TASK_PROGRESS 简化为     工具集裁剪
              FEEDBACK 才有提示               MUST 创建, 严格措辞       提示词最简
```

**对不偏离的贡献**：variant 让"针对不同模型能力定制"成为可能——例如 GPT-5 模型使用更严格的 `UPDATING_TASK_PROGRESS_NATIVE_GPT5` 措辞：

> *"You MUST create a comprehensive checklist... If a checklist is being used, be sure to update it any time a step has been completed..."*

---

## 5. 第二道防线：User Message — 动态状态注入层

### 5.1 定位

如果说 System Prompt 是"宪法"，User Message 的尾部注入就是**每轮的"现状快报"**。它把 LLM 之前看不到的"上下文状态"重新拼接到 user 侧。

### 5.2 User Message 的最终组装顺序（★ 已重排）

```
recursivelyMakeClineRequests 中 userContent 的最终 push 顺序（source: task/index.ts:3112-3128）：
```

**组装顺序（自上而下依次 push）**：

```
① <task>...</task>             或 <user_message>...</user_message>     ← 基础内容
② [file_content / image / hook_context] ...                            ← 附件/Hook 注入
③ <environment_details>...</environment_details>                       ← ★ 第 1 位：提供上下文
④ [Focus Chain todo list]                                             ← [条件] 计划进度
⑤ <explicit_instructions type="<workflow>" priority="override">        ← ★ 第 2 位：紧跟环境信息
⑥ <workflow_execution_override>                                       ← ★ 第 3 位：模型回复前最后一条指令
   CRITICAL: You are currently executing the workflow "xxx"...
   </workflow_execution_override>
⑦ <explicit_instructions type="summarize_task">                       ← [条件] auto-condense 触发
```

**关键变更**（2026-06-17 优化）：
- `environment_details` 被提升到**第 1 位**（紧跟基础内容），确保 LLM 在阅读任何指令前先看到当前模式
- `<explicit_instructions>` 作为**独立字段**（不再是 processedText 的内嵌内容），由 `parseSlashCommands` 返回 `workflowInstructions` 独立返回值，调用方 `loadContext` → `recursivelyMakeClineRequests` 决定插入位置
- `<workflow_execution_override>` 作为**最后一条指令**（第 3 位），在模型回复前形成"最后提醒"
- 所有 XML 标签使用 `priority="override"` 属性**显式标记覆盖权限**：

```
IMPORTANT: The following instructions OVERRIDE any default behavior. You MUST follow them exactly as written.
```

### 5.3 `<environment_details>` —— "精简模式"（仅保留 Current Mode）

**当前环境**（2026-06-17 精简优化）：`environment_details` 块仅保留两个有效字段，其余字段均已被**注释屏蔽**（source: task/index.ts:4261-4490）：

```
<environment_details>
{可选: # Workspace Roots（仅 multi-root 且 >1 个根时显示）}
# Current Mode
ACT MODE   或
PLAN MODE
{planModeInstructions 文本}              ← PLAN 模式下追加
</environment_details>
```

**已注释屏蔽的字段（保留旧代码但不再生效）**：
- `# {platform} Visible Files`
- `# {platform} Open Tabs`
- `# Actively Running Terminals` / `# Inactive Terminals`
- `# Recently Modified Files`
- `# Current Time`
- `# Current Working Directory ({cwd}) Files`
- `# Workspace Configuration`
- `# Detected CLI Tools`
- `# Context Window Usage`

> **区分**：System Prompt 中包含 `SYSTEM INFORMATION` 段（`system_info.ts`），提供 OS、IDE、Shell、Home Directory、CWD 等**静态环境信息**。这与 `<environment_details>` 的**动态模式指示**角色互补。

**对不偏离的贡献**（精简后）：
- `# Current Mode` 让 LLM 知道自己在 ACT 还是 PLAN 模式，决定可用工具集
- PLAN 模式下的 `planModeInstructions()` 明确提示"不能自行切换到 ACT 模式"
- 精简后减少了 token 占用，让 LLM 的注意力更集中在**模式切换指令**上
- 首轮的文件清单功能仍通过 System Prompt 的 `SYSTEM_INFO_SECTION` 提供

### 5.4 关键条件判断：Context Window Usage 显示

```typescript
// apps/vscode/src/core/task/index.ts:3866-3882
if (
    isNextGenModelFamily(this.api.getModel().id) ||
    (this.api.getModel().info.apiFormat !== ApiFormat.OPENAI_RESPONSES && (this.taskState.apiRequestCount > 100 || ...))
) {
    // 显示条件
    if (lastApiReqTotalTokens / contextWindow >= 0.6) {
        // 显示 "X / Y tokens used (Z%)"
    }
}
```

**Next-gen 模型（Claude 4+ / GPT-5）**仅在 `used/total >= 60%` 时才显示。阈值 = `autoCondenseThreshold(75%) - 15%` 的余量，给 LLM 留出"还有空间但要开始节约"的提示信号。

### 5.5 parseMentions 与 parseSlashCommands

#### a) `parseMentions`（`@file:` 提及解析）

```typescript
// 仅当 text block 包含 USER_CONTENT_TAGS（<task> / <feedback> / <answer> / <user_message>）时处理
// 把 "@src/foo.ts" 替换为 <file_content path="src/foo.ts">...内容...</file_content>
```

**对不偏离的贡献**：用户**主动**把文件"喂"给 LLM，比让 LLM 自己去 find_file 更准确。

#### b) `parseSlashCommands`（`/command` 处理）

按优先级匹配：

```
用户输入 /xxx 参数
   ↓
① 内置命令：/newtask /smol /compact /newrule /reportbug /deep-planning /explain-changes
   → 直接替换为预定义指令文本
② MCP prompt：/mcp:server:prompt
   → 异步从 mcpHub.fetchPrompt 获取
③ Workflow：/.clinerules/workflows/<name>.md 或 ~/Documents/Cline/Workflows/<name>.md
   → fs.readFile 读内容
   → 包装为 <explicit_instructions type="<name>" priority="override">
```

**关键设计**：
- Workflow **不**进 System Prompt，而是按需注入到 user message
- 用 `priority="override"` XML 属性**显式标记**为"高优先级"
- 末尾追加 `<workflow_execution_override>` 提示：

```
<workflow_execution_override>
CRITICAL: You are currently executing the workflow "my-workflow.md". 
The instructions above override default behavior. Follow the workflow steps precisely.
</workflow_execution_override>
```

这相当于在 system prompt 之外再"贴一张大字报"提醒 LLM。

### 5.6 Hook 注入的 contextModification

每个 hook 可返回 `contextModification` 字符串，Harness 用 `<hook_context source="...">` 标签包裹后追加到 userContent：

```xml
<hook_context source="UserPromptSubmit">
{project hook 注入的 context}
</hook_context>
```

这给**项目级扩展**提供了"在 user 消息中塞入额外指令"的官方通道。

---

## 6. 第三道防线：Tool 协议 — 行动约束层

### 6.1 定位

即使 LLM 接受了 system prompt 的所有约束，**真正能保证"不偏离"的是 Tool 协议**——因为：

```
┌────────────────────────────────────────────────────────────┐
│  System Prompt 是"软约束"：模型可以违反                    │
│  Tool 协议是"硬约束"：模型必须按 schema 写才能调通          │
└────────────────────────────────────────────────────────────┘
```

### 6.2 两种 Tool 协议

CygCode 支持**两种互斥**的协议，根据 Provider 能力自动选择：

```
┌────────────────────────────────────────────────────────────────┐
│  模式 1: XML 标签协议（默认）                                   │
│  ─────────────────────────                                     │
│  LLM 输出:                                                     │
│    <write_to_file>                                             │
│      <path>foo.ts</path>                                       │
│      <content>...</content>                                   │
│    </write_to_file>                                            │
│  Harness 解析: StreamResponseHandler → parseAssistantMessageV2 │
│  工具集: 17 个内置 ClineDefaultTool                            │
├────────────────────────────────────────────────────────────────┤
│  模式 2: 原生 Tool Calls（仅 enableNativeToolCalls=true）      │
│  ─────────────────────────────────────────                    │
│  LLM 输出:                                                     │
│    tool_calls: [{                                              │
│      id: "xxx", name: "write_to_file",                        │
│      input: { path: "foo.ts", content: "..." }                │
│    }]                                                          │
│  Harness 解析: provider 自己的 tool_calls 字段                │
│  触发条件:                                                     │
│    - model.info.apiFormat === ApiFormat.OPENAI_RESPONSES       │
│    - 或 stateManager.getGlobalStateKey("nativeToolCallEnabled")│
└────────────────────────────────────────────────────────────────┘
```

### 6.3 关键 Tool 对"不偏离"的强化

#### a) `attempt_completion` — "显式结束信号"

```typescript
// 关键约束：
1. 调用前必须验证任务要求（来自 OBJECTIVE_SECTION 第 4 条）
2. 参数 `result` 不能以问号或"需要更多帮助"结尾（来自 RULES_SECTION）
3. 不允许 STRICTLY FORBIDDEN 开头语（来自 RULES_SECTION）
```

模型想"宣告完成"必须调用 `attempt_completion` 工具，Harness 才能识别任务结束。这避免了"模型自己说完成但实际未完成"的跑偏。

#### b) `ask_followup_question` — "暂停信号"

模型发现自己缺少关键参数时，**唯一合法**的提问方式就是调这个工具。这避免模型"自己瞎猜"参数然后做错事。

#### c) `plan_mode_respond` — "PLAN 模式下的'想'工具"

PLAN 模式下，模型不能用任何执行工具（除只读工具），只能调 `plan_mode_respond` 输出"想法"。这强制模型**先把计划讲清楚**再切到 ACT 模式执行。

#### d) `replace_in_file` 的硬性 XML 格式

```typescript
// 来自 rules.ts 的硬性要求：
- 必填完整行，不能 partial line
- 多 block 时按文件中出现顺序
- 不能改 marker 格式（> 是 INVALID）
- 不能忘 +++++++ REPLACE 结束标记
```

**为什么这么严格？** 因为如果 LLM 输出的 SEARCH 块有 0.1% 的格式偏差，Harness 就找不到匹配，**整次编辑失败**。把规则写死是工程妥协。

#### e) `task_progress` 参数 — 进度追踪的"钩子"

虽然 `task_progress` 不算 tool，但它是**所有 tool 调用**的"可选参数"。Harness 在 `updateFCListFromToolResponse()` 中专门处理：

```typescript
// apps/vscode/src/core/task/focus-chain/index.ts:273
public async updateFCListFromToolResponse(taskProgress: string | undefined) {
    if (taskProgress && taskProgress.trim()) {
        // 1. 写文件
        await this.writeFocusChainToDisk(taskProgress.trim())
        // 2. 重置计数器
        this.taskState.apiRequestsSinceLastTodoUpdate = 0
        // 3. 通知 UI
        await this.say("task_progress", taskProgress.trim())
        // 4. 上报 telemetry
        ...
    }
}
```

这相当于在"模型调工具"的"必经之路"上**强制检查 todo list 更新**。

### 6.4 工具结果回流 + Tool Pair 修复

调用工具后，结果通过 `addToApiConversationHistory({ role: "user", content: [{ type: "tool_result", tool_use_id, content }] })` 写回历史。ContextManager 还会做 `ensureToolResultsFollowToolUse` 修复：

```typescript
// 重新排序 tool_result blocks（必须紧跟对应 tool_use）
// 补齐缺失的 tool_result（内容 = "result missing"）
```

**对不偏离的贡献**：保证 LLM 看到的是**合法 Anthropic 格式**，否则模型可能"看到 tool_use 但没看到 tool_result"导致逻辑错乱。

---

## 7. 第四道防线：FocusChain — 计划与进度锚定层

### 7.1 定位

FocusChain 是 Harness 体系中**最具特色**的子系统——它把"任务进度"从模型的"短期记忆"外化为**持久化、跨轮次、用户可编辑**的状态机。

> **本节是已有文档 `FocusChain与TaskProgress提示词机制详解.md` 的精华整合，补充其在 Harness 体系中的角色定位。**

### 7.2 状态机

```
                    ┌─────────────────────────────────┐
                    │  FocusChainManager               │
                    │  持有 taskState.currentFocus     │
                    │  ChainChecklist                  │
                    └────────────┬────────────────────┘
                                 │
       ┌─────────────────────────┼─────────────────────────┐
       ▼                         ▼                         ▼
   没清单                    有清单                    用户改了清单
   (切到 ACT)                                      (todoListWasUpdatedByUser)
       │                         │                         │
       ▼                         ▼                         ▼
  inject initial          inject update               inject update
       │                         │                         │
       └─────────────────────────┼─────────────────────────┘
                                 ▼
                    ┌────────────────────────┐
                    │  LLM 调用工具时附带    │
                    │  task_progress 参数    │
                    └────────────┬───────────┘
                                 ▼
                    ┌────────────────────────┐
                    │  updateFCListFrom      │
                    │  ToolResponse()         │
                    │  → 写文件 + say UI     │
                    └────────────┬───────────┘
                                 ▼
                    ┌────────────────────────┐
                    │  chokidar 监听文件变化  │
                    │  → 通知 UI 更新        │
                    └────────────────────────┘
```

### 7.3 三种"应不应该注入"的状态判断

`shouldIncludeFocusChainInstructions()` 决策（`focus-chain/index.ts:337`）：

```typescript
public shouldIncludeFocusChainInstructions(): boolean {
    const inPlanMode = this.mode === "plan"
    const justSwitchedFromPlanMode = this.taskState.didRespondToPlanAskBySwitchingMode
    const userUpdatedList = this.taskState.todoListWasUpdatedByUser
    const reachedReminderInterval = 
        this.taskState.apiRequestsSinceLastTodoUpdate >= this.focusChainSettings.remindClineInterval
    const isFirstApiRequest = this.taskState.apiRequestCount === 1 && !this.currentFocusChainChecklist
    const hasNoTodoListAfterMultipleRequests = 
        !this.currentFocusChainChecklist && this.taskState.apiRequestCount >= 2

    return reachedReminderInterval || 
           justSwitchedFromPlanMode || 
           userUpdatedList || 
           inPlanMode || 
           isFirstApiRequest || 
           hasNoTodoListAfterMultipleRequests
}
```

**汇总决策表**：

| 场景 | 是否注入 | 注入内容 |
|------|---------|---------|
| PLAN MODE 下每轮 | ✅ | `planModeReminder`（弱提示） |
| 切到 ACT MODE | ✅ | `initial`（强要求创建） |
| 用户编辑了清单 | ✅ | `update` + 提示"用户改过" |
| 已达 remindClineInterval（默认 6）轮未更新 | ✅ | `reminder` |
| 第 1 轮且无清单 | ✅ | `recommended` |
| 已完成 100% | ✅ | `completed`（祝贺 + 提示用 attempt_completion） |
| 已经有清单，且 N 轮内 | ❌ | 节省上下文 |
| 已 N 轮（> 1）还没清单 | ✅ | `apiRequestCount`（强烈催促） |

### 7.4 7 种 prompt 模板

定义在 `apps/vscode/src/core/task/focus-chain/prompts.ts`：

```
┌──────────────────────────────────────────────────────────────────┐
│  FocusChainPrompts = {                                            │
│    initial,           // 切到 ACT 后强要求创建                    │
│    reminder,          // 已有清单，更新提示                       │
│    recommended,       // 早期任务，建议创建                       │
│    planModeReminder,  // PLAN 模式，弱提示                         │
│    completed,         // 全部完成，祝贺                            │
│    apiRequestCount,   // 多轮没清单，强烈催促                      │
│    listInstructionsRecommended,  // 推荐清单内容                  │
│  }                                                                │
└──────────────────────────────────────────────────────────────────┘
```

**示例 — `initial` prompt**：

```markdown
# task_progress CREATION REQUIRED - ACT MODE ACTIVATED

**You've just switched from PLAN MODE to ACT MODE!**

** IMMEDIATE ACTION REQUIRED:**
1. Create a comprehensive todo list in your NEXT tool call
2. Use the task_progress parameter to provide the list
3. Format each item using markdown checklist syntax:
	- [ ] For tasks to be done
	- [x] For any tasks already completed

**Your todo/task_progress list should include:**
   - All major implementation steps
   - Testing and validation tasks
   - Documentation updates if needed
   - Final verification steps

**Example format:**
   - [ ] Set up project structure
   - [ ] Implement core functionality
   - [ ] Add error handling
   - [ ] Write tests
   - [ ] Test implementation
   - [ ] Document changes
```

### 7.5 文件持久化 + chokidar 监听

```
~/.vscode-server/data/User/globalStorage/cygcoder.cyg-code/tasks/{taskId}/focus_chain_{taskId}.md
```

内容格式：

```markdown
# Focus Chain

- [x] Set up project structure
- [x] Install dependencies
- [ ] Create components
- [ ] Test application
```

**chokidar 监听**（`focus-chain/index.ts:69-92`）：

```typescript
this.focusChainFileWatcher = chokidar.watch(focusChainFilePath, {
    persistent: true,
    ignoreInitial: true,
    awaitWriteFinish: { stabilityThreshold: 300, pollInterval: 100 },
})
.on("add", () => this.updateFCListFromMarkdownFileAndNotifyUI())
.on("change", () => this.updateFCListFromMarkdownFileAndNotifyUI())
.on("unlink", () => { this.taskState.currentFocusChainChecklist = null; ... })
```

**对不偏离的独特贡献**：
1. **持久化**：即使任务被中断，重启后 LLM 仍能看到上次的进度（关键！）
2. **外部可编辑**：用户可以直接在文件里勾掉某项，Harness 通过 `todoListWasUpdatedByUser` 标志感知，下次注入时会附 `"用户已修改过该清单"` 提示
3. **双向同步**：UI 列表、磁盘文件、LLM 上下文三者实时一致
4. **去抖**：300ms `awaitWriteFinish` 避免编辑过程中的"假阳性"更新

### 7.6 Interval 门控机制：只在中"强制校验"（★ 关键变更）

**设计变更**（2026-06-17 起）：默认不再每轮强制要求 `task_progress`，而是在**到达 remindClineInterval（默认 6 轮）时**才进行强制校验。未到达 interval 时跳过的**不**只是 `task_progress`，还包括 `workflow` 和 `skill` 参数。

#### a) 工具调用级别地强制校验（`ToolExecutor.ts:345-447`）

执行逻辑分两条路径：

**路径 A：`attempt_completion`（始终严格）**
- `task_progress` 始终为必填（skipTaskProgress=false）
- 额外解析 checklist 内容，**检查是否所有 `[ ]` 均已标记为 `[x]`**
- 如有未完成项，返回错误列出未完成项

**路径 B：其他工具（Interval 门控）**

```typescript
// ToolExecutor.ts:415-441
const focusChainSettings = this.stateManager.getGlobalSettingsKey("focusChainSettings")
const remindClineInterval = focusChainSettings?.remindClineInterval ?? 6
const reachedReminderInterval =
    this.taskState.apiRequestsSinceLastTodoUpdate >= remindClineInterval
const skipTaskProgress = !reachedReminderInterval

const result = this.validator.assertRequiredParamsFromSpec(block, toolSpec?.config, {
    skipTaskProgress,
    skipSkillWorkflow: skipTaskProgress,  // <-- 同一个变量控制两者
})
```

**关键点**：
- `skipTaskProgress` 和 `skipSkillWorkflow` 使用**同一个布尔值**控制
- 当 `apiRequestsSinceLastTodoUpdate < 6` → 两者均跳过
- 当 `apiRequestsSinceLastTodoUpdate >= 6` → 两者均强制校验
- `apiRequestsSinceLastTodoUpdate` 在模型提交 `task_progress` 时重置为 0

**豁免工具**（始终不强制）：`todo`, `act_mode`, `plan_mode`

#### b) Todo 列表规则：内容细化 + 结果标注

**当前要求**（来自 `prompts.ts` 的 `rulesComplianceReminder` + `activeSkillWorkflowReminder`）：

```
- [ ] 每项在完成之后要在列表之后标注结果或发现
      示例: - [x] 创建组件 (用了 React.FC + TypeScript)
- [ ] todo 列表要参考 skill、rules 和 workflows 来写
- [ ] 使用 task_progress 参数时需包含完整 checklist
```

这确保了 todo 列表不仅含任务步骤，还包含执行结果，并且参考了当前激活的 rules/skills/workflows 内容。

### 7.7 与 `task_progress` 参数的协同

```
         模型视角                         Harness 视角
         ───────                         ───────────
   工具调用: <write_to_file>
             <task_progress>           ← ① 解析 task_progress
               - [x] 已完成1
               - [x] 已完成2
               - [ ] 待完成
             </task_progress>
                                   
                                    → ② 写文件
                                    → ③ say("task_progress", ...)
                                    → ④ 重置 apiRequestsSinceLastTodoUpdate=0
                                    → ⑤ 触发 telemetry
```

**设计哲学**：把"todo 列表"放在**所有 tool 调用的可选参数**上，是非常聪明的设计——模型**没法跳过**这个字段（即使不填，也不影响工具执行），但 Harness 可以**强制每隔 N 轮**提醒一次。

---

## 8. 辅助防线 1：ContextManager 上下文治理

### 8.1 定位

LLM 上下文窗口是有限的。ContextManager 解决 3 个问题：

1. **超长对话导致 token 超限** → 截断 + 摘要
2. **重复 read_file 浪费 token** → 去重
3. **tool_use / tool_result 配对错乱** → 修复

### 8.2 截断策略 4 种

```typescript
// apps/vscode/src/core/context/context-management/ContextManager.ts
getNextTruncationRange(apiMessages, currentDeletedRange, keep) {
    // keep 参数：
    //   "none"     → 删除所有中间消息（完全重启，不常用）
    //   "lastTwo"  → 仅保留首尾 user-assistant pair（测试用）
    //   "half"     → 删除一半 pair（旧版普通截断）
    //   "quarter"  → 删除 3/4 pair（激进截断 / 强制重试）
}
```

### 8.3 阈值计算

```typescript
function getContextWindowInfo(api) {
    let contextWindow = api.getModel().info.contextWindow || 128_000
    
    // 64k (deepseek) -27k = 37k
    // 128k -30k = 98k
    // 200k (claude) -40k = 160k
    // default: max(contextWindow - 40k, 80%)
    let maxAllowedSize = ...
    
    return { contextWindow, maxAllowedSize }
}
```

**设计权衡**：保留 27-40k 给 system prompt + 新一轮输出 + 缓冲，避免真正用满 context 触发 API 错误。

### 8.4 File Read 去重（最实用优化）

```typescript
// 每轮自动找出重复的 read_file / write_to_file / file_mention 调用
// 只保留最后一次完整内容，历史版本替换为 [[NOTE] This file read has been removed...]

// 节省 < 30% 仍触发截断
return { anyContextUpdates, needToTruncate: percentSaved < 0.3 }
```

**对不偏离的贡献**：减少 LLM 因"context 变长"而丢失早期约束的概率。

### 8.5 Auto-Condense（Next-gen 模型默认）

```
[1] shouldCompact = (useAutoCondense && isNextGenModelFamily)
[2] if (shouldCompact && 已压缩过 && activeMessageCount <= 2) shouldCompact = false
[3] if (shouldCompact) 先尝试 file read 优化（节省 30%+ 就跳过 auto-compact）
[4] if (shouldCompact) 追加 summarizeTask 提示，让 LLM 调 summarize_task 工具
[5] 下一轮 currentlySummarizing 检测 → conversationHistoryDeletedRange += 2
```

**PreCompact Hook**：自动压缩前触发，**允许 hook 干预**。这是为团队级"压缩前先做点啥"留的扩展点。

### 8.6 Truncation Notice —— "被截断的提示"

当 `conversationHistoryDeletedRange` 实际变化时，ContextManager 会在历史消息中插入显式 notice：

```typescript
// 第一条 user message 替换为：
"[Continue assisting the user!]"

// 第一条 assistant message 顶部追加：
"[NOTE] Some previous conversation history with the user has been removed to maintain optimal context window length. 
The initial user task has been retained for continuity, while intermediate conversation history has been removed. 
Keep this in mind as you continue assisting the user. Pay special attention to the user's latest messages."
```

**对不偏离的贡献**：让 LLM 明确知道"上下文不完整"——这避免它误以为自己已经知道的事情（实际是早期的）。

---

## 9. 辅助防线 2：PLAN MODE / ACT MODE 双模式约束

### 9.1 定位

把"想"和"做"分离是减少跑偏的关键工程模式：

```
┌────────────────────────────────────────────────────────────────┐
│  PLAN MODE                                                       │
│  ──────────                                                      │
│  • 可用工具：只读工具（read_file / search_files / list_files）   │
│              + plan_mode_respond                                │
│  • 不可用：write_to_file / replace_in_file / execute_command     │
│  • 目的：让 LLM 在"动手前"先把计划讲清楚                          │
│  • 切到 ACT：用户手动操作（UI 按钮）                              │
│  • FocusChain 行为：弱提示（planModeReminder）                    │
│                                                                 │
│  ACT MODE                                                       │
│  ─────────                                                      │
│  • 可用工具：全部                                                │
│  • FocusChain 行为：强提示 / 强要求（initial / reminder）        │
│  • 任务完成必须用 attempt_completion 工具                        │
└────────────────────────────────────────────────────────────────┘
```

### 9.2 System Prompt 中的 ACT_VS_PLAN 组件

```typescript
// apps/vscode/src/core/prompts/system-prompt/components/act_vs_plan_mode.ts
const getActVsPlanModeTemplateText = (context) => `ACT MODE V.S. PLAN MODE

In each user message, the environment_details will specify the current mode. There are two modes:

- ACT MODE: In this mode, you have access to all tools EXCEPT the plan_mode_respond tool.
 - In ACT MODE, you use tools to accomplish the user's task. Once you've completed the user's task, you use the attempt_completion tool to present the result of the task to the user.
- PLAN MODE: In this special mode, you have access to the plan_mode_respond tool.
 - In PLAN MODE, the goal is to gather information and get context to create a detailed plan for accomplishing the task, which the user will review and approve before they switch you to ACT MODE to implement the solution.

## What is PLAN MODE?
- While you are usually in ACT MODE, the user may switch to PLAN MODE in order to have a back and forth with you to plan how to best accomplish the task. 
- When starting in PLAN MODE, depending on the user's request, you may need to do some information gathering e.g. using read_file or search_files to get more context about the task.${context.yoloModeToggled !== true ? " You may also ask the user clarifying questions with ask_followup_question to get a better understanding of the task." : ""}
- Once you've gained more context about the user's request, you should architect a detailed plan for how you will accomplish the task. Present the plan to the user using the plan_mode_respond tool.
- Then you might ask the user if they are pleased with this plan, or if they would like to make any changes. Think of this as a brainstorming session where you can discuss the task and plan the best way to accomplish it.
- Finally once it seems like you've reached a good plan, ask the user to switch you back to ACT MODE to implement the solution.`
```

### 9.3 对不偏离的贡献

| 维度 | PLAN MODE 贡献 | ACT MODE 贡献 |
|------|---------------|---------------|
| **思考深度** | 强制 LLM 在动手前把计划讲清楚 | 不强制（但 OBJECTIVE 第 3 条 <thinking> 标签兜底） |
| **行动权限** | 严格受限 | 全部 |
| **FocusChain** | 弱提示 | 强提示/强要求 |
| **切换点** | 用户手动 | 触发 FocusChain 切换后自动 |

**核心思想**：把"用户审批计划"作为"模型开始执行"的**硬性门**。

---

## 10. 辅助防线 3：Hooks 扩展点（外部干预通道）

### 10.1 定位

Hooks 是**项目级**的"外部干预通道"——允许项目所有者通过脚本在关键 Harness 节点注入 context 或阻止行为。

### 10.2 5 个 Hook 点

```
┌──────────────────────────────────────────────────────────────────┐
│  Hook 触发点              触发时机           可注入内容            │
├──────────────────────────────────────────────────────────────────┤
│  TaskStart                任务开始时         contextModification  │
│  UserPromptSubmit         每次用户输入       contextModification  │
│  TaskResume               任务恢复时         contextModification  │
│  TaskCancel               任务取消时         可阻止 cancel         │
│  PreCompact               自动压缩前         可阻止 auto-compact  │
└──────────────────────────────────────────────────────────────────┘
```

### 10.3 contextModification 注入方式

```typescript
// apps/vscode/src/core/task/index.ts:1108-1182
if (hooksEnabled) {
    const taskStartResult = await executeHook({ hookName: "TaskStart", ... })
    if (taskStartResult.contextModification) {
        userContent.push({ 
            type: "text", 
            text: `<hook_context source="TaskStart">\n${contextText}\n</hook_context>` 
        })
    }
}
```

**对不偏离的贡献**：让团队可以在 Harness 之外**再叠加一层**约束（例如强制走安全审批流程、注入团队编码规范、禁止操作某些文件等）。

---

## 11. 辅助防线 4：Rules / Skills / Workflows 三层配置

> **本节是已有文档 `Rules_Workflows_Skills加载机制详解.md` 的体系化整合，详尽内容请参考原文档。**

### 11.1 Rules — 强制规则层（注入 System Prompt）

| 类型 | 来源 | 注入位置 | 频率 |
|------|------|---------|------|
| `globalClineRules` | `~/Documents/Cline/Rules/` + remoteConfig | System Prompt 末尾 | 每轮 |
| `localClineRules` | `<cwd>/.clinerules/`（排除 workflows/hooks/skills） | System Prompt 末尾 | 每轮 |
| `localCursorRules` | `<cwd>/.cursorrules` | System Prompt 末尾 | 每轮 |
| `localCursorRulesDir` | `<cwd>/.cursor/rules/` | System Prompt 末尾 | 每轮 |
| `localWindsurfRules` | `<cwd>/.windsurfrules` | System Prompt 末尾 | 每轮 |
| `localAgentsRules` | `<cwd>/.agents/AGENT.md` | System Prompt 末尾 | 每轮 |
| `clineIgnoreInstructions` | `<cwd>/.clineignore` | System Prompt 末尾 | 每轮 |
| `preferredLanguageInstructions` | 用户设置 | System Prompt 末尾 | 每轮 |

### 11.2 Workflows — 工作流触发层（按需注入 User Message）

| 类型 | 来源 | 注入方式 | 触发条件 |
|------|------|---------|---------|
| `globalWorkflows` | `~/Documents/Cline/Workflows/` | `<explicit_instructions>` | 用户输入 `/<name>` |
| `localWorkflows` | `<cwd>/.clinerules/workflows/` | `<explicit_instructions>` | 用户输入 `/<name>` |
| `remoteWorkflows` | remoteConfig | `<explicit_instructions>` | 用户输入 `/<name>` |

### 11.3 Skills — 技能包（按需加载）

| 优先级 | 目录 |
|--------|------|
| 低 | `<cwd>/.clinerules/skills/<name>/SKILL.md` |
| ↓ | `<cwd>/.cline/skills/<name>/SKILL.md` |
| ↓ | `<cwd>/.claude/skills/<name>/SKILL.md` |
| ↓ | `<cwd>/.agents/skills/<name>/SKILL.md` |
| ↓ | `~/.cline/skills/<name>/SKILL.md` |
| ↓ | `~/.agents/skills/<name>/SKILL.md` |
| 高 | remoteConfig |

**Skills 三步加载**：
1. **元数据**注入 System Prompt（`name + description`）
2. LLM 调 `use_skill` 工具时**按需加载**实际指令
3. 指令以 tool_result 形式回流到 messages

### 11.4 三者对比

| 维度 | Rules | Workflows | Skills |
|------|-------|-----------|--------|
| **注入层** | System Prompt | User Message | System Prompt（元数据）+ messages（按需） |
| **加载时机** | 每轮全量加载 | 触发时懒加载 | 元数据每轮，按需懒加载 |
| **作用范围** | 全局生效 | 单次任务 | 任务内可选调用 |
| **格式要求** | 纯文本（YAML 可选） | 纯文本 | 必须 YAML frontmatter |
| **典型场景** | 编码规范、风格约束 | 复杂多步任务模板 | 可复用的 prompt 包 |

---

## 12. 多轮不偏离的反馈闭环（核心结论）

把所有防线串起来，**多轮不偏离的反馈闭环**是这样的：

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  第 1 轮：startTask                                                    │
│  ───────────────                                                      │
│  System Prompt 重建（宪法）：                                          │
│    • 角色/工具/规则/8 类用户规则                                       │
│    • TASK_PROGRESS 教导 agent 使用 task_progress                      │
│  User Message：                                                       │
│    • <task>原始任务</task>                                            │
│    • <environment_details>（含完整 CWD Files）                        │
│    • FocusChain 指令：initial（要求创建清单）                          │
│                                                                      │
│       ↓ LLM 看到                                                                 
│                                                                      │
│  LLM 响应：<write_to_file path="A" content="..."/>                    │
│           <task_progress>                                              │
│             - [x] 分析需求                                            │
│             - [ ] 创建文件 A                                          │
│             - [ ] 创建文件 B                                          │
│           </task_progress>                                            │
│                                                                      │
│       ↓ Harness 处理                                                                   
│                                                                      │
│  updateFCListFromToolResponse("..."):                                 │
│    • 写 focus_chain_{taskId}.md                                      │
│    • say("task_progress", ...) 通知 UI                                │
│    • 重置 apiRequestsSinceLastTodoUpdate=0                           │
│  执行 write_to_file：实际写文件                                        │
│  addToApiConversationHistory(tool_result)                             │
│                                                                      │
│       ↓ 继续下一轮                                                                   
│                                                                      │
│  第 N 轮（"请问改成 XXX"）：                                          │
│  ─────────────────────                                                │
│  System Prompt 重建：同第 1 轮（无变化）                              │
│  User Message：                                                       │
│    • <user_message>请把 A 改成 XXX</user_message>                    │
│    • <environment_details>（含 # Recently Modified Files: A）        │
│    • FocusChain 指令：                                                │
│         - listCurrentProgress: "1/3 items completed (33%)"            │
│         - checklist 内容                                              │
│         - reminder                                                    │
│         - 提示 "33% complete"                                         │
│                                                                      │
│       ↓ LLM 看到                                                                 
│                                                                      │
│  LLM 现在同时看到：                                                   │
│   ① 用户的最新诉求                                                    │
│   ② 当前的环境状态（什么文件被改过）                                   │
│   ③ 自己之前承诺的清单（1/3 完成）                                    │
│   ④ 提示 "继续完成剩余 2 项"                                          │
│                                                                      │
│  LLM 响应：调 replace_in_file                                         │
│           <task_progress>                                              │
│             - [x] 分析需求                                            │
│             - [ ] 创建文件 A ← 仍标记 [ ]? 其实是完成的               │
│             - [x] 修改 A 内容 ← 新增项                                │
│           </task_progress>                                            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 关键设计点总结

| 设计 | 解决什么问题 | 怎么解决的 |
|------|-------------|-----------|
| System Prompt 每轮重建 | 用户改了规则 → 立即生效 | `getSystemPrompt()` 无缓存（component 内可缓存） |
| `task_progress` 强提示 | 跑偏 → 提醒还剩多少工作 | `shouldIncludeFocusChainInstructions()` 多重判断 |
| FocusChain 文件持久化 | 任务中断 → 续接时仍知道进度 | 磁盘文件 + chokidar 监听 + `currentFocusChainChecklist` |
| 用户可编辑清单 | 用户想微调计划 | `todoListWasUpdatedByUser` 标志 + 注入 "用户已修改" 提示 |
| 进度反馈到 UI | 用户需要看到 agent 在做什么 | `say("task_progress", ...)` + WebView 订阅 |
| 验证后再 attempt_completion | 目标偏移 → 强制自检 | OBJECTIVE 第 4 条 |
| PLAN/ACT 双模式 | 上来就动手 → 强制先想 | `act_vs_plan_mode` 组件 + 工具可用性差异 |
| Workflow override 标签 | 工作流被忽略 → 显式 override | `<workflow_execution_override>` 末尾追加 |
| `<environment_details>` 每轮 | LLM 看不到当前状态 → 强制推送 | 每次构建 userContent 时调用 |
| Truncation Notice | 上下文被截断 → 显式提示 | `processFirstUserMessageForTruncation` + `contextTruncationNotice` |
| File read 去重 | token 浪费 → 自动去重 | `applyContextOptimizations` |
| Hooks contextModification | 团队级定制 | 5 个 hook 点 + XML 包裹注入 |

### 一句话总结

> **CygCode Harness 的核心思想是：把 LLM 当成一个"无状态、健忘、易分心"的协作者，所有约束都通过 System Prompt + User Message + Tool 协议 + FocusChain 四个层面**每轮重新注入**，形成"对状态的外部控制"。它不做"模型自我管理"，而是做"系统侧强约束"**。

---

## 13. 关键源码索引

| 主题 | 文件路径 |
|------|----------|
| **主循环入口** | `apps/vscode/src/core/task/index.ts` (`initiateTaskLoop`, `recursivelyMakeClineRequests`, `attemptApiRequest`) |
| **System Prompt 入口** | `apps/vscode/src/core/prompts/system-prompt/index.ts` (`getSystemPrompt`) |
| **Variant 注册表** | `apps/vscode/src/core/prompts/system-prompt/registry/PromptRegistry.ts` |
| **Variant 构建器** | `apps/vscode/src/core/prompts/system-prompt/variants/variant-builder.ts` |
| **Generic Variant** | `apps/vscode/src/core/prompts/system-prompt/variants/generic/config.ts` + `template.ts` |
| **PromptBuilder** | `apps/vscode/src/core/prompts/system-prompt/registry/PromptBuilder.ts` |
| **TemplateEngine** | `apps/vscode/src/core/prompts/system-prompt/templates/TemplateEngine.ts` |
| **AGENT_ROLE** | `apps/vscode/src/core/prompts/system-prompt/components/agent_role.ts` |
| **TOOL_USE** | `apps/vscode/src/core/prompts/system-prompt/components/tool_use/index.ts` |
| **TASK_PROGRESS 组件** | `apps/vscode/src/core/prompts/system-prompt/components/task_progress.ts` |
| **MCP** | `apps/vscode/src/core/prompts/system-prompt/components/mcp.ts` |
| **EDITING_FILES** | `apps/vscode/src/core/prompts/system-prompt/components/editing_files.ts` |
| **ACT_VS_PLAN** | `apps/vscode/src/core/prompts/system-prompt/components/act_vs_plan_mode.ts` |
| **CAPABILITIES** | `apps/vscode/src/core/prompts/system-prompt/components/capabilities.ts` |
| **SKILLS** | `apps/vscode/src/core/prompts/system-prompt/components/skills.ts` |
| **FEEDBACK** | `apps/vscode/src/core/prompts/system-prompt/components/feedback.ts` |
| **RULES** | `apps/vscode/src/core/prompts/system-prompt/components/rules.ts` |
| **SYSTEM_INFO** | `apps/vscode/src/core/prompts/system-prompt/components/system_info.ts` |
| **OBJECTIVE** | `apps/vscode/src/core/prompts/system-prompt/components/objective.ts` |
| **USER_INSTRUCTIONS** | `apps/vscode/src/core/prompts/system-prompt/components/user_instructions.ts` |
| **FocusChainManager** | `apps/vscode/src/core/task/focus-chain/index.ts` |
| **FocusChain Prompts** | `apps/vscode/src/core/task/focus-chain/prompts.ts` |
| **FocusChain file utils** | `apps/vscode/src/core/task/focus-chain/file-utils.ts` |
| **FocusChainSettings** | `apps/vscode/src/shared/FocusChainSettings.ts` |
| **TaskState** | `apps/vscode/src/core/task/TaskState.ts` |
| **loadContext** | `apps/vscode/src/core/task/index.ts` (around line 3438) |
| **environmentDetails** | `apps/vscode/src/core/task/index.ts` (around line 3683) |
| **parseSlashCommands** | `apps/vscode/src/core/slash-commands/index.ts` |
| **parseMentions** | `apps/vscode/src/core/mentions/` |
| **ContextManager** | `apps/vscode/src/core/context/context-management/ContextManager.ts` |
| **contextWindow-utils** | `apps/vscode/src/core/context/context-management/context-window-utils.ts` |
| **summarizeTask / continuationPrompt** | `apps/vscode/src/core/prompts/contextManagement.ts` |
| **Rules 加载** | `apps/vscode/src/core/context/instructions/user-instructions/cline-rules.ts` |
| **Rules Helpers** | `apps/vscode/src/core/context/instructions/user-instructions/rule-helpers.ts` |
| **Rule Conditionals** | `apps/vscode/src/core/context/instructions/user-instructions/rule-conditionals.ts` |
| **External Rules** | `apps/vscode/src/core/context/instructions/user-instructions/external-rules.ts` |
| **Workflows 加载** | `apps/vscode/src/core/context/instructions/user-instructions/workflows.ts` |
| **Skills 发现** | `apps/vscode/src/core/context/instructions/user-instructions/skills.ts` |
| **frontmatter 解析** | `apps/vscode/src/core/context/instructions/user-instructions/frontmatter.ts` |
| **Hooks** | `apps/vscode/src/core/hooks/` |
| **formatResponse** | `apps/vscode/src/core/prompts/responses.ts` |
| **message-state** | `apps/vscode/src/core/task/message-state.ts` |

---

## 14. 附录 A：Harness 关键简图汇总

### 14.1 "不偏离"的 4 道防线 + 4 个辅助防线

```
                            LLM（健忘、易跑偏）
                                   ▲
                                   │
       ┌───────────────────────────┼───────────────────────────┐
       │            Harness 在每一轮强制注入的"四道防线"         │
       │                           │                          │
       │   ┌───────────────────────┴───────────────────────┐  │
       │   │  ① System Prompt：宪法（角色/工具/规则/原则）    │  │
       │   │     ↓                                          │  │
       │   │  ② User Message：状态快报（任务/环境/进度）      │  │
       │   │     ↓                                          │  │
       │   │  ③ Tool 协议：行动约束（XML schema）            │  │
       │   │     ↓                                          │  │
       │   │  ④ FocusChain：计划锚定（跨轮次 todo list）     │  │
       │   └───────────────────────────────────────────────┘  │
       │                                                      │
       │   辅助防线：                                         │
       │   • ContextManager：上下文治理（截断+去重+摘要）     │
       │   • PLAN/ACT MODE：双模式分离                        │
       │   • Hooks：项目级外部干预                            │
       │   • Rules/Skills/Workflows：三层配置源               │
       └──────────────────────────────────────────────────────┘
```

### 14.2 单轮 API 调用的"组装清单"

```
  每轮 LLM API 调用前，Task.recursivelyMakeClineRequests → attemptApiRequest 都会：

  1.  加载 Rules（7 类）              ←  ① 静态契约
  2.  加载 Skills（3 层）             ←  ① 静态契约
  3.  收集 Editor 状态
  4.  解析 multi-root workspace
  5.  构建 SystemPromptContext
  6.  生成 System Prompt（每轮重新）  ←  ① 静态契约
  7.  追加 Hook context               ←  辅助 3
  8.  追加 environment_details        ←  ② 动态状态
  9.  追加 FocusChain 指令            ←  ④ 计划锚定
  10. 追加 workflow 指令              ←  辅助 4
  11. 追加 summarize 指令             ←  辅助 1
  12. 持久化到 api_conversation_history
  13. ContextManager 决策              ←  辅助 1
        - file read 去重
        - 截断（half/quarter）
        - tool_use/result 配对修复
  14. api.createMessage(system, history, tools?)
```

### 14.3 System Prompt 12 section 总图

```
┌──────────────────────────────────────────────────────────────────┐
│  System Prompt = baseTemplate + 占位符替换 + postProcess         │
│                                                                  │
│  ① {{AGENT_ROLE}}      "You are Cyg Code..."                     │
│  ② {{TOOL_USE}}        所有可用工具的参数/用法（XML 格式）        │
│  ③ {{TASK_PROGRESS}}   task_progress 参数使用说明                │
│  ④ {{MCP}}             [条件] 已连接 MCP server 时出现            │
│  ⑤ {{EDITING_FILES}}   write_to_file / replace_in_file 规则      │
│  ⑥ {{ACT_VS_PLAN}}     ACT vs PLAN 区分                          │
│  ⑦ {{CAPABILITIES}}    工具能力清单                              │
│  ⑧ {{SKILLS}}          [条件] Skills 元数据                      │
│  ⑨ {{FEEDBACK}}        /reportbug + 回答策略                     │
│  ⑩ {{RULES}}           CWD / 工具约束 / CLI / browser 规则       │
│  ⑪ {{SYSTEM_INFO}}     OS / IDE / Shell / 工作目录               │
│  ⑫ {{OBJECTIVE}}       7 条任务执行原则                          │
│  ⑬ {{USER_INSTRUCTIONS}}  8 类规则按固定顺序拼接                  │
└──────────────────────────────────────────────────────────────────┘
```

### 14.4 User Message 5 段式结构

```
┌──────────────────────────────────────────────────────────────────┐
│  userContent[] （按追加顺序）                                     │
│                                                                  │
│  A. 基础内容                                                      │
│     • <task>...</task>                       首轮                │
│     • <user_message>...</user_message>       非首轮              │
│     • <file_content path="...">              附件                │
│     • <image> base64                         图片                │
│     • <hook_context source="...">            hook 注入           │
│                                                                  │
│  B. parseTextBlock（loadContext 中执行）                          │
│     • @file: → 替换为 <file_content path="...">                 │
│     • /cmd  → 移除命令、保留参数、可能匹配 workflow              │
│                                                                  │
│  C. ★ 每轮追加（Harness 注入点）                                  │
│     1. <environment_details>...</environment_details>           │
│     2. [Focus Chain 实际 todo list 内容]   [条件]                │
│     3. <explicit_instructions type="<workflow>">  [可选]         │
│     4. <workflow_execution_override>           [可选]            │
│     5. <explicit_instructions type="summarize_task">  [可选]     │
└──────────────────────────────────────────────────────────────────┘
```

### 14.5 FocusChain 状态机

```
  ┌────────────────┐
  │   没清单       │  ─── 切到 ACT ───▶  inject initial
  │   (PLAN MODE)  │
  └────────────────┘
          │
          │ 切到 ACT
          ▼
  ┌────────────────┐        LLM 调工具附带 task_progress
  │   有清单       │  ◀────────────────────────────────────┐
  │   (ACT MODE)   │                                         │
  └────────────────┘                                         │
          │                                                  │
          │ remindClineInterval 轮未更新                     │
          ▼                                                  │
  ┌────────────────┐                                         │
  │   inject       │  ─── 提醒 ───▶ LLM 更新 task_progress  ─┘
  │   reminder     │
  └────────────────┘
          │
          │ 用户编辑了文件
          ▼
  ┌────────────────┐
  │  user updated  │  ─── 注入 ───▶ LLM 看到 "用户已修改"
  │  list detected │
  └────────────────┘
          │
          │ 全部完成
          ▼
  ┌────────────────┐
  │   completed    │  ─── 注入 ───▶ LLM 调 attempt_completion
  │   inject       │
  └────────────────┘
```

### 14.6 Harness 与 LLM 之间的"双向流"

```
  ┌──────────────┐                                ┌──────────────┐
  │   Harness    │ ─── system + user message ──▶ │   LLM        │
  │              │                                │              │
  │  每轮重建：  │ ◀──  assistant response ─────  │  输出：      │
  │  • Rules    │                                │  • 文本思考  │
  │  • Env      │                                │  • 工具调用  │
  │  • FocusChain│                                │  • task_progress
  │  • Workflow │                                │              │
  └──────────────┘                                └──────────────┘
         │                                              │
         │                                              │
         └────────── Harness 处理响应 ──────────────────┘
                    • 解析 tool_use
                    • 写 FocusChain 文件
                    • 执行工具
                    • 收集 tool_result
                    • 写回 api_conversation_history
                    • 触发 UI 更新
```

---

## 15. 附录 B：对照实验思考 — 如果去掉某道防线会怎样

| 去掉 | 后果 |
|------|------|
| 去掉 ① System Prompt | LLM 没有角色认知，不知道用什么工具，不知道 CWD 在哪 |
| 去掉 ② `<environment_details>` | LLM 不知道当前打开了什么文件，可能在已删除的路径上操作 |
| 去掉 ② Workflow override | Workflow 触发了但 LLM 把它当普通 user 输入忽略 |
| 去掉 ③ Tool schema | LLM 输出自由格式文本，根本调不通工具 |
| 去掉 ④ FocusChain | 任务超过 5-10 轮后，LLM 必然忘记早期规划，开始"自由发挥" |
| 去掉 ④ 持久化 | 任务中断后无法续接，模型不知道自己做到哪了 |
| 去掉 ④ 文件监听 | 用户改了清单，模型不知道，仍按旧清单执行 |
| 去掉 ① 强制验证（OBJECTIVE 第 4 条） | 模型倾向"快速宣布完成"，不做自检 |
| 去掉 PLAN/ACT 双模式 | 复杂任务上来就动手，方向错了再返工 |
| 去掉 ContextManager | 长对话会因 context 超限 API 报错 |
| 去掉 File Read 去重 | 长对话 token 浪费严重，触发不必要的截断 |
| 去掉 Truncation Notice | LLM 不知道早期信息被截断，误以为还有 |
| 去掉 Hooks | 团队级定制只能改源码 |
| 去掉 Rules toggle | 关闭规则后下次启动又重新启用 |
| 去掉 Variant 区分 | 同一个 prompt 给小模型和大模型，效率低下 |

---

## 总结

CygCode 的 Harness 工程是一套**多层防御、多点干预、状态外化**的完整体系：

1. **System Prompt 解决"做什么"**（规则、原则、能力边界）
2. **User Message 解决"现在什么状态"**（环境、进度、临时指令）
3. **Tool 协议解决"必须按格式做"**（硬性 schema 约束）
4. **FocusChain 解决"别忘了我刚才的计划"**（持久化、跨轮次、用户可干预）
5. **ContextManager 解决"上下文太长怎么办"**（截断+去重+摘要）
6. **PLAN/ACT 模式解决"先想清楚再动手"**（双模式分离）
7. **Hooks 解决"团队级定制"**（5 个扩展点）
8. **Rules/Skills/Workflows 解决"用户可配置"**（三层配置源）

8 个子系统**协同工作**形成反馈闭环：每轮 LLM 调用前，Harness 都会**主动重新计算**所有约束的内容，然后**强制注入**到 LLM 看到的上下文中。

这种设计的核心哲学是：

> **不依赖 LLM 自身的"记忆"或"自控力"，而是用工程手段把所有约束"外化"成可观测、可调整、可调试的系统行为。**

这是 CygCode（Cline）作为成熟 AI Agent 框架的核心工程价值，也是值得任何 Agent 系统借鉴的范式。

---

*文档生成时间：2026-06-11*
*基于代码版本：af6c7d7fdfb4fdee08ea63c97809c7d7e39badd5*
*整合来源：*
- *CygCodeFunctionIntroduction/FocusChain与TaskProgress提示词机制详解.md*
- *CygCodeFunctionIntroduction/Rules_Workflows_Skills加载机制详解.md*
- *CygCodeFunctionIntroduction/cygcode上下文管理*
- *源码逐行分析：focus-chain/, system-prompt/, context-management/, task/index.ts 等*


---

## 11.5 辅助防线 5：Tool 输出截断与压缩机制

> **本节是基于源码调研的新增章节**（2026-06-17），系统化梳理项目中对各类工具（tool handler）输出结果的截断/压缩机制。

### 11.5.1 定位与动机

Tool 调用是 LLM 获取外部信息的主要途径。Tool 的输出可能极长（例如读取大文件、搜索大量结果、运行长命令），如果**直接全量塞回 LLM 的 messages 数组**，会导致：

1. **Context window 快速耗尽** → 触发 ContextManager 的截断（见 §8）
2. **LLM 注意力分散** → 长输出稀释关键信息
3. **Token 费用增加** → 不必要的成本

因此 CygCode 在 **tool handler 层** 预先做"输出体积治理"。这与 ContextManager 的"消息历史治理"形成**双重防御**：

```
┌──────────────────────────────────────────────────────────────────┐
│  Tool 输出治理双层防御                                             │
│                                                                  │
│  Layer A: Tool Handler 层（handler 内部裁剪）                    │
│   - 在 tool 结果返回 LLM 之前，先做体积控制                       │
│   - 例如：read_file 最多 1000 行、list_files 最多 200 个          │
│                                                                  │
│  Layer B: ContextManager 层（消息历史裁剪）                       │
│   - 在 tool 结果进入 messages 后，再做整体去重/截断               │
│   - 例如：重复 read_file 内容替换为 [NOTE]，25% 消息删除          │
│                                                                  │
│  两层互相独立，互不耦合                                            │
└──────────────────────────────────────────────────────────────────┘
```

### 11.5.2 完整截断点清单

通过对 `apps/vscode/src/core/task/tools/handlers/` 目录下 25 个 handler 的系统调研，整理出以下截断点：

| # | 截断函数 | 工具 | 位置 | 默认值 | 触发时机 |
|---|---------|------|------|--------|----------|
| 1 | `excerpt()` | **subagent** | `SubagentToolHandler.ts:36-47` | **不再使用**（`excerpt()` 是死代码，已改为无截断的 `.trim()` 透传） | **返回结果给主 agent**（**截断已完全移除，仅保留空白清理**） |
| 2 | `truncateContent()` | read_file (PDF/DOCX/Excel/IPYNB) | `extract-text.ts:76` | **400 KB** | 任意文件读取 |
| 3 | `truncateContent()` | mcp tools | `UseMcpToolHandler.ts:209` | **400 KB** | MCP 工具调用 |
| 4 | `truncateContent()` | mcp resources | `AccessMcpResourceHandler.ts:163` | **400 KB** | MCP 资源访问 |
| 5 | `DEFAULT_MAX_LINES` | read_file | `ReadFileToolHandler.ts:18` | **1000 行** | 未指定 end_line 时 |
| 6 | `listFiles(..., 200)` | list_files | `ListFilesToolHandler.ts:100` | **200 文件** | 目录列表 |
| 7 | `extractTextFromExcel` | read_file (xlsx) | `extract-text.ts:162-165` | **50000 行** | Excel 行级截断 |
| 8 | 20 MB 硬限制 | read_file | `extract-text.ts:66-69` | **20 MB** | 文本文件大小限制 |
| 9 | `shouldCompactBeforeNextRequest()` | subagent 内部 | `SubagentRunner.ts:834-849` | **75% context window** (next-gen) / `maxAllowedSize` | 上下文管理 |
| 10 | `getNextTruncationRange("quarter")` | subagent 内部 | `SubagentRunner.ts:787` | **25% 消息** | 上下文不足时 |

### 11.5.3 核心截断函数详解

#### a) `truncateContent()` - 全局 400KB 字节级截断

**文件**：`apps/vscode/src/shared/content-limits.ts`

```typescript
export const MAX_CONTENT_SIZE_BYTES = 400 * 1024  // 400 KB

export function truncateContent(content: string, maxSize = MAX_CONTENT_SIZE_BYTES): string {
    if (content.length <= maxSize) return content
    const truncatedContent = content.slice(0, maxSize)
    return `${truncatedContent}\n\n---\n\n[FILE TRUNCATED: This content is ${formatBytes(content.length)} but only the first ${formatBytes(maxSize)} is shown (${formatBytes(content.length - maxSize)} truncated). Use search_files to find specific patterns, or execute_command with grep/head/tail for targeted reading.]`
}
```

**调用方**：
- `extract-text.ts:76` — 所有 read_file（PDF/DOCX/Excel/IPYNB/普通文本）
- `UseMcpToolHandler.ts:209` — MCP 工具调用
- `AccessMcpResourceHandler.ts:163` — MCP 资源访问

**设计特点**：
- 截断后附加 `[FILE TRUNCATED: ...]` 提示，让 LLM 明确知道被截断
- 提示 LLM 用 `search_files` 或 `grep` 找到具体内容

#### b) `excerpt()` - subagent 输出截断（已移除，仅保留死代码）

**文件**：`apps/vscode/src/core/task/tools/handlers/SubagentToolHandler.ts:36-47`

```typescript
function excerpt(text: string | undefined, maxChars = 1200): string {
    if (!text) return ""
    const trimmed = text.trim()
    if (trimmed.length <= maxChars) return trimmed
    return `${trimmed.slice(0, maxChars)}...`
}
```

**当前状态（2026-06-17 起）**：`excerpt()` 函数**仍作为死代码保留在文件中**，但**在 summary 组装中已不再被调用**。实际代码（`SubagentToolHandler.ts:321-322`）改为：

```typescript
const detail =
    entry.status === "completed" ? (entry.result?.trim() ?? "") : (entry.error?.trim() ?? "")
```

即仅做 `.trim()` 空白清理，**不做任何字符上限截断**。原截断调用已被注释保留：
```typescript
// const detail = entry.status === "completed" ? excerpt(entry.result) : excerpt(entry.error)
```

**修改原因**：subagent 分析长文件、生成长报告或产生大量代码时，1200 字符硬截断会导致主 agent 看到不完整信息，影响判断。移除后主 agent 能看到 subagent 的完整输出。

**保护措施仍然存在**：subagent 内部仍受 context window 压缩保护（第 2/3 层），且 read_file / MCP 工具的 400KB 全局限制仍然有效。

#### c) `DEFAULT_MAX_LINES` - read_file 行数截断

**文件**：`apps/vscode/src/core/task/tools/handlers/ReadFileToolHandler.ts:18`

```typescript
export const DEFAULT_MAX_LINES = 1000
```

**行为**：未指定 `end_line` 时只显示 1000 行，超过则追加 `(Showing lines X-Y of Z total. Use start_line=...)` 提示。

#### d) `listFiles(..., 200)` - list_files 文件数限制

**文件**：`apps/vscode/src/core/task/tools/handlers/ListFilesToolHandler.ts:100`

```typescript
;[files, didHitLimit] = await listFiles(absolutePath, recursive, 200)
```

**行为**：单次 list_files 最多返回 200 个文件/目录。

#### e) 文本文件 20MB 硬限制

**文件**：`apps/vscode/src/integrations/misc/extract-text.ts:66-69`

```typescript
if (fileStat.size > 20 * 1000 * 1024) {
    throw new Error(`File is too large to read into context.`)
}
```

**行为**：超过 20MB **直接拒绝读取**（不截断，直接报错）。

#### f) Excel 行级截断

**文件**：`apps/vscode/src/integrations/misc/extract-text.ts:162-165`

```typescript
worksheet.eachRow({ includeEmpty: false }, (row, rowNumber) => {
    if (rowNumber > 50000) {
        excelText += `[... truncated at row ${rowNumber} ...]\n`
        return false
    }
    // ...
})
```

**行为**：每个 Sheet 最多处理 50000 行。

### 11.5.4 没有截断的工具

| 工具 | 行为 | 备注 |
|------|------|------|
| `execute_command` | 命令输出原样返回 | 30s/300s 超时 |
| `web_fetch` | 后端服务控制 | handler 不截断 |
| `search_files` | ripgrep 输出原样 | 无明确上限 |
| `list_code_definition_names` | 完整结果 | - |
| `web_search` | 完整结果 | - |
| `ask_followup_question` | 用户输入 | - |
| `attempt_completion` | 完成标记 | - |
| `write_to_file` / `replace_in_file` / `apply_patch` | 写入操作 | 无输出截断 |

### 11.5.5 Subagent 内部三层截断机制

Subagent 涉及**三层**截断/压缩机制（详见 `SubagentRunner.ts`）：

| 层级 | 位置 | 阈值 | 触发时机 |
|------|------|------|----------|
| **第 1 层** | `SubagentToolHandler.excerpt()` | 默认无上限（`Number.MAX_SAFE_INTEGER`） | subagent 完成返回结果给主 agent |
| **第 2 层** | `SubagentRunner.shouldCompactBeforeNextRequest()` | 75% context window (next-gen) / `maxAllowedSize` | 每次 LLM 请求前 |
| **第 3 层** | `SubagentRunner.createMessageWithInitialChunkRetry()` | "quarter" 模式删除 25% 消息 | API 返回 context window exceeded 错误时 |

### 11.5.6 Subagent 用户规则注入（★ 新增特性）

**支持状态**：✅ 已实现（source: `SubagentRunner.ts:365-399`, `PromptBuilder.ts`）

**机制**：Subagent 的 system prompt 同样通过 `PromptRegistry` 构建，`componentOrder` 中包含 `USER_INSTRUCTIONS_SECTION`，因此用户规则（`.clinerules/`, `.cursorrules`, `.agents/AGENT.md`, `.clineignore` 等）**自动注入到 subagent 的 system prompt** 中。

**注入路径**：

```
SubagentRunner.run()
  → getGlobalClineRules() / getLocalClineRules() / clineIgnoreContent   ← 规则加载
  → SystemPromptContext { isSubagentRun: true }                          ← 标记 subagent
  → PromptRegistry.get(context) → PromptBuilder.build()
      → componentOrder 包含 USER_INSTRUCTIONS
          → user_instructions.ts 不加区分地加载规则
  → SubagentBuilder.buildSystemPrompt(generatedSystemPrompt)            ← 追加 identity + suffix
```

**关键事实**：
- 无 `isSubagentRun` 过滤：`user_instructions.ts`、`rules.ts`、`PromptBuilder.ts` **都不检查** `isSubagentRun` 来排除规则
- 因此 subagent 的 system prompt 结构与主 agent 几乎一致（仅通过 `SUBAGENT_SYSTEM_SUFFIX` 区分角色）
- 这意味着团队可以通过 `.clinerules/` 为 subagent 也强制编码规范、行为约束

### 11.5.8 与 ContextManager 的协同

Tool handler 层的截断是**第一道防线**，ContextManager 层的处理是**第二道防线**：

```
Tool 执行结果
    ↓
Tool handler 内部截断（如 400KB / 1000 行 / 200 文件）  ← 第一道防线
    ↓
返回到 LLM 的 messages 数组
    ↓
ContextManager 每轮处理（file read 去重 / 截断）      ← 第二道防线
    ↓
最终发给 LLM API
```

**互补关系**：
- Tool handler 层：按工具特性定制（如 read_file 按行截断，list_files 按数量）
- ContextManager 层：统一处理所有消息（去重 + 截断）

### 11.5.9 关键源码索引

| 主题 | 文件 |
|------|------|
| 全局内容限制 | `apps/vscode/src/shared/content-limits.ts` |
| read_file handler | `apps/vscode/src/core/task/tools/handlers/ReadFileToolHandler.ts` |
| read_file 文本提取 | `apps/vscode/src/integrations/misc/extract-file-content.ts` |
| 文本/PDF/DOCX/Excel 提取 | `apps/vscode/src/integrations/misc/extract-text.ts` |
| subagent handler | `apps/vscode/src/core/task/tools/handlers/SubagentToolHandler.ts` |
| subagent 执行 | `apps/vscode/src/core/task/tools/subagent/SubagentRunner.ts` |
| list_files handler | `apps/vscode/src/core/task/tools/handlers/ListFilesToolHandler.ts` |
| MCP tool handler | `apps/vscode/src/core/task/tools/handlers/UseMcpToolHandler.ts` |
| MCP resource handler | `apps/vscode/src/core/task/tools/handlers/AccessMcpResourceHandler.ts` |
| ContextManager | `apps/vscode/src/core/context/context-management/ContextManager.ts` |

---

*本节整合自 `DevelopmentRecord/subagent输出截断取消实现.md` 调研结果*
