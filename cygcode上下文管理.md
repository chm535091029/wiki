# 每轮对话完整提示词样式与上下文管理（基于代码分析 v2）

> 本文档基于对 `/apps/vscode/src/core/task/index.ts`、`/apps/vscode/src/core/context/`、`/apps/vscode/src/core/prompts/system-prompt/`、`/apps/vscode/src/core/slash-commands/`、`/apps/vscode/src/core/prompts/contextManagement.ts` 等核心代码逐行解析，还原 **每轮 LLM API 调用** 时的完整消息结构、上下文管理机制、Token 截断策略。

---

## 〇、整体上下文管理架构（核心）

每轮 API 调用并不是简单的「system + 历史 messages」拼接，而是一套**多阶段、多层缓存、按模型动态重建**的精密流水线。整体架构如下：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Task 启动层                                        │
│                                                                             │
│  startTask(task, images, files)                                             │
│     ├── 初始化 ClineIgnoreController                                        │
│     ├── 清空 apiConversationHistory / clineMessages                         │
│     ├── say("task", task, images, files)              [写入 UI 消息]          │
│     ├── 构建 userContent: [<task>...</task>, <file_content>...]              │
│     ├── Hook: TaskStart (project hook 注入 contextModification)             │
│     ├── Hook: UserPromptSubmit (project hook 注入 contextModification)      │
│     └── initiateTaskLoop(userContent)                                       │
│                                                                             │
│  resumeTaskFromHistory()                                                    │
│     ├── 加载 savedClineMessages (UI 展示)                                   │
│     ├── 加载 savedApiConversationHistory (给 LLM)                            │
│     ├── contextManager.initializeContextHistory(taskDir)                    │
│     ├── 弹出 ask("resume_task" / "resume_completed_task")                    │
│     ├── Hook: TaskResume                                                    │
│     └── initiateTaskLoop(newUserContent)                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                      任务循环层（每轮一次）                                  │
│                                                                             │
│  initiateTaskLoop (while !abort)                                            │
│     └── recursivelyMakeClineRequests(userContent, includeFileDetails)       │
│            ├── [1] 决定是否需要 shouldCompact（auto-condense 判断）          │
│            ├── [2] loadContext()  →  mentions 解析 + slash commands 解析    │
│            ├── [3] 构建 userContent 末尾 3 段:                              │
│            │       ├── environmentDetails                                   │
│            │       ├── detectedWorkflowInstructions (workflow 触发时)        │
│            │       └── <workflow_execution_override> (workflow 触发时)        │
│            ├── [4] shouldCompact ? 追加 summarizeTask 提示                   │
│            ├── [5] addToApiConversationHistory(userContent)                  │
│            ├── [6] attemptApiRequest(previousApiReqIndex)                   │
│            └── [7] 处理响应 / tool / resumeTaskFromHistory 循环              │
└─────────────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│              attemptApiRequest（核心：每轮完整 prompt 构建）                │
│                                                                             │
│  attemptApiRequest(previousApiReqIndex)                                     │
│     ├── [A] 加载 Rules 全部内容（7 类规则 + LAZY_TEAMMATE_RULES）           │
│     │       getGlobalClineRules / getLocalClineRules                        │
│     │       getLocalCursorRules / getLocalWindsurfRules / getLocalAgentsRules│
│     ├── [B] 加载 clineIgnoreInstructions                                    │
│     ├── [C] 准备 multiRoot workspaceRoots                                   │
│     ├── [D] discoverAvailableSkills() — 3 层优先级合并                       │
│     ├── [E] 快照 editorTabs (open + visible, cap=50)                        │
│     ├── [F] 构建 promptContext  →  getSystemPrompt(promptContext)           │
│     │       ├── PromptRegistry.get(context) → 选 variant                     │
│     │       ├── PromptBuilder.build()                                       │
│     │       │   ├── buildComponents() → 并行执行各 component fn             │
│     │       │   ├── preparePlaceholders(componentSections)                  │
│     │       │   ├── templateEngine.resolve(baseTemplate, ...)               │
│     │       │   └── postProcess(prompt)  // 清理空行、空 section              │
│     │       └── 返回 { systemPrompt, tools }                                │
│     ├── [G] writePromptMetadataArtifacts (CLINE_WRITE_PROMPT_ARTIFACTS)      │
│     ├── [H] contextManager.getNewContextMessagesAndMetadata(...)            │
│     │       ├── 检测 token 阈值 → 触发 file read 优化 / truncation          │
│     │       ├── getAndAlterTruncatedMessages  → 截断 + 替换 duplicated reads│
│     │       └── 返回 { truncatedConversationHistory, deletedRange }         │
│     ├── [I] stream = api.createMessage(systemPrompt, msgs, tools)            │
│     └── [J] yield chunk  // streaming 给到上层                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                  ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                     ContextManager（消息裁剪层）                            │
│                                                                             │
│  shouldCompactContextWindow:                                                │
│     └── 判断上一轮 api_req_started 的 totalTokens ≥ maxAllowedSize           │
│                                                                             │
│  getNextTruncationRange:                                                    │
│     ├── "none"      → 删除所有中间消息                                       │
│     ├── "lastTwo"   → 仅保留首尾 user-assistant pair                         │
│     ├── "half"      → 删除一半 user-assistant pair                          │
│     └── "quarter"   → 删除 3/4  pair（context 超限或 auto-condense 强制）    │
│                                                                             │
│  applyContextOptimizations:                                                  │
│     ├── getPossibleDuplicateFileReads → 找重复 read_file / write_to_file    │
│     ├── applyFileReadContextHistoryUpdates                                 │
│     │   ├── READ_FILE_TOOL     → 替换为 duplicateFileReadNotice              │
│     │   ├── ALTER_FILE_TOOL    → 替换 final_file_content 内文                │
│     │   └── FILE_MENTION       → 替换 <file_content> 块为 notice              │
│     └── applyContextHistoryUpdates → 应用所有 in-memory text 替换            │
│                                                                             │
│  applyStandardContextTruncationNoticeChange:                                │
│     ├── 替换 index=0 第一条 user message 为 processFirstUserMessageFor...    │
│     └── 在 index=1 assistant message 顶部插入 contextTruncationNotice        │
└─────────────────────────────────────────────────────────────────────────────┘
```

**关键事实**：
- System Prompt **每轮 API 调用前都完整重建**（不缓存，但每个 component 内部可以缓存）
- 规则 / 技能 / 文件清单 / 终端状态等 **每轮都重新读取**（保证实时性）
- 消息历史裁剪 + file read 去重 **每轮决策一次**（基于上一轮 token 报告）
- 所有 user content 都在 `addToApiConversationHistory` 之前追加到 `userContent` 数组

---

## 〇.五、最终模板构成速查（简图）

> 本节是后续章节（§二 System Prompt、§三 User Message）的可视化浓缩，便于一眼看清每轮 LLM 调用时的「完整拼图」。所有顺序、条件均严格按源码行为还原。

### 1. System Prompt 最终结构（generic variant，按 `componentOrder` 顺序）

```
┌──────────────────────────────────────────────────────────────────┐
│  System Prompt = baseTemplate + 占位符替换 + postProcess         │
│  （由 PromptBuilder.build() 按 componentOrder 串行执行）         │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ ① {{AGENT_ROLE}}      "You are Cyg Code, a highly        │  │
│  │                        skilled software engineer..."       │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ② {{TOOL_USE}}        # Tools + 所有可用工具的参数/用法   │  │
│  │                        （XML 标签调用格式）                  │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ③ {{TASK_PROGRESS}}   task_progress 参数使用说明           │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ④ {{MCP}}             [条件] 存在已连接 MCP server 时出现  │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑤ {{EDITING_FILES}}   write_to_file / replace_in_file     │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑥ {{ACT_VS_PLAN}}     ACT MODE vs PLAN MODE 区分          │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑦ {{CAPABILITIES}}    工具能力清单                         │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑧ {{SKILLS}}          [条件] context.skills.length > 0    │  │
│  │                        仅元数据（name + description）       │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑨ {{FEEDBACK}}        /reportbug + 回答策略               │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑩ {{RULES}}           CWD / 工具约束 / CLI / browser 规则 │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑪ {{SYSTEM_INFO}}     OS / IDE / Shell / 工作目录         │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑫ {{OBJECTIVE}}       任务执行原则                         │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │ ⑬ {{USER_INSTRUCTIONS}} 8 类规则按固定顺序拼接             │  │
│  │   ├─ preferredLanguage                                     │  │
│  │   ├─ globalClineRules  (.clinerules/)                       │  │
│  │   ├─ localClineRules   (.clinerules/)                       │  │
│  │   ├─ localCursorRules  (.cursorrules)                       │  │
│  │   ├─ localCursorRulesDir (.cursor/rules/)                   │  │
│  │   ├─ localWindsurfRules (.windsurfrules)                    │  │
│  │   ├─ localAgentsRules   (.agents/AGENT.md)                  │  │
│  │   └─ clineIgnoreInstructions (.clineignore)                 │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  拼接引擎：每个 component 独立函数，串行执行；空 component 会被    │
│  postProcess 清理掉；占位符替换不区分大小小节分隔符（====）。      │
└──────────────────────────────────────────────────────────────────┘
```

### 2. User Message 最终结构（每轮 userContent 数组，按追加顺序）

```
┌──────────────────────────────────────────────────────────────────┐
│  userContent: ClineUserContent[]                                  │
│  （由 loadContext → recursivelyMakeClineRequests 构建）          │
│                                                                  │
│  ┌─ A. 基础内容（startTask / ask 响应阶段注入）────────────────┐ │
│  │  • <task>{原始任务}</task>            首轮：startTask       │ │
│  │  • <user_message>{...}</user_message> 非首轮：ask 响应      │ │
│  │  • <file_content path="...">          processFilesIntoText  │ │
│  │  • <image> base64                     用户拖入图片          │ │
│  │  • <hook_context source="TaskStart">     hook 注入         │ │
│  │  • <hook_context source="UserPromptSubmit">                 │ │
│  │  • <hook_context source="TaskResume">  resume 任务时       │ │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ B. parseTextBlock 处理（loadContext 中执行）───────────────┐ │
│  │  • @file: → 替换为 <file_content path="...">               │ │
│  │  • /cmd  → 移除命令、保留参数、可能匹配 workflow            │ │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ C. 每轮追加（recursivelyMakeClineRequests 末尾）──────────┐ │
│  │  ★ 1. <environment_details>...（仅 Current Mode） [精简]  │ │
│  │       ├─ # Current Mode（ACT / PLAN + planModeInstructions）│ │
│  │       └─ {可选: # Workspace Roots（multi-root 时）}         │ │
│  │  ★ 2. [Focus Chain todo list]          [条件: interval/切换] │ │
│  │       ├─ 当前进度 + checklist 内容                           │ │
│  │       ├─ 结果标注提示                                        │ │
│  │       └─ 参考 rules/skills/workflows 提示                    │ │
│  │  ★ 3. <explicit_instructions                                │ │
│  │       type="<workflow>" priority="override"> [条件] 独立注入 │ │
│  │  ★ 4. <workflow_execution_override> [条件] 模型回复前最后一条│ │
│  │  ★ 5. <explicit_instructions                                │ │
│  │       type="summarize_task">   [条件] auto-condense 触发   │ │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ─────────────────────────────────────────────────────────────   │
│  追加完毕 → addToApiConversationHistory()                       │
│         → ContextManager 截断 + 去重                            │
│         → api.createMessage()                                   │
└──────────────────────────────────────────────────────────────────┘
```

### 3. 最终 API 调用形态（三参数一览）

```
   ┌────────────────────────────────────────────────────────────┐
   │  api.createMessage(systemPrompt, messages, tools?)         │
   │         ▲                  ▲          ▲                    │
   │         │                  │          └─ [可选] 原生 tools  │
   │         │                  │             （仅 enable-       │
   │         │                  │              NativeToolCalls）  │
   │         │                  │                               │
   │         │                  └─ truncatedConversationHistory │
   │         │                     （ContextManager 处理后：     │
   │         │                      • file read 去重            │
   │         │                      • 旧版截断 / auto-condense   │
   │         │                      • tool_use/result 配对修复）│
   │         │                                                  │
   │         └─ 完整重建的 system prompt（见 §1）               │
   └─────────────────────────────────────────────────────────────┘
```

### 4. 一图流速记（最简版）

```
┌──────────── System (string) ─────────────────────────────────┐
│ AGENT_ROLE → TOOL_USE → TASK_PROGRESS → MCP?               → │
│ EDITING_FILES → ACT_VS_PLAN → CAPABILITIES → SKILLS?       → │
│ FEEDBACK → RULES → SYSTEM_INFO → OBJECTIVE                 → │
│ USER_INSTRUCTIONS（8 类规则按固定顺序拼接）                  │
└─────────────────────────────────────────────────────────────┘

┌──────────── Messages (array) ───────────────────────────────┐
│ [历史 messages]（ContextManager 截断 + 去重后）              │
│ + 当前 userContent：                                        │
│   <task>/<user_message> → [files/images] → [hooks]          │
│   → [parseMentions/slash]                                   │
│   → <environment_details> ★每轮                            │
│   → [workflow instructions]                                │
│   → [summarize instructions]                               │
└─────────────────────────────────────────────────────────────┘

┌──────────── Tools (array, 可选) ────────────────────────────┐
│ ClineToolSet.getEnabledToolSpecs()                          │
│ （按 variant + contextRequirements 动态过滤）                │
└─────────────────────────────────────────────────────────────┘
```

**关键提示（一眼记住几个不显然的事实）**：

- System Prompt 顺序由 **`componentOrder`** 决定（**不是** components 注册顺序），不同 variant 不同
- `USER_INSTRUCTIONS` 是用户自定义规则**唯一**注入位置（8 类按固定顺序拼接）
- **Workflows 不**进入 System Prompt，而是通过 `<explicit_instructions>` 进入 user message
- **Skills 只**有元数据进入 System Prompt，详细指令在 LLM 调 `use_skill` 工具后才进入 messages
- `<environment_details>` **每轮**追加（其中 CWD Files 仅首轮）
- ContextManager 在 messages 阶段做去重和截断，**不影响** system
- `enableNativeToolCalls` 开启时多出 `tools` 数组（与 XML 工具调用互斥）

---

## 一、整体消息结构

每轮 API 调用包含两部分：

```ts
const stream = api.createMessage(systemPrompt, truncatedConversationHistory, tools)
```

1. **`system` (string)** — 由 `getSystemPrompt(promptContext)` 生成，**每轮重新构建**
2. **`messages` 数组** — 由 `contextManager.getNewContextMessagesAndMetadata()` 截断后的 `apiConversationHistory` + 刚追加的当前 `userContent`
3. **`tools` 数组**（可选）— 仅当 `enableNativeToolCalls=true` 时存在（OpenAI Responses API 等），内容来自 `ClineToolSet.getEnabledToolSpecs()`

---

## 二、System Prompt 完整拼装（Variant 模板引擎）

### 2.1 模板基座

以 generic variant 为例（`apps/vscode/src/core/prompts/system-prompt/variants/generic/template.ts`）：

```typescript
export const baseTemplate = `{{${SystemPromptSection.AGENT_ROLE}}}

{{${SystemPromptSection.TOOL_USE}}}

====

{{${SystemPromptSection.TASK_PROGRESS}}}

====

{{${SystemPromptSection.MCP}}}

====

{{${SystemPromptSection.EDITING_FILES}}}

====

{{${SystemPromptSection.ACT_VS_PLAN}}}

====

{{${SystemPromptSection.CAPABILITIES}}}

====

{{${SystemPromptSection.SKILLS}}}

====

{{${SystemPromptSection.FEEDBACK}}}

====

{{${SystemPromptSection.RULES}}}

====

{{${SystemPromptSection.SYSTEM_INFO}}}

====

{{${SystemPromptSection.OBJECTIVE}}}

====

{{${SystemPromptSection.USER_INSTRUCTIONS}}}`
```

**关键点**：
- `{{SECTION}}` 是 `TemplateEngine.resolve()` 替换的占位符
- 不同 variant 拥有不同 `baseTemplate` 和 `componentOrder`
- 实际生效顺序由 `componentOrder` 决定（不是 `components` 注册顺序）
- 实际看到的 generic variant `componentOrder`（`config.ts`）：`AGENT_ROLE → TOOL_USE → TASK_PROGRESS → MCP → EDITING_FILES → ACT_VS_PLAN → CAPABILITIES → RULES → SYSTEM_INFO → OBJECTIVE → USER_INSTRUCTIONS → SKILLS`

### 2.2 拼装流程（`PromptBuilder.build()`）

```typescript
// apps/vscode/src/core/prompts/system-prompt/registry/PromptBuilder.ts
async build(): Promise<string> {
  const componentSections = await this.buildComponents()        // ① 逐个调用 component fn
  const placeholderValues = this.preparePlaceholders(componentSections)  // ② 合并占位符
  const prompt = this.templateEngine.resolve(
    this.variant.baseTemplate, this.context, placeholderValues
  )                                                            // ③ 替换占位符
  return this.postProcess(prompt)                              // ④ 清理空行/空 section
}
```

`buildComponents()` 对 `componentOrder` 中的每个 section 顺序执行 `components[id](variant, context)`，**串行执行**。每个 component 是独立函数，返回 string 或 undefined。空 component 不会写入最终 prompt。

`preparePlaceholders()` 合并三类占位符：
1. `variant.placeholders`（variant 自定义）
2. 标准占位符（`STANDARD_PLACEHOLDERS`）：`CWD`, `SUPPORTS_BROWSER`, `MODEL_FAMILY`, `CURRENT_DATE`
3. 所有 `componentSections` 自身
4. `runtimePlaceholders`（如果 context 提供，最高优先级）

### 2.3 关键组件（Component）内容

#### 2.3.1 `{{AGENT_ROLE_SECTION}}`（`agent_role.ts`）
```typescript
const AGENT_ROLE = [
  "You are Cyg Code,",
  "a highly skilled software engineer",
  "with extensive knowledge in many programming languages, frameworks, design patterns, and best practices.",
]
```

#### 2.3.2 `{{TOOL_USE_SECTION}}`（`components/tool_use/index.ts`）
- TOOL USE 标题
- 工具使用格式说明（XML 标签）
- `# Tools` 下包含**全部**可用工具的详细参数、用法

工具定义在 `components/tool_use/tools.ts`，每个工具包含：
- `## {tool_name}` 标题
- `Description: ...` 描述
- `Parameters:` 每个参数的 `(required|optional) {instruction}`
- `Usage: <{tool_name}>...<{param}>value</{param}>...</{tool_name}>`

#### 2.3.3 `{{MCP_SECTION}}`（`mcp.ts`）
仅当 `mcpHub.getServers().length > 0` 且至少一个 server `status === "connected"` 时出现：
```
MCP SERVERS
The Model Context Protocol (MCP) enables communication between the system and locally running MCP servers...

# Connected MCP Servers

When a server is connected, you can use the server's tools via the `use_mcp_tool` tool, and access the server's resources via the `access_mcp_resource` tool.

Servers may also provide prompts - predefined templates that can be invoked by users to generate contextual messages.

## server-name (`command args`)
### Available Tools
- tool_name: description
  Input Schema: ...
### Resource Templates
- uriTemplate (name): description
### Direct Resources
- uri (name): description
### Available Prompts
- prompt_name (title): description
    Arguments: name (required): description, ...
```

#### 2.3.4 `{{EDITING_FILES_SECTION}}`（`editing_files.ts`）
固定文本，描述 `write_to_file` 与 `replace_in_file` 的使用场景和 SEARCH/REPLACE 格式。

#### 2.3.5 `{{ACT_VS_PLAN_SECTION}}`（`act_vs_plan_mode.ts`）
固定文本，区分 ACT MODE 和 PLAN MODE 的工具可用性、切换方式。

#### 2.3.6 `{{CAPABILITIES_SECTION}}`（`capabilities.ts`）
固定文本，描述 LLM 拥有的工具能力（execute_command、search_files、list_code_definition_names、list_files、read_file、write_to_file、replace_in_file、access_mcp_resource、MCP servers 等）。

#### 2.3.7 `{{SKILLS_SECTION}}`（`skills.ts`）
仅当 `context.skills.length > 0` 时出现：
```
SKILLS

The following skills provide specialized instructions for specific tasks. When a user's request matches a skill description, use the use_skill tool to load and activate the skill.

Available skills:
  - "skill-name-1": description of skill
  - "skill-name-2": description of skill

To use a skill:
1. Match the user's request to a skill based on its description
2. Call use_skill with the skill_name parameter set to the exact skill name
3. Follow the instructions returned by the tool
```

**仅含元数据（name + description）**，实际指令通过 `use_skill` 工具运行时加载到 messages。

#### 2.3.8 `{{FEEDBACK_SECTION}}`（`feedback.ts`）
固定文本，引导用户通过 `/reportbug` 反馈问题，以及如何回答关于 Cyg Code 的提问。

#### 2.3.9 `{{RULES_SECTION}}`（`rules.ts`）
固定框架文本 + 动态占位符 `{CWD, BROWSER_RULES, CLI_RULES}`。**注意：RULES_SECTION 不包含 cline rules 内容**，那是 USER_INSTRUCTIONS_SECTION 的事。RULES_SECTION 主要是：
- CWD 工作目录与 cd 限制
- search_files、replace_in_file 等工具使用约束
- browser 工具使用规则（条件渲染）
- CLI 环境规则（条件渲染）
- 通用代码风格与对话规范
- "NEVER end attempt_completion result with a question"
- 文件外部修改提醒

#### 2.3.10 `{{SYSTEM_INFO_SECTION}}`（`system_info.ts`）
```
SYSTEM INFORMATION

Operating System: {os}
IDE: {ide}
Default Shell: {shell}
Home Directory: {homeDir}
Current Working Directory: {workingDir}    # 或多 root 模式下显示所有根
```

多 root 模式下替换为 `Workspace Roots: ...` + `Primary Working Directory: ...`

#### 2.3.11 `{{OBJECTIVE_SECTION}}`（`objective.ts`）
固定的 6-7 条任务执行原则，详见 `objective.ts`。

#### 2.3.12 `{{USER_INSTRUCTIONS_SECTION}}`（`user_instructions.ts`）
**这是 CygCode 中**用户自定义规则**真正注入的地方**。模板：
```
USER'S CUSTOM INSTRUCTIONS

IMPORTANT: The following instructions OVERRIDE any default behavior. You MUST follow them exactly as written.

<所有非空指令按以下顺序拼接，每个用 \n\n 分隔>
```

拼接顺序（来自 `buildUserInstructions()`）：
1. `preferredLanguageInstructions`（首选语言）
2. `globalClineRulesFileInstructions`（全局 .clinerules/）
3. `localClineRulesFileInstructions`（本地 .clinerules/）
4. `localCursorRulesFileInstructions`（.cursorrules）
5. `localCursorRulesDirInstructions`（.cursor/rules/）
6. `localWindsurfRulesFileInstructions`（.windsurfrules）
7. `localAgentsRulesFileInstructions`（.agents/AGENT.md）
8. `clineIgnoreInstructions`（.clineignore）

#### 2.3.13 `{{TASK_PROGRESS_SECTION}}`（`task_progress.ts`）

**定义文件**：`apps/vscode/src/core/prompts/system-prompt/components/task_progress.ts`

**门控条件**：仅当 `context.focusChainSettings?.enabled === true` 时输出（第 67 行），否则返回 `undefined`，该 section 完全从 System Prompt 中消失。

**内容性质**：该 section 是**静态的使用说明文本**，教导 AI 如何使用 `task_progress` 参数（格式规范、使用时机、Markdown 示例）。**不包含任何实际的进度数据**。

有三种变体（差异细微）：
- `UPDATING_TASK_PROGRESS`（generic 版本）
- `UPDATING_TASK_PROGRESS_NATIVE_NEXT_GEN`
- `UPDATING_TASK_PROGRESS_NATIVE_GPT_5`

**⚠️ 重要区分**：此 System Prompt section 只负责解说 `task_progress` 参数的用法。实际的**进度数据（todo list 内容）** 是通过 `FocusChainManager` 在 `loadContext()` 阶段注入到 **User Message** 中的，而非 System Prompt（详见 §3.6）。

### 2.4 Rules 各子项的格式化样式

#### a) `globalClineRulesFileInstructions` / `localClineRulesFileInstructions`

`getGlobalClineRules` / `getLocalClineRules` 调用 `getRuleFilesTotalContentWithMetadata` 加载内容，格式：

```
# .clinerules/

The following is provided by a [global|root-level] .clinerules[/] [directory|file], located at {path}, where the user has specified instructions:

<相对于 rules 目录的文件路径>
<文件的 body 内容（去除 YAML frontmatter 后）>

<另一个文件路径>
<另一个文件的内容>
...
```

**重要细节**：
- 单文件格式：`formatResponse.clineRulesLocalFileInstructions(cwd, body)` 输出
- 目录格式：`formatResponse.clineRulesLocalDirectoryInstructions(cwd, content)` 输出
- 全局目录格式：`formatResponse.clineRulesGlobalDirectoryInstructions(globalClineRulesFilePath, combinedContent)` 输出
- YAML frontmatter 通过 `parseYamlFrontmatter()` 解析，**解析错误 fail-open**（保留原文）
- 条件规则（YAML `paths:` 等）通过 `evaluateRuleConditionals()` 评估，匹配后才包含
- `activatedConditionalRules` 记录触发的条件规则，通过 `say("conditional_rules_applied", ...)` 通知用户

**目录扫描排除列表**（`cline-rules.ts:94-98`）：
- `.clinerules/workflows/`（workflows 单独管理）
- `.clinerules/hooks/`（hooks 单独管理）
- `.clinerules/skills/`（skills 单独管理）

**目录扫描的拼接规则**（`rule-helpers.ts`）：
```typescript
content = parts
  .map((p) => p.contentPart)  // 每个文件: `${ruleFilePathRelative}\n${body.trim()}`
  .filter(Boolean)
  .join("\n\n")
```

#### b) `localCursorRulesFileInstructions`（`.cursorrules`）
```
# .cursorrules

The following is provided by a root-level .cursorrules file where the user has specified instructions for this working directory ({cwd}):

<.cursorrules 文件内容>
```

#### c) `localCursorRulesDirInstructions`（`.cursor/rules/`）
```
# .cursor/rules

The following is provided by a root-level .cursor/rules directory where the user has specified instructions for this working directory ({cwd}):

<递归目录下所有规则文件内容>
```

#### d) `localWindsurfRulesFileInstructions`（`.windsurfrules`）
```
# .windsurfrules

The following is provided by a root-level .windsurfrules file where the user has specified instructions for this working directory ({cwd}):

<.windsurfrules 文件内容>
```

#### e) `localAgentsRulesFileInstructions`（`.agents/AGENT.md`）
⚠️ **当前 CygCode 实际是单文件模式**（代码验证版）：
```
# .agents/AGENT.md

The following is provided by the .agents/AGENT.md file in this working directory ({cwd}) where the user has specified instructions. You should apply these instructions when working on files in this directory.

<.agents/AGENT.md 文件内容>
```

> **原文档描述的"递归找所有嵌套 AGENTS.md"在该实现版本不成立**——`getLocalAgentsRules` 实际只读取项目根目录的 `.agents/AGENT.md`（`external-rules.ts`）。原版本的相关描述（`agentsRulesLocalFileInstructions` 旧版字符串）已被注释掉：
> ```typescript
> // === 原代码（保留） ===
> // agentsRulesLocalFileInstructions: (cwd: string, content: string) =>
> //     `# AGENTS.md\n\nThe following is provided by AGENTS.md files found recursively...`
>
> // === 新代码：修正描述，避免 AI 自行递归查找根目录的 AGENTS.md ===
> agentsRulesLocalFileInstructions: ...
> ```

#### f) `clineIgnoreInstructions`（`.clineignore`）
```
# .clineignore

(The following is provided by a root-level .clineignore file where the user has specified files and directories that should not be accessed. When using list_files, you'll notice a 🔒 next to files that are blocked. Attempting to access the file's contents e.g. through read_file will result in an error.)

<被忽略的路径列表>
.clineignore
```

#### g) `preferredLanguageInstructions`
```
# Preferred Language

Speak in {languageKey}.
```

> 由 `attemptApiRequest()` 中的 `preferredLanguageInstructions` 变量生成（line 1980-1985）。仅在 `preferredLanguage !== DEFAULT_LANGUAGE_SETTINGS` 时非空。

#### h) LAZY_TEAMMATE_RULES（懒人队友模式）
当 `lazyTeammateModeEnabled === true` 时，会被追加到 `globalClineRulesFileInstructions` 末尾（`task/index.ts:2004-2010`）。

---

## 三、User Message 包装格式

### 3.1 首轮消息（`startTask`）

```typescript
// task/index.ts:1090-1106
const userContent: ClineUserContent[] = [
  { type: "text", text: `<task>\n${task}\n</task>` },
  ...imageBlocks,
]
// 如果有 files:
if (files && files.length > 0) {
  const fileContentString = await processFilesIntoText(files)
  if (fileContentString) {
    userContent.push({ type: "text", text: fileContentString })
  }
}
```

首轮 user message 的完整结构（在 `recursivelyMakeClineRequests` 经过 `loadContext` 处理后）：
```
[
  { type: "text", text: "<task>\n{用户原始任务文本}\n</task>" },
  { type: "text", text: "<file_content path='path1'>\n...内容...\n</file_content>\n<file_content path='path2'>..." },  // 可选
  { type: "image", source: { type: "base64", media_type: "...", data: "..." } },  // 可选
  { type: "text", text: "<hook_context source=\"TaskStart\">\n{hook 注入的 context}\n</hook_context>" },  // 可选
  { type: "text", text: "<hook_context source=\"UserPromptSubmit\">\n{hook 注入的 context}\n</hook_context>" },  // 可选
  { type: "text", text: "{processContentBlock 后的文本}" },  // mentions 解析、slash command 替换后
  { type: "text", text: "{environmentDetails}" },  // ★ 每轮追加
  { type: "text", text: "{detectedWorkflowInstructions}" },  // ★ workflow 触发时
  { type: "text", text: "<workflow_execution_override>\nCRITICAL: ...\n</workflow_execution_override>" },  // ★ workflow 触发时
  { type: "text", text: "{summarizeTask(...)}" },  // ★ shouldCompact 时
]
```

### 3.2 Hook 注入上下文（`TaskStart` / `UserPromptSubmit` / `TaskResume`）

`startTask` 调用顺序：
1. **TaskStart hook**：项目级 hook，可返回 `contextModification` 注入到 user message
2. **UserPromptSubmit hook**：项目级 hook，可返回 `contextModification` 注入到 user message
3. **环境追踪**：`environmentContextTracker.recordEnvironment()`

**关键代码**（`task/index.ts:1108-1182`）：
```typescript
if (hooksEnabled) {
  const taskStartResult = await executeHook({ hookName: "TaskStart", ... })
  if (taskStartResult.contextModification) {
    userContent.push({ type: "text", text: `<hook_context source="TaskStart">\n${contextText}\n</hook_context>` })
  }
}
const userPromptHookResult = await this.runUserPromptSubmitHook(userContent, "initial_task")
if (userPromptHookResult.contextModification) {
  userContent.push({ type: "text", text: `<hook_context source="UserPromptSubmit">\n${contextModification}\n</hook_context>` })
}
```

### 3.3 `loadContext` 阶段：mentions 解析 + slash commands 处理

**`loadContext` 是每轮 user content 构建的关键**（`task/index.ts:3438-3576`）：

```typescript
async loadContext(userContent, includeFileDetails, useCompactPrompt) {
  // 1. 准备 workflow toggles（从 .clinerules/workflows/ 和 ~/.cline/workflows/ 扫描）
  const { localWorkflowToggles, globalWorkflowToggles } = await refreshWorkflowToggles(this.controller, cwd)

  // 2. 对每个 text content block 调 parseTextBlock:
  const parseTextBlock = async (text: string) => {
    const parsedText = await parseMentions(text, cwd, ...)        // @file: 提及解析
    const slashResult = await parseSlashCommands(
      parsedText,
      localWorkflowToggles, globalWorkflowToggles, ulid, ...
    )                                                              // /command 处理
    return slashResult.processedText
  }

  // 3. 遍历 userContent，对 text/tool_result 中的 text 调 parseTextBlock

  // 4. 并行执行: 解析 userContent + getEnvironmentDetails(includeFileDetails)
  const [processedUserContent, environmentDetails] = await Promise.all([
    Promise.all(userContent.map(processContentBlock)),
    this.getEnvironmentDetails(includeFileDetails),
  ])

  // 5. 添加 focus chain 指令
  if (this.FocusChainManager?.shouldIncludeFocusChainInstructions()) {
    processedUserContent.push({ type: "text", text: focusChainInstructions })
  }

  return [processedUserContent, environmentDetails, clinerulesError, workflowName, workflowInstructions]
}
```

**`parseMentions` 触发条件**：仅当 text block 包含 `USER_CONTENT_TAGS`（`<task>`, `<feedback>`, `<answer>`, `<user_message>`）时处理。

**`parseSlashCommands` 优先级**（`slash-commands/index.ts`）：
1. 内置命令：`newtask` / `smol` / `compact` / `newrule` / `reportbug` / `deep-planning` / `explain-changes`
2. MCP prompt 命令：`/mcp:<server>:<prompt>` → 通过 `mcpPromptFetcher` 抓取
3. Workflows：local > global > remote（按 fileName 匹配）

**Workflow 触发格式**（`slash-commands/index.ts:231`）：
```typescript
const workflowInstructions = `<explicit_instructions type="${matchingWorkflow.fileName}" priority="override">\n${workflowContent}\n</explicit_instructions>`
```

### 3.4 环境信息 `environment_details` —— "精简模式"（★ 已精简）

**当前环境**（2026-06-17 精简优化）：`getEnvironmentDetails`（`task/index.ts:4261-4490`）生成的 `<environment_details>` 块**仅保留两个有效字段**，其余已被**注释屏蔽**。

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

**`# Current Mode`** 区分 ACT / PLAN，PLAN 模式时附 `formatResponse.planModeInstructions()` 内容。

#### 原 `# Context Window Usage` 显示条件（保留代码但不再生效）

```typescript
// task/index.ts:3866-3882
if (
    isNextGenModelFamily(this.api.getModel().id) ||
    (this.api.getModel().info.apiFormat !== ApiFormat.OPENAI_RESPONSES && (this.taskState.apiRequestCount > 100 || ...))
) {
    if (lastApiReqTotalTokens / contextWindow >= 0.6) {
        // 显示 "X / Y tokens used (Z%)"
    }
}
```
Next-gen 模型（Claude 4+ / GPT-5）**曾经**仅在 `used/total >= 60%` 时显示。

### 3.5 Workflow 注入

当 `parseSlashCommands` 匹配到 workflow 时，`detectedWorkflowName` 和 `detectedWorkflowInstructions` 被返回。在 `recursivelyMakeClineRequests` 中（`task/index.ts:2704-2719`）：

```typescript
// 顺序: environment_details → workflow instructions → workflow execution override
if (environmentDetails) userContent.push({ type: "text", text: environmentDetails })
if (detectedWorkflowInstructions) userContent.push({ type: "text", text: detectedWorkflowInstructions })
if (detectedWorkflowName) {
  userContent.push({
    type: "text",
    text: `<workflow_execution_override>\nCRITICAL: You are currently executing the workflow "${detectedWorkflowName}". The instructions above override default behavior. Follow the workflow steps precisely.\n</workflow_execution_override>`,
  })
}
```

### 3.6 Compact 注入（`shouldCompact = true`）

当 auto-condense 决定压缩时：
```typescript
userContent.push({
  type: "text",
  text: summarizeTask(
    this.stateManager.getGlobalSettingsKey("focusChainSettings"),
    this.cwd,
    isMultiRootEnabled(this.stateManager),
  ),
})
```

`summarizeTask` 返回（`contextManagement.ts:10-110`）一个大型 `<explicit_instructions type="summarize_task">` 块，要求 LLM 调用 `summarize_task` 工具（提供详细 conversation summary）。可选地包含 `task_progress` 状态。

### 3.7 非首轮 user message 格式

#### a) 反馈/追问（`ask`/`say` 流程）
LLM 调用工具时，工具执行结果通过 `addToApiConversationHistory({ role: "user", content: [tool_result, ...] })` 追加。

#### b) 用户问答/ask_followup_question 回应
当用户对 `ask_followup_question` 做出选择，新一轮 user message 包含：
```typescript
{ type: "text", text: formatResponse.tooManyMistakes(text) }
{ type: "text", text: fileContentString }  // 可选
{ image_blocks }  // 可选
```

#### c) Resume 任务
`resumeTaskFromHistory` 中用户回应后，`newUserContent` 通过 `runUserPromptSubmitHook()` 注入 hook 上下文，然后进入 `initiateTaskLoop`：
```typescript
const [taskResumptionMessage, userResponseMessage] = formatResponse.taskResumption(mode, agoText, cwd, wasRecent, responseText, hasPendingFileContextWarnings)
newUserContent.push({ type: "text", text: taskResumptionMessage })
if (responseText) {
  newUserContent.push({ type: "text", text: userResponseMessage })
}
// TaskResume hook 注入:
if (taskResumeResult.contextModification) {
  newUserContent.push({ type: "text", text: `<hook_context source="TaskResume">\n${contextText}\n</hook_context>` })
}
```

`taskResumptionMessage` 内容（`responses.ts:239-247`）：
```
[TASK RESUMPTION] This task was interrupted {agoText}. ...

{条件: IMPORTANT: If the last tool use was a replace_in_file or write_to_file that was interrupted, the file was reverted back to its original state before the interrupted edit, and you do NOT need to re-read the file as you already have its up-to-date contents.}
```

`userResponseMessage`：
```
{条件: "New message to respond to with plan_mode_respond tool (be sure to provide your response in the <response> parameter)" 或 "New instructions for task continuation"}:
<user_message>
{用户响应文本}
</user_message>
```

#### d) Condense 接受
`formatResponse.condense()` 输出：
```
The user has accepted the condensed conversation summary you generated. This summary covers important details of the historical conversation with the user which has been truncated.
<explicit_instructions type="condense_response">It's crucial that you respond by ONLY asking the user what you should work on next. ...</explicit_instructions>
```

---

## 四、ContextManager 消息截断机制（详细）

### 4.1 阈值计算（`getContextWindowInfo`）

`apps/vscode/src/core/context/context-management/context-window-utils.ts`：

```typescript
export function getContextWindowInfo(api: ApiHandler) {
  let contextWindow = api.getModel().info.contextWindow || 128_000
  
  // DeepSeek 特殊处理
  if (api instanceof OpenAiHandler && api.getModel().id.toLowerCase().includes("deepseek")) {
    contextWindow = 128_000
  }
  
  let maxAllowedSize: number
  switch (contextWindow) {
    case 64_000:  maxAllowedSize = contextWindow - 27_000; break  // deepseek
    case 128_000: maxAllowedSize = contextWindow - 30_000; break  // most models
    case 200_000: maxAllowedSize = contextWindow - 40_000; break  // claude
    default:      maxAllowedSize = Math.max(contextWindow - 40_000, contextWindow * 0.8)
  }
  return { contextWindow, maxAllowedSize }
}
```

**核心设计**：为 system prompt + 即将到来的输出预留 buffer，避免真正用到 context 极限。

### 4.2 `shouldCompactContextWindow`（`ContextManager.ts:150`）

```typescript
shouldCompactContextWindow(clineMessages, api, previousApiReqIndex, thresholdPercentage?) {
  if (previousApiReqIndex >= 0) {
    const previousRequestText = clineMessages[previousApiReqIndex]?.text
    if (previousRequestText) {
      const { tokensIn, tokensOut, cacheWrites, cacheReads } = JSON.parse(previousRequestText)
      const totalTokens = (tokensIn || 0) + (tokensOut || 0) + (cacheWrites || 0) + (cacheReads || 0)
      
      const { contextWindow, maxAllowedSize } = getContextWindowInfo(api)
      const thresholdTokens = thresholdPercentage
        ? Math.min(Math.floor(contextWindow * thresholdPercentage), maxAllowedSize)
        : maxAllowedSize
      
      return totalTokens >= thresholdTokens
    }
  }
  return false
}
```

### 4.3 `getNewContextMessagesAndMetadata` 完整流程

```typescript
async getNewContextMessagesAndMetadata(
  apiConversationHistory, clineMessages, api,
  conversationHistoryDeletedRange, previousApiReqIndex, taskDirectory, useAutoCondense
) {
  let updatedConversationHistoryDeletedRange = false
  
  if (!useAutoCondense) {
    // === 旧版（不推荐） ===
    if (previousApiReqIndex >= 0) {
      const totalTokens = ... // 上一轮 token 总和
      if (totalTokens >= maxAllowedSize) {
        const keep = totalTokens / 2 > maxAllowedSize ? "quarter" : "half"
        
        // 先尝试 file read 优化
        let { anyContextUpdates, needToTruncate } = this.attemptFileReadOptimizationCore(...)
        if (needToTruncate) {
          anyContextUpdates = this.applyStandardContextTruncationNoticeChange(timestamp) || anyContextUpdates
          conversationHistoryDeletedRange = this.getNextTruncationRange(apiMessages, deletedRange, keep)
          updatedConversationHistoryDeletedRange = true
        }
        if (anyContextUpdates) await this.saveContextHistory(taskDirectory)
      }
    }
  }
  // useAutoCondense=true 时不在此处压缩，由 attemptApiRequest 的 [1] 步骤处理
  
  const truncatedConversationHistory = this.getAndAlterTruncatedMessages(
    apiConversationHistory, conversationHistoryDeletedRange
  )
  
  return { conversationHistoryDeletedRange, updatedConversationHistoryDeletedRange, truncatedConversationHistory }
}
```

### 4.4 `getNextTruncationRange`（`ContextManager.ts:299`）

四种策略：
| 参数 | 行为 | 用途 |
|------|------|------|
| `"none"` | 删除从 index 2 开始的所有消息 | 完全重启（不常用） |
| `"lastTwo"` | 保留首 pair + 尾 pair | 测试用 |
| `"half"` | 删除一半 pair（向上取偶数） | 旧版普通截断 |
| `"quarter"` | 删除 3/4 pair | 旧版激进截断 / handleContextWindowExceededError |

**算法**：
```typescript
const rangeStartIndex = 2  // 保留前 2 条（user + assistant）
const startOfRest = currentDeletedRange ? currentDeletedRange[1] + 1 : 2
let messagesToRemove: number
if (keep === "none") messagesToRemove = Math.max(apiMessages.length - startOfRest, 0)
else if (keep === "lastTwo") messagesToRemove = Math.max(apiMessages.length - startOfRest - 2, 0)
else if (keep === "half") messagesToRemove = Math.floor((apiMessages.length - startOfRest) / 4) * 2
else /* quarter */ messagesToRemove = Math.floor(((apiMessages.length - startOfRest) * 3) / 4 / 2) * 2

let rangeEndIndex = startOfRest + messagesToRemove - 1
// 保证 rangeEndIndex 指向 assistant message，保留 user-assistant 结构
if (apiMessages[rangeEndIndex]?.role !== "assistant") rangeEndIndex -= 1
return [rangeStartIndex, rangeEndIndex]
```

### 4.5 File Read 优化（`applyContextOptimizations`）

每次 API 调用前会自动找出**重复的 read_file / write_to_file / replace_in_file / file_mention** 调用，**只保留最后一次完整内容**，历史版本替换为 `[[NOTE] This file read has been removed to save space...]`。

支持的 EditType：
```typescript
enum EditType {
  UNDEFINED = 0,
  NO_FILE_READ = 1,
  READ_FILE_TOOL = 2,    // 旧 read_file 工具调用
  ALTER_FILE_TOOL = 3,   // write_to_file / replace_in_file 的 <final_file_content>
  FILE_MENTION = 4,      // 用户 @ 文件提及（<file_content path="...">）
}
```

替换策略：
- **READ_FILE_TOOL**：替换为 `[read_file for 'path'] Result: [[NOTE] This file read has been removed...]`
- **ALTER_FILE_TOOL**：保留 `<final_file_content path="...">` 标签，但内容替换为 `[[NOTE] ...]`
- **FILE_MENTION**：保留 `<file_content path="...">` 标签，文件内容替换为 `[[NOTE] ...]`

**优化判定**（`attemptFileReadOptimizationCore`）：
```typescript
if (!anyContextUpdates) return { needToTruncate: true }  // 无重复，跳过
const percentSaved = this.calculateContextOptimizationMetrics(...)  // 字符节省百分比
return { anyContextUpdates: true, needToTruncate: percentSaved < 0.3 }
// 节省 < 30% 仍然需要截断
```

### 4.6 `applyStandardContextTruncationNoticeChange`（`ContextManager.ts:745`）

**只在 `conversationHistoryDeletedRange` 实际变化时**：
1. 在 `apiConversationHistory[1]`（第一个 assistant 消息）的 block 0 文本前面追加 `contextTruncationNotice()`
2. 将 `apiConversationHistory[0]`（第一个 user 消息）的 block 0 文本替换为 `processFirstUserMessageForTruncation()` → `"[Continue assisting the user!]"`

```
[NOTE] Some previous conversation history with the user has been removed to maintain optimal context window length. The initial user task has been retained for continuity, while intermediate conversation history has been removed. Keep this in mind as you continue assisting the user. Pay special attention to the user's latest messages.

{原第一条 assistant 消息的内容}
```

```
[Continue assisting the user!]

{原 task 标签内容保留？实测是替换为这个简短的}
```

### 4.7 Context History 持久化

`ContextManager.contextHistoryUpdates: Map<number, [EditType, Map<blockIndex, ContextUpdate[]>]>]`

- key: message index
- value: `[EditType, { blockIndex: [timestamp, updateType, update, metadata][] }]`

**保存到磁盘**：`{taskDir}/.context_history.json`（`GlobalFileNames.contextHistory`）

`truncateContextHistoryAtTimestamp` 支持从某个时间点回滚所有 in-memory 替换。

### 4.8 `ensureToolResultsFollowToolUse`（`ContextManager.ts:375`）

截断后**修复**：
- 重新排序 `tool_result` blocks（必须紧跟对应 `tool_use`）
- 补齐缺失的 `tool_result`（内容 = `"result missing"`）

确保 LLM 收到的是合法 Anthropic 格式。

---

## 五、Auto-Condense 流程（useAutoCondense + summarize_task）

这是 CygCode/Cline **默认推荐**的上下文管理路径（`task/index.ts:2607-2730`）：

```
[1] shouldCompact = (useAutoCondense && isNextGenModelFamily(modelId))
       → contextManager.shouldCompactContextWindow(...)

[2] if (shouldCompact && conversationHistoryDeletedRange 已存在) {
       // 边缘情况: 检查 activeMessageCount <= 2 → 避免"压缩已压缩"
       if (activeMessageCount <= 2) shouldCompact = false
    }

[3] if (shouldCompact) {
       // 先尝试 file read 优化（可省 30% 就跳过 auto-compact）
       shouldCompact = await contextManager.attemptFileReadOptimization(...)
    }

[4] if (shouldCompact) {
       // 在 userContent 末尾追加 summarizeTask 提示
       userContent.push({ type: "text", text: summarizeTask(...) })
       // LLM 看到提示后应调用 summarize_task 工具
    }

[5] 正常走 attemptApiRequest
```

**Summarize 完成**：
- 下一轮 `recursivelyMakeClineRequests` 检测 `taskState.currentlySummarizing`
- 之后 `conversationHistoryDeletedRange` 自增 2（覆盖 pre-summarization 的 user+assistant 消息）

**handleContextWindowExceededError**（`task/index.ts:1898`）：
- **PreCompact hook**（`PreCompact`）先执行，允许 hook 干预
- 失败/取消则继续标准流程
- 强制 `getNextTruncationRange(..., "quarter")` 激进截断
- 插入 `contextTruncationNotice` 标记
- 标记 `didAutomaticallyRetryFailedApiRequest = true` → 下一轮重试

### 5.1 `summarize_task` 工具

由 LLM 调用，返回摘要内容，注入到下一轮作为 user message 的一部分。

### 5.2 `continuationPrompt`（`contextManagement.ts:112`）

会话续接时使用：
```
This session is being continued from a previous conversation that ran out of context. The conversation is summarized below:
{summaryText}.

Please continue the conversation from where we left it off without asking the user any further questions. ...
```

---

## 六、Skills 加载与 3 层优先级（`skills.ts`）

### 6.1 加载顺序
```typescript
// discoverSkills() 内部顺序
const scanDirs = getSkillsDirectoriesForScan(cwd)  // [project, disk-global]
const projectSkills = [...]      // .clinerules/skills/ 或 .cline/skills/ 项目级
const diskGlobalSkills = [...]   // ~/.cline/skills/ 用户级
const remoteSkills = [...]       // 远程配置（从 stateManager.getRemoteConfigSettings().remoteGlobalSkills）

// 最终拼接顺序: project → disk-global → remote
skills.push(...projectSkills, ...diskGlobalSkills, ...remoteSkills)
```

### 6.2 优先级解析（`getAvailableSkills`）
**反序遍历，后加入的胜出**：
```typescript
for (let i = skills.length - 1; i >= 0; i--) {
  if (!seen.has(skill.name)) {
    seen.add(skill.name)
    result.unshift(skill)
  }
}
```

**优先级（高 → 低）**：remote > disk-global > project

### 6.3 Toggle 过滤（`filterEnabledSkills`）
- 远程 skill：`alwaysEnabled || remoteSkillsToggles[name] !== false`
- 全局 skill：`globalSkillsToggles[path] !== false`
- 项目 skill：`localSkillsToggles[path] !== false`

### 6.4 Skill 元数据结构
```typescript
interface SkillMetadata {
  name: string         // 必须与目录名匹配
  description: string  // YAML frontmatter 必填
  path: string         // 文件路径 或 "remote:<name>"
  source: "global" | "project"
}
```

`SKILL.md` 文件必须包含合法 YAML frontmatter，否则 warn 并跳过。

---

## 七、API 调用入口（`api.createMessage`）

```typescript
// task/index.ts:2118
const stream = this.api.createMessage(systemPrompt, contextManagementMetadata.truncatedConversationHistory, tools)
const iterator = stream[Symbol.asyncIterator]()
const firstChunk = await iterator.next()
```

各 provider 实现位于 `/apps/vscode/src/core/api/providers/`，接口 `ApiHandler.createMessage` 返回 `ApiStream`（AsyncIterable）。

**Provider 类型**（部分）：
- `anthropic.ts` — Claude（Anthropic API / Bedrock / Vertex）
- `openai.ts` — OpenAI / OpenAI 兼容（含 DeepSeek）
- `gemini.ts` — Google Gemini
- `cline.ts` — Cline 自有 API
- `cyg.ts` — Cyg 自有 provider
- `sapaicore.ts`, `bedrock.ts`, `vertex.ts` — 其他云

### 7.1 Native Tool Calls 模式

`enableNativeToolCalls` 开启条件（`promptContext:2084-2086`）：
```typescript
enableNativeToolCalls: 
  providerInfo.model.info.apiFormat === ApiFormat.OPENAI_RESPONSES ||
  this.stateManager.getGlobalStateKey("nativeToolCallEnabled")
```

开启时：
- `getSystemPrompt` 返回 `tools: ClineToolSet.getEnabledToolSpecs(...)`
- LLM 通过原生 `tools` 数组调用，而不是 XML 标签
- `useNativeToolCalls = true` 标志影响后续 `parseAssistantMessageV2` 与 tool_result 包装

### 7.2 Tools 列表生成

`ClineToolSet.getEnabledToolSpecs(variant, context)` 过滤启用工具：
- 根据 `context` 的 `enableNativeToolCalls`、`subagentsEnabled` 等字段动态过滤
- 根据工具的 `dependencies`（如 `task_progress` 依赖 `TODO`）
- 根据 `contextRequirements`（context 条件）

`PromptBuilder.tool()` 渲染每个工具的 system prompt section：
```
## {tool_name}
Description: {description}
{可选: \n{param description}}
Parameters:
- param_name: (required) {instruction}
- ...
Usage:
<{tool_name}>
<{param1}>...</{param1}>
<{param2}>...</{param2}>
...
</{tool_name}>
```

---

## 八、MessageStateHandler 消息状态管理

### 8.1 两套数据结构（`message-state.ts`）

| 字段 | 类型 | 用途 | 持久化 |
|------|------|------|--------|
| `apiConversationHistory` | `ClineStorageMessage[]` | 发给 LLM 的完整消息 | `{taskDir}/api_conversation_history.json` |
| `clineMessages` | `ClineMessage[]` | UI 展示的消息 | `{taskDir}/cline_messages.json` |

**关键**：`addToClineMessages` 会记录 `message.conversationHistoryIndex = apiConversationHistory.length - 1`，用于后续 **checkpoint 回滚**到任意 cline message 对应的 api conversation 位置。

### 8.2 互斥保护（`stateMutex: p-mutex`）

所有修改都包在 `withStateLock()` 中：
- `addToApiConversationHistory`
- `addToClineMessages`
- `overwriteClineMessages`
- `updateClineMessage`
- `deleteClineMessage`
- `saveClineMessagesAndUpdateHistory`

### 8.3 Event 通知（`clineMessagesChanged`）

修改 clineMessages 时 emit `add` / `update` / `delete` / `set` 事件，UI 订阅以实时刷新。

### 8.4 Resume 任务

`resumeTaskFromHistory`：
1. 加载 `getSavedClineMessages(taskId)` 和 `getSavedApiConversationHistory(taskId)`
2. 删除尾部所有 `resume_task` / `resume_completed_task` ask
3. 删除最近一条无 cost/cancelReason 的 `api_req_started`（避免显示空请求）
4. 初始化 `contextManager.initializeContextHistory(taskDir)` 加载已保存的 `context_history.json`
5. 弹 `resume_task` / `resume_completed_task` ask
6. 触发 `TaskResume` hook
7. 构建 `newUserContent`（task resumption 消息 + 用户响应 + hook context）
8. `initiateTaskLoop(newUserContent)`

---

## 九、`api_req_started` 消息结构

每轮 API 调用前先调用 `say("api_req_started", ...)`，占位消息 + 实际内容：

```typescript
// 第一次: 占位
await this.say("api_req_started", JSON.stringify({
  request: userContent.map(block => formatContentBlockToMarkdown(block)).join("\n\n") + "\n\nLoading..."
}))

// API 调用结束后: 真实内容
await this.messageStateHandler.updateClineMessage(lastApiReqIndex, {
  text: JSON.stringify({
    request: userContent.map(block => formatContentBlockToMarkdown(block)).join("\n\n")
  } satisfies ClineApiReqInfo)
})
```

`ClineApiReqInfo` 后续由 `updateApiReqMsg` 不断更新为：
```typescript
{
  request: string,         // markdown 格式的 user content
  tokensIn: number,        // 本次输入
  tokensOut: number,       // 本次输出
  cacheWrites: number,     // cache 写入 token
  cacheReads: number,      // cache 命中 token
  cost: number,            // 累计 cost
  cancelReason?: "user" | "streaming_failed" | ...,
  streamingFailedMessage?: string
}
```

**关键**：`previousApiReqIndex` = `findLastIndex(clineMessages, m => m.say === "api_req_started")`，`shouldCompactContextWindow` 用此读取上一轮 token。

---

## 十、Abort / Cancel 流程（`abortTask`）

7 阶段取消（`task/index.ts:1562-...`）：

| Phase | 行为 |
|-------|------|
| 1 | `shouldRunTaskCancelHook()` 判断是否需要跑 hook |
| 2 | `taskState.abort = true` 立刻设标志 |
| 3 | 取消 active hook + 取消 background command |
| 4 | 执行 `TaskCancel` hook（不可取消） |
| 5 | `saveClineMessagesAndUpdateHistory() + postStateToWebview()` |
| 6 | `FocusChainManager.checkIncompleteProgressOnCompletion()` |
| 7 | 资源清理（presentation scheduler、environment tracker、file context tracker、claude code、mcp hub 等） |

**取消后未完成消息**：
```typescript
// abortStream() 中
await this.messageStateHandler.addToApiConversationHistory({
  role: "assistant",
  content: [{ type: "text", text: assistantMessage + `\n\n[Response interrupted by user/API Error]` }],
  modelInfo, metrics: {...}, ts: Date.now()
})
```

`resumeTaskFromHistory` 通过 `taskResumptionMessage` 让 LLM 知道被中断。

---

## 十一、完整每轮 API 请求示例

### 11.1 第一轮（`startTask`）

```json
{
  "system": "<完整 baseTemplate 替换后的 system prompt>...",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "<task>\n请帮我写一个 hello world 程序\n</task>" },
        { "type": "text", "text": "<file_content path='spec.md'>\n...</file_content>" },
        { "type": "text", "text": "<hook_context source=\"TaskStart\">\n...\n</hook_context>" },
        { "type": "text", "text": "<hook_context source=\"UserPromptSubmit\">\n...\n</hook_context>" },
        { "type": "text", "text": "<environment_details>\n# Linux 5.4 Visible Files\n...\n# Current Working Directory (/home/llm/chm/cline) Files\n...\n# Workspace Configuration\n{...}\n# Detected CLI Tools\ngit, docker, npm, ...\n# Context Window Usage\n0 / 1,000K tokens used (0%)\n# Current Mode\nACT MODE\n</environment_details>" }
      ]
    }
  ],
  "tools": [...]  // 仅 enableNativeToolCalls=true
}
```

### 11.2 第二轮（LLM 工具调用后）

```json
{
  "messages": [
    // 上轮的 user message
    {"role": "user", "content": [...]},
    // LLM 响应
    {
      "role": "assistant",
      "content": [
        {"type": "text", "text": "我来帮你写一个 hello world 程序。"},
        {"type": "tool_use", "id": "tool_001", "name": "write_to_file", "input": {"path": "hello.js", "content": "..."}}
      ]
    },
    // 工具结果（user role + tool_result block）
    {
      "role": "user",
      "content": [
        {"type": "tool_result", "tool_use_id": "tool_001", "content": "File created successfully at: /path/hello.js"}
      ]
    },
    // 后续的 assistant 响应
    {
      "role": "assistant",
      "content": [{"type": "text", "text": "已创建 hello.js 文件。"}]
    },
    // 用户的 follow-up（新一轮 user message）
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "<user_message>\n请把输出改成 Hello, CygCode!\n</user_message>" },
        {"type": "text", "text": "<environment_details>\n# Linux 5.4 Visible Files\nhello.js\n...\n# Current Working Directory (/home/llm/chm/cline) Files\n...\n# Context Window Usage\n12,500 / 1,000K tokens used (1%)\n# Current Mode\nACT MODE\n</environment_details>" }
      ]
    }
  ]
}
```

### 11.3 启用 Native Tool Calls 时

```json
{
  "system": "...",
  "messages": [...],
  "tools": [
    {
      "name": "write_to_file",
      "description": "...",
      "input_schema": {"type": "object", "properties": {"path": {...}, "content": {...}}, "required": ["path", "content"]}
    },
    ...
  ]
}
```

### 11.4 触发 workflow 时（`/my-workflow`）

用户输入 `/my-workflow 我想做 X`，`parseSlashCommands` 处理后：
- user text 变成：`"我想做 X"`（slash command 移除）
- 返回 `detectedWorkflowName = "my-workflow.md"`, `detectedWorkflowInstructions = "<explicit_instructions type=\"my-workflow.md\" priority=\"override\">\n{workflow 内容}\n</explicit_instructions>"`
- userContent 末尾追加：

```json
{"role": "user", "content": [
  ...原 content...
  {"type": "text", "text": "<explicit_instructions type=\"my-workflow.md\" priority=\"override\">\n{workflow 内容}\n</explicit_instructions>"},
  {"type": "text", "text": "<workflow_execution_override>\nCRITICAL: You are currently executing the workflow \"my-workflow.md\". The instructions above override default behavior. Follow the workflow steps precisely.\n</workflow_execution_override>"}
]}
```

### 11.5 触发 auto-condense 时

`recursivelyMakeClineRequests` 判定 `shouldCompact=true`，在 userContent 末尾追加：

```json
{"type": "text", "text": "<explicit_instructions type=\"summarize_task\">\nThe current conversation is rapidly running out of context. ...\nUsage: <summarize_task><context>Your detailed summary</context>...</summarize_task>\n</explicit_instructions>\n"}
```

LLM 看到此提示后应调用 `summarize_task` 工具。

---

## 十二、关键差异 / 重要说明

### 12.1 System Prompt 每轮都重新生成

- 完整重建（不缓存）
- 所有 toggle 刷新 → 路径上下文构建 → Rules 加载 → Skills 发现 → SystemPromptContext 构建 → `getSystemPrompt()`
- Rules 文件内容每轮重新读取，**内容变化实时生效**
- 不同 variant（generic/next-gen/xs/gemini-3/devstral/hermes/gpt-5/native-gpt-5/native-gpt-5-1/native-next-gen/trinity/glm）有不同 `baseTemplate`、`componentOrder`、`tools` 列表

### 12.2 Workflows 不注入 System Prompt

- Workflows (`.clinerules/workflows/` 或 `~/.cline/workflows/`) **不在** System Prompt 中
- 通过 `parseSlashCommands()` 在用户消息阶段匹配 `/<workflow-name>` 触发
- 匹配成功后通过 `<explicit_instructions type="..." priority="override">` 注入到 **user message**
- 末尾追加 `<workflow_execution_override>` 提示

### 12.3 Skills 只注入元数据

- System Prompt 的 `SKILLS_SECTION` 中**只**包含 Skill 的 `name + description`
- 实际 Skill 的指令内容在 LLM 调用 `use_skill` 工具后才通过 `getSkillContent()` 加载
- `use_skill` 工具 handler 返回的 `SkillContent.instructions` 会作为 tool_result 追加到 messages

### 12.4 environment_details 每轮都追加（★ 已精简）

- 每条 user message 末尾都追加 `<environment_details>...</environment_details>` 块
- **当前内容**（2026-06-17 精简后）：仅 `# Current Mode`（ACT / PLAN）和可选 `# Workspace Roots`
- **已移除字段**（用注释屏蔽）：Visible Files、Open Tabs、Terminals、Recent Files、Current Time、CWD Files、Workspace Config、CLI Tools、Context Window Usage
- 静态环境信息（OS/IDE/Shell/CWD）通过 System Prompt 的 `SYSTEM_INFO_SECTION` 提供
- `includeFileDetails=true` 仅首轮传递

### 12.5 Context Window 显示策略

- **当前状态（2026-06-17）**：`# Context Window Usage` 字段已在 `getEnvironmentDetails` 中被**注释屏蔽**，不再显示
- 旧逻辑（保留代码）：Next-gen 模型（Claude 4+ / GPT-5）曾在 `lastApiReqTotalTokens / contextWindow >= 0.6` 时显示

### 12.6 message 截断 + file read 去重 + 强制重试

- `getNewContextMessagesAndMetadata` 每轮决策
- 先 file read dedup，节省 < 30% 仍触发截断
- 阈值 `maxAllowedSize`：
  - 64k: -27k = 37k（deepseek）
  - 128k: -30k = 98k
  - 200k: -40k = 160k
- 截断 `keep: "half" | "quarter"`，quarter 更激进

### 12.7 Auto-Condense 是 Next-gen 模型默认

`useAutoCondense && isNextGenModelFamily` 才会走 auto-compact 路径：
- 阈值与 `shouldCompactContextWindow` 相同
- 触发后 LLM 必须返回 `summarize_task` 工具调用
- 下一轮 `currentlySummarizing` 检测 + `conversationHistoryDeletedRange` 增 2 隐藏预摘要消息

### 12.8 Hooks 全程串联

- **TaskStart** hook：任务开始时
- **UserPromptSubmit** hook：用户输入时（`runUserPromptSubmitHook`）
- **TaskResume** hook：恢复任务时
- **TaskCancel** hook：取消任务时
- **PreCompact** hook：自动压缩前

每个 hook 可返回 `contextModification` 注入到 user content，用 `<hook_context source="...">` 标签包裹。

### 12.9 Native Tool Calls 模式

- 开启条件：`model.info.apiFormat === OPENAI_RESPONSES` 或 `nativeToolCallEnabled === true`
- LLM 通过 OpenAI/Anthropic 原生 `tools` 参数调用
- 工具结果通过原生 `tool_result` blocks 返回
- 与 XML 工具调用**互斥**

### 12.10 路径别名约定

- `~/` 和 `$HOME` **不能**用
- 必须使用 `process.cwd()` 或 `getCwd()` 解析
- `.clinerules` 等目录用 `path.resolve(cwd, ...)` 拼接

---

## 十三、消息序列时序图（典型多轮对话）

```
第 1 轮 (startTask)
─────────────────────────────────────────────────────────
User: <task>{原始任务}</task>
      [可选: images, file_content, hook_context]
      <environment_details>...</environment_details>

Assistant: (调用 write_to_file 工具)

User (tool_result): File created successfully.

Assistant: (调用 attempt_completion 工具)


第 N 轮 (用户问 "修改一下")
─────────────────────────────────────────────────────────
API 历史（经 ContextManager 截断 + file read 去重）:
  - User: <task>...</task>           ← 可能被替换为 [Continue assisting the user!]
  - Assistant: [NOTE]...truncation notice... + 原始内容
  - User: <file_content path="..."> ...   ← 可能被替换为 [[NOTE] removed]
  - Assistant: 调用 write_to_file
  - User: tool_result
  - Assistant: 调用 attempt_completion

当前轮新增 user message:
  User: <user_message>请把输出改成 Hello, CygCode!</user_message>
        <environment_details>...</environment_details>

Assistant: 调用 replace_in_file

User (tool_result): The file was reverted/saved successfully.

Assistant: 调用 attempt_completion
```

---

## 十四、关键代码位置索引

| 主题 | 文件 | 行号 / 关键函数 |
|------|------|----------------|
| **任务启动** | `apps/vscode/src/core/task/index.ts` | `startTask` (1070), `resumeTaskFromHistory` (1193) |
| **主循环** | `apps/vscode/src/core/task/index.ts` | `initiateTaskLoop` (1481), `recursivelyMakeClineRequests` (2451) |
| **API 请求** | `apps/vscode/src/core/task/index.ts` | `attemptApiRequest` (1962) |
| **上下文加载** | `apps/vscode/src/core/task/index.ts` | `loadContext` (3438) |
| **环境信息** | `apps/vscode/src/core/task/index.ts` | `getEnvironmentDetails` (3683) |
| **取消** | `apps/vscode/src/core/task/index.ts` | `abortTask` (1562), `shouldRunTaskCancelHook` (1516) |
| **Context 超限** | `apps/vscode/src/core/task/index.ts` | `handleContextWindowExceededError` (1898) |
| **Context 截断** | `apps/vscode/src/core/context/context-management/ContextManager.ts` | `getNewContextMessagesAndMetadata` (227), `getNextTruncationRange` (299), `applyContextOptimizations` (606) |
| **Context Window 计算** | `apps/vscode/src/core/context/context-management/context-window-utils.ts` | `getContextWindowInfo` (10) |
| **Context 错误识别** | `apps/vscode/src/core/context/context-management/context-error-handling.ts` | `checkContextWindowExceededError` (3) |
| **System Prompt** | `apps/vscode/src/core/prompts/system-prompt/index.ts` | `getSystemPrompt` (16) |
| **Variant 模板引擎** | `apps/vscode/src/core/prompts/system-prompt/registry/PromptBuilder.ts` | `build` (23) |
| **Template 替换** | `apps/vscode/src/core/prompts/system-prompt/templates/TemplateEngine.ts` | `resolve` (7) |
| **占位符定义** | `apps/vscode/src/core/prompts/system-prompt/templates/placeholders.ts` | `SystemPromptSection` enum |
| **用户指令构建** | `apps/vscode/src/core/prompts/system-prompt/components/user_instructions.ts` | `getUserInstructions` (17), `buildUserInstructions` (41) |
| **规则加载** | `apps/vscode/src/core/context/instructions/user-instructions/cline-rules.ts` | `getGlobalClineRules` (21), `getLocalClineRules` (81) |
| **规则助手** | `apps/vscode/src/core/context/instructions/user-instructions/rule-helpers.ts` | `getRuleFilesTotalContentWithMetadata` (179) |
| **外部规则** | `apps/vscode/src/core/context/instructions/user-instructions/external-rules.ts` | `getLocalCursorRules` 等 |
| **Workflows** | `apps/vscode/src/core/context/instructions/user-instructions/workflows.ts` | `refreshWorkflowToggles` (10) |
| **Skills** | `apps/vscode/src/core/context/instructions/user-instructions/skills.ts` | `discoverAvailableSkills` (228), `getSkillContent` (237) |
| **Slash Commands** | `apps/vscode/src/core/slash-commands/index.ts` | `parseSlashCommands` (42) |
| **响应模板** | `apps/vscode/src/core/prompts/responses.ts` | `formatResponse.*` 各种方法 |
| **Compact 提示** | `apps/vscode/src/core/prompts/contextManagement.ts` | `summarizeTask` (1), `continuationPrompt` (112) |
| **内置命令** | `apps/vscode/src/core/prompts/commands.ts` | `newTaskToolResponse`, `condenseToolResponse` 等 |
| **消息状态** | `apps/vscode/src/core/task/message-state.ts` | `MessageStateHandler` 类 |
| **Tools 生成** | `apps/vscode/src/core/prompts/system-prompt/registry/ClineToolSet.ts` | `getEnabledToolSpecs` |
| **Variant 配置示例** | `apps/vscode/src/core/prompts/system-prompt/variants/generic/config.ts` | `createVariant` builder |

---

## 十五、总结：每轮 API 调用的"组装清单"

每轮 LLM API 调用前，`Task.recursivelyMakeClineRequests` → `attemptApiRequest` 都会：

1. **加载 Rules**（7 类）：global/local .clinerules, .cursorrules, .cursor/rules/, .windsurfrules, .agents/AGENT.md, .clineignore
2. **加载 Skills**（3 层）：project → disk-global → remote，去重 + 过滤 + 排序
3. **收集 Editor 状态**：open tabs, visible tabs（cap 50）
4. **解析 multi-root workspace**（如启用）
5. **构建 SystemPromptContext**
6. **生成 System Prompt**（每轮重新构建）
7. **追加 Hook context**（TaskStart / UserPromptSubmit / TaskResume）
8. **追加 environment_details**（含 file details 仅首轮）
9. **追加 workflow 指令**（如触发）
10. **追加 summarize 指令**（如 auto-condense 触发）
11. **持久化**到 `api_conversation_history.json`
12. **ContextManager 决策**：
    - 检查上一轮 token → 触发 file read 优化 / 截断
    - 应用 in-memory text 替换（`contextHistoryUpdates`）
    - 确保 `tool_use` / `tool_result` 配对
13. **调用 `api.createMessage(systemPrompt, truncatedHistory, tools)`**
14. **流式响应** → 处理 chunk → 写回 `clineMessages` + 触发 UI 更新

每一步都基于上一轮的真实状态（token 报告、clineMessages、apiConversationHistory），构成一个完整的**自适应反馈循环**。


---

## 十六、Tool 输出截断机制（Handler 层）

> **本节是基于源码调研的新增章节**（2026-06-17），补充 §四 提到的 ContextManager 截断，介绍在 tool handler 层预先做的输出体积治理。

### 16.1 概述

ContextManager（§四）是对**消息历史**的截断/去重。但**tool 的输出结果**在进入 messages 之前，**tool handler 内部**就已经做了一层"输出体积治理"。这形成双层防御：

| 层级 | 处理位置 | 处理对象 | 典型阈值 |
|------|---------|---------|----------|
| **Handler 层** | tool handler 内部 | 工具返回的原始输出 | 400KB / 1000 行 / 200 文件 |
| **ContextManager 层** | messages 数组 | 整段对话历史 | 75% context window / quarter 截断 |

### 16.2 Handler 层截断点全集

| # | 截断函数 | 工具 | 位置 | 默认值 |
|---|---------|------|------|--------|
| 1 | `excerpt()` | **subagent** | `SubagentToolHandler.ts:36-47` | **不再使用**（`excerpt()` 是死代码，已改为无截断的 `.trim()` 透传） |
| 2 | `truncateContent()` | read_file (PDF/DOCX/Excel/IPYNB) | `extract-text.ts:76` | **400 KB** |
| 3 | `truncateContent()` | mcp tools | `UseMcpToolHandler.ts:209` | **400 KB** |
| 4 | `truncateContent()` | mcp resources | `AccessMcpResourceHandler.ts:163` | **400 KB** |
| 5 | `DEFAULT_MAX_LINES` | read_file | `ReadFileToolHandler.ts:18` | **1000 行** |
| 6 | `listFiles(..., 200)` | list_files | `ListFilesToolHandler.ts:100` | **200 文件** |
| 7 | `extractTextFromExcel` | read_file (xlsx) | `extract-text.ts:162-165` | **50000 行** |
| 8 | 20 MB 硬限制 | read_file | `extract-text.ts:66-69` | **20 MB** |

### 16.3 全局字节级截断：`truncateContent()`

**文件**：`apps/vscode/src/shared/content-limits.ts`

```typescript
export const MAX_CONTENT_SIZE_BYTES = 400 * 1024  // 400 KB

export function truncateContent(content: string, maxSize = MAX_CONTENT_SIZE_BYTES): string {
    if (content.length <= maxSize) return content
    const truncatedContent = content.slice(0, maxSize)
    return `${truncatedContent}\n\n---\n\n[FILE TRUNCATED: This content is ${formatBytes(content.length)} but only the first ${formatBytes(maxSize)} is shown (${formatBytes(content.length - maxSize)} truncated). Use search_files to find specific patterns, or execute_command with grep/head/tail for targeted reading.]`
}
```

**调用位置**（统一在 tool result 拼装前调用）：

- **`extract-text.ts:76`**：所有 `read_file` 文件类型（PDF/DOCX/Excel/IPYNB/普通文本）
- **`UseMcpToolHandler.ts:209`**：MCP 工具调用结果
- **`AccessMcpResourceHandler.ts:163`**：MCP 资源访问结果

**设计特点**：
- 截断后追加 `[FILE TRUNCATED: ...]` 提示，让 LLM 知道内容不完整
- 提示 LLM 用 `search_files` 或 `grep/head/tail` 找具体内容

### 16.4 行级截断：`DEFAULT_MAX_LINES`

**文件**：`apps/vscode/src/core/task/tools/handlers/ReadFileToolHandler.ts:18, 49`

```typescript
export const DEFAULT_MAX_LINES = 1000
// ...
const requestedEnd = endLine !== undefined ? Math.max(1, endLine) : requestedStart + DEFAULT_MAX_LINES - 1
```

**行为**：未指定 `end_line` 时只显示 1000 行。超过则追加 `(Showing lines X-Y of Z total. Use start_line=...)` 提示。

### 16.5 文件数限制：`listFiles(..., 200)`

**文件**：`apps/vscode/src/core/task/tools/handlers/ListFilesToolHandler.ts:100`

```typescript
;[files, didHitLimit] = await listFiles(absolutePath, recursive, 200)
```

**行为**：单次 `list_files` 最多返回 200 个文件/目录。

### 16.6 文本文件 20MB 硬限制

**文件**：`apps/vscode/src/integrations/misc/extract-text.ts:66-69`

```typescript
if (fileStat.size > 20 * 1000 * 1024) {
    throw new Error(`File is too large to read into context.`)
}
```

**行为**：超过 20MB **直接拒绝读取**（不截断，直接报错让 LLM 知道）。

### 16.7 Excel 行级截断

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

### 16.8 Subagent 输出截断（已移除，仅保留死代码）

**文件**：`apps/vscode/src/core/task/tools/handlers/SubagentToolHandler.ts:36-47, 315-324`

`excerpt()` 函数定义**仍保留在文件中作为死代码**（`SubagentToolHandler.ts:36-47`）：

```typescript
function excerpt(text: string | undefined, maxChars = 1200): string {
    if (!text) return ""
    const trimmed = text.trim()
    if (trimmed.length <= maxChars) return trimmed
    return `${trimmed.slice(0, maxChars)}...`
}
```

但**在 summary 组装中已不再被调用**。原截断调用已被注释保留（`SubagentToolHandler.ts:318`）：
```typescript
// const detail = entry.status === "completed" ? excerpt(entry.result) : excerpt(entry.error)
```

当前实际代码（`SubagentToolHandler.ts:321-322`）改为仅做 `.trim()` 空白清理，**不做任何字符上限截断**：
```typescript
const detail =
    entry.status === "completed" ? (entry.result?.trim() ?? "") : (entry.error?.trim() ?? "")
```

**修改原因**（2026-06-17）：subagent 分析长文件、生成长报告或产生大量代码时，1200 字符硬截断会导致主 agent 看到不完整信息，影响判断。移除后主 agent 能看到 subagent 的完整输出。

**相关保护措施仍然存在**：
- subagent 内部仍受 context window 压缩保护（第 2/3 层）
- read_file / MCP 工具的 400KB 全局限制仍然有效
- read_file 行数限制 1000 行仍然有效
- list_files 200 文件限制仍然有效

### 16.9 没有截断的工具

| 工具 | 行为 | 备注 |
|------|------|------|
| `execute_command` | 命令输出原样返回 | 30s/300s 超时控制 |
| `web_fetch` | 后端服务控制 | handler 不截断 |
| `search_files` | ripgrep 输出原样 | 无明确上限 |
| `list_code_definition_names` | 完整结果 | - |
| `web_search` | 完整结果 | - |
| `ask_followup_question` | 用户输入 | - |
| `attempt_completion` | 完成标记 | - |
| `write_to_file` / `replace_in_file` / `apply_patch` | 写入操作 | 无输出截断 |

### 16.10 Subagent 内部三层截断机制

Subagent 涉及**三层**截断/压缩机制：

| 层级 | 位置 | 阈值 | 触发时机 |
|------|------|------|----------|
| **第 1 层（Handler 层）** | `SubagentToolHandler.excerpt()` | 无上限（仅 `.trim()` 透传，`excerpt()` 是死代码） | subagent 完成返回结果给主 agent |
| **第 2 层（ContextManager 层）** | `SubagentRunner.shouldCompactBeforeNextRequest()` | 75% context window (next-gen) / `maxAllowedSize` | 每次 LLM 请求前 |
| **第 3 层（ContextManager 层）** | `SubagentRunner.createMessageWithInitialChunkRetry()` | "quarter" 模式删除 25% 消息 | API 返回 context window exceeded 错误时 |

**注意**：第 1 层的 `excerpt()` 函数**已不再被调用**（原始截断逻辑已移除），主 agent 现在看到的是 subagent 的完整输出（仅经 `.trim()` 清理空白）。第 2/3 层作为 subagent 内部的上下文保护机制仍然有效。

### 16.11 Handler 层与 ContextManager 层的协同

```
Tool 执行结果
    ↓
Tool handler 内部截断（如 400KB / 1000 行 / 200 文件）  ← Handler 层（第一道防线）
    ↓
返回到 LLM 的 messages 数组
    ↓
ContextManager 每轮处理（file read 去重 / 截断）      ← ContextManager 层（第二道防线）
    ↓
最终发给 LLM API
```

**互补关系**：
- **Handler 层**：按工具特性定制（如 read_file 按行截断，list_files 按数量，subagent 不截断仅 `.trim()`）
- **ContextManager 层**：统一处理所有消息（去重 + 截断 + 摘要）

### 16.12 关键源码索引

| 主题 | 文件 |
|------|------|
| 全局内容限制（400KB） | `apps/vscode/src/shared/content-limits.ts` |
| read_file handler（行数 1000） | `apps/vscode/src/core/task/tools/handlers/ReadFileToolHandler.ts` |
| read_file 文本提取 | `apps/vscode/src/integrations/misc/extract-file-content.ts` |
| 文本/PDF/DOCX/Excel 提取 | `apps/vscode/src/integrations/misc/extract-text.ts` |
| subagent handler | `apps/vscode/src/core/task/tools/handlers/SubagentToolHandler.ts` |
| subagent 执行 | `apps/vscode/src/core/task/tools/subagent/SubagentRunner.ts` |
| list_files handler（200 文件） | `apps/vscode/src/core/task/tools/handlers/ListFilesToolHandler.ts` |
| MCP tool handler | `apps/vscode/src/core/task/tools/handlers/UseMcpToolHandler.ts` |
| MCP resource handler | `apps/vscode/src/core/task/tools/handlers/AccessMcpResourceHandler.ts` |
| ContextManager | `apps/vscode/src/core/context/context-management/ContextManager.ts` |

---

*本节整合自 `DevelopmentRecord/subagent输出截断取消实现.md` 调研结果*
