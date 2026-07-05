---
aliases: [CygCode Harness, Harness 工程, Cline Fork Harness, AI Agent 约束系统, 四道防线]
tags: [Harness, Agent, Cline, CygCode, LLM-Constraint, FocusChain, ContextManagement, MultiTurn]
related:
  - "./claude-code-harness.md"
  - "./harness-engineering.md"
  - "./hook.md"
  - "../context-engineering/claude-code-context-engineering.md"
---

# CygCode Harness 工程 — LLM 多轮对话"不跑偏"的系统方法论

> 调研对象：CygCode（Cline 的一个活跃 Fork）中的 Harness（驾驭/脚手架）系统。该系统的使命是解决 AI Agent 在多轮长对话中最难的问题——**如何让 LLM 始终按照用户与系统的约束执行任务，不偏离最初的规则和计划**。
>
> 本文整合了该项目中 System Prompt 提示词工程、FocusChain 任务进度追踪、ContextManager 上下文治理、Rules/Skills/Workflows 加载、Tool 输出截断等 10+ 个子系统的协同机制，提炼为方法论级的知识，**不涉及具体实现代码细节**。

---

## 1. 核心问题：LLM 为什么会在多轮对话中"跑偏"

一切 Harness 设计的出发点，是 LLM 在多轮 Agent 场景中的四个结构性弱点：

- **上下文衰减**：随着对话增长，早期指令的权重相对降低，模型倾向关注最近的内容（recency bias）
- **指令漂移**：模型在长任务中倾向于"自己找合理路径"，覆盖或忘掉用户的特殊约束
- **状态丢失**：模型是"无状态"的，每轮只能看到 messages；没有"我刚才做到第几步了"的内部记忆
- **目标偏移**：完成若干子目标后，模型容易"宣告完成"而非"继续检查"

**Harness 的使命**：用工程手段，将这四个依赖模型自身能力的约束外化为系统侧强制注入、强制校验、强制纠正的可观测、可调整机制。核心哲学是不依赖 LLM 自身的记忆或自控力。

---

## 2. 核心心法：三条基本原则

| 原则 | 说明 |
|------|------|
| 规则不依赖模型记忆 | 所有长期有效的约束，每轮都重新"推到"模型面前。不指望模型在前几轮看到后就记住。 |
| 软约束 + 硬约束分层 | System Prompt 中的规则是"软约束"（模型可能违反），Tool 协议和 Permission 是"硬约束"（模型必须按 schema 写才能调通）。能上硬约束的绝不留给软约束。 |
| 所有状态外化 | 任务进度、文件状态、环境信息，全部由系统侧维护并在每轮显式注入。模型不需要"自己记住"。 |

---

## 3. 总体框架：四道防线 + 五辅助体系

整个 Harness 体系可抽象为 4 道核心防线和 5 个辅助系统，每轮 LLM 调用时同步运作：

```
                         Harness 防御层次模型

 用户原始任务 ->  LLM  <- Harness 在每一层都强制约束
                    |
 +------------------+------------------+
 |  1 System Prompt（静态契约）        |  <- 每次请求都重建的"宪法"
 |     - 角色/能力/工具/规则/原则        |
 |     - 用户规则在这里注入              |
 +------------------+------------------+
                    v
 +-------------------------------------+
 |  2 User Message（动态状态）         |  <- 每次请求都重新计算的状态
 |     - 当前任务、附件                 |
 |     - <environment_details>          |
 |     - Workflow / FocusChain 指令     |
 +------------------+------------------+
                    v
 +-------------------------------------+
 |  3 Tool 协议（行动约束）            |  <- XML 标签或原生 tool_calls
 |     - 参数 schema 严格定义           |
 |     - 工具执行前的用户审批/沙箱      |
 |     - Tool result 自动回流给模型     |
 +------------------+------------------+
                    v
 +-------------------------------------+
 |  4 FocusChain（计划与进度）         |  <- 跨轮次的"任务状态机"
 |     - 任务清单 + 完成度              |
 |     - 每轮 re-inject 提醒更新        |
 |     - 文件持久化 + 文件监听          |
 +-------------------------------------+

辅助防线：
 - ContextManager：上下文长度治理（截断 + 去重 + 摘要）
 - PLAN/ACT MODE：双模式分离"想"与"做"
 - Hooks：项目级外部干预通道
 - Rules/Skills/Workflows：用户可配置的三层指令源
 - Tool 输出截断与压缩：Handler 层预先做输出体积治理
```

---

## 4. 第一道防线：System Prompt（静态契约层）

### 4.1 定位

System Prompt 是 LLM 看到的"宪法"。核心设计是**每轮重建**——每轮 API 调用前完整重建一次 System Prompt，确保 Rules 文件改动立即生效、CWD 等动态信息总是最新的、任何开关关闭都立即反映到提示词中。

### 4.2 12 个 Section 的顺序

```
System Prompt = baseTemplate + 12 section 占位符
（componentOrder 决定实际顺序，不同 variant 不同）

1. AGENT_ROLE      你是 Cyg Code 高级软件工程师
2. TOOL_USE        工具定义 + XML 调用格式（最占空间）
3. TASK_PROGRESS   task_progress 参数使用规范
4. MCP             [条件] 已连接 MCP server 时出现
5. EDITING_FILES   write_to_file / replace_in_file 用法
6. ACT_VS_PLAN     ACT vs PLAN 模式区分
7. CAPABILITIES    工具能力清单
8. RULES           CWD / 工具约束 / 通用行为规范
9. SYSTEM_INFO     OS / IDE / Shell / CWD
10. OBJECTIVE       7 条任务执行原则
11. USER_INSTRUCTIONS  <- 用户规则注入的唯一位置
12. SKILLS          [条件] Skills 元数据列表
```

### 4.3 最重要的两个 Section

**OBJECTIVE（宪法原则）**：7 条不可协商的行为准则。关键条款：
- 调工具前用 `<thinking>` 标签显式推理，防止冲动调用
- 参数缺失时必须用 ask_followup_question 提问（非 YOLO 模式），防止瞎猜参数
- 用 attempt_completion 前必须验证任务要求，防止"未完成就声称完成"
- 禁止以问句结尾，防止无意义的来回对话

**RULES（硬性行为规范）**：把模型容易犯的错全部显式列出来。关键禁令包括：不能 cd 到其他目录、不要用 ~ 或 $HOME、NEVER 以问句结束 attempt_completion、STRICTLY FORBIDDEN 以 Great/Certainly/Okay/Sure 开头、必须等待用户确认每次工具使用、replace_in_file 的 XML 格式硬性要求。

### 4.4 Variant 系统（动态适配不同模型）

System Prompt 按模型/Provider 动态选择 variant：generic（全工具 fallback）、next-gen（Claude 4+/GPT-5，措辞更严格）、xs（极小模型，工具集裁剪）。不同 variant 同 section 可以有不同措辞力度。

### 4.5 用户规则注入

用户自定义规则唯一注入点是 System Prompt 末尾的 USER_INSTRUCTIONS，按固定顺序拼接 8 类内容：preferredLanguage, globalClineRules, localClineRules, localCursorRules, localCursorRulesDir, localWindsurfRules, localAgentsRules, clineIgnore。顶部用大写 IMPORTANT + MUST 强调 override 行为，每条规则以文件路径为标题。

---

## 5. 第二道防线：User Message（动态状态注入层）

### 5.1 定位

User Message 尾部注入是每轮的"现状快报"，把 LLM 看不到的上下文状态重新拼接到 user 侧。User Message 末尾的 5 段式结构：

```
A. 基础内容：<task> / <user_message> / <file_content> / <image> / <hook_context>
B. parseTextBlock 处理：@file: -> <file_content>、/cmd -> 匹配 workflow
C. 每轮追加（Harness 核心注入点，按以下严格顺序）：
   1. <environment_details>（精简版，仅 Current Mode + 可选 Workspace Roots）
   2. FocusChain todo list（条件性，interval 门控）
   3. <explicit_instructions type="workflow">（可选，独立注入）
   4. <workflow_execution_override>（可选，模型回复前最后一条指令）
   5. <explicit_instructions type="summarize_task">（可选）
```

**关键变更**（2026-06-17 优化）：
- `environment_details` 被提升到**第 1 位**，确保 LLM 在阅读任何指令前先看到当前模式
- `<explicit_instructions>` 作为**独立字段**（不再是 processedText 的内嵌内容）
- `<workflow_execution_override>` 作为**最后一条指令**，在模型回复前形成"最后提醒"

### 5.2 `<environment_details>` 结构（精简模式）

```
<environment_details>
{# Current Mode}（ACT MODE / PLAN MODE）
{planModeInstructions 文本}（仅 PLAN 模式下追加）
</environment_details>
```

**已精简/注释屏蔽的字段**：Visible Files、Open Tabs、Terminals、Recently Modified Files、Current Time、CWD Files、Workspace Configuration、Detected CLI Tools、Context Window Usage。

这些字段的旧代码保留但不生效。静态环境信息（OS/IDE/Shell/CWD）改由 System Prompt 的 SYSTEM_INFO_SECTION 提供。

### 5.3 斜杠命令与 Workflow 注入

用户输入 `/xxx 参数` 时按优先级匹配：内置命令 > MCP prompt > Workflow。Workflow 不进 System Prompt，而是按需注入到 User Message，末尾追加 `workflow_execution_override` 标签作为"大字报提醒"。

---

## 6. 第三道防线：Tool 协议（行动约束层）

核心思想：System Prompt 是"软约束"（模型可以违反），Tool 协议是"硬约束"（模型必须按 schema 写才能调通）。

### 6.1 两种 Tool 协议模式

- **XML 标签协议（默认）**：LLM 输出 XML 格式标签，Harness 用 XML 流式解析匹配 17 个内置工具
- **原生 Tool Calls**：LLM 输出 tool_calls JSON 格式，适用 OpenAI Responses API 等

### 6.2 关键工具的约束逻辑

| 工具 | 约束逻辑 | 防止的"跑偏" |
|------|---------|-------------|
| attempt_completion | 调用前必须验证任务要求，result 不能以问句结尾 | 未完成就宣告完成 |
| ask_followup_question | LLM 缺少参数时唯一合法的提问方式 | 模型瞎猜参数 |
| plan_mode_respond | PLAN 模式下只能用此工具输出想法 | 模型未经计划就动手 |
| replace_in_file | 硬性 XML 格式要求（完整行匹配、准确 marker） | 格式偏差导致编辑失败 |
| task_progress 参数 | 所有工具调用的可选参数，Harness 从中提取进度 | 忘记录入进度 |

---

## 7. 第四道防线：FocusChain（计划与进度锚定层）

FocusChain 是整个 Harness 中最具特色的子系统——把"任务进度"从模型的短期记忆外化为持久化、跨轮次、用户可编辑的状态机。

### 7.1 何时注入 FocusChain 指令

| 场景 | 注入的 prompt 类型 |
|------|-------------------|
| PLAN MODE 下每轮 | planModeReminder（弱提示） |
| 从 PLAN 切到 ACT MODE | initial（强要求创建清单）|
| 用户编辑了清单文件 | update + 提示"用户已修改" |
| 已达 remindClineInterval（默认 6）轮未更新进度 | reminder（督促更新） |
| 第 1 轮且无清单 | recommended（建议创建） |
| 多轮还没清单 | apiRequestCount（强烈催促） |

### 7.2 Interval 门控机制（★ 关键变更，2026-06-17）

默认不再每轮强制要求 `task_progress`，而是在**到达 remindClineInterval（默认 6 轮）时**才进行强制校验。

**关键设计**：
- `skipTaskProgress` 和 `skipSkillWorkflow` 使用**同一个布尔值**控制（通过 `reachedReminderInterval`）
- 当 `apiRequestsSinceLastTodoUpdate < 6` → 两者均跳过
- 当 `apiRequestsSinceLastTodoUpdate >= 6` → 两者均强制校验
- `apiRequestsSinceLastTodoUpdate` 在模型提交 `task_progress` 时重置为 0

**豁免工具**（始终不强制）：`todo`, `act_mode`, `plan_mode`

### 7.3 Todo 列表规则：内容细化 + 结果标注

当前要求（来自 FocusChain prompts）：
```
- [ ] 每项在完成之后要在列表之后标注结果或发现
      示例: - [x] 创建组件 (用了 React.FC + TypeScript)
- [ ] todo 列表要参考 skill、rules 和 workflows 来写
- [ ] 使用 task_progress 参数时需包含完整 checklist
```

### 7.4 task_progress 与工具调用的协同

```
         模型视角                         Harness 视角
         ───────                         ───────────
   工具调用: <write_to_file>
             <task_progress>           → ① 解析 task_progress
               - [x] 已完成1           → ② 写文件到磁盘
               - [x] 已完成2           → ③ 通知 UI 更新
               - [ ] 待完成            → ④ 重置 apiRequestsSinceLastTodoUpdate=0
             </task_progress>          → ⑤ 触发 telemetry
```

### 7.5 文件持久化与双向同步

FocusChain 的清单存储在磁盘文件上，支持持久化（任务中断后重启仍能看到进度）、外部可编辑（用户勾掉某项后系统感知）、双向同步（UI-磁盘-LLM 上下文实时一致）、文件监听（300ms awaitWriteFinish 防假阳性更新）。

---

## 8. 辅助防线 1：ContextManager（上下文治理）

解决三个问题：超长对话导致 token 超限（截断 + 摘要）、重复 read_file 浪费 token（自动去重）、tool_use/tool_result 配对错乱（自动修复）。

截断策略有四种：none（删除所有中间）、lastTwo（仅保留首尾）、half（删除一半 pair）、quarter（删除 3/4 pair）。

File Read 去重：每轮自动找出重复的 read_file/write_to_file 调用，只保留最后一次完整内容，历史版本替换为 [NOTE]。当节省低于 30% 时仍触发截断。

Auto-Condense（next-gen 模型默认）：先尝试 file read 去重优化（节省 ≥30% 就跳过），否则追加 `<summarize_task>` 指令让 LLM 自行生成摘要。摘要内容注入下一轮作为 user message。PreCompact Hook 可以在自动压缩前干预。

Truncation Notice：当历史消息被截断时，显式告知 LLM"上下文被截断"，避免它误以为早期信息仍然存在。

---

## 9. 辅助防线 2：PLAN/ACT 双模式约束

把"想"和"做"分离：PLAN 模式只用只读工具 + plan_mode_respond（不可写/执行），ACT 模式用全部工具。切换方式为用户手动。System Prompt 的 ACT_VS_PLAN 组件明确告知模型两个模式的区别。

---

## 10. 辅助防线 3：Hooks 扩展点

五个 Hook 点：TaskStart（任务开始时注入 context）、UserPromptSubmit（每次用户输入注入）、TaskResume（任务恢复时注入）、TaskCancel（可阻止取消）、PreCompact（可阻止自动压缩）。Hook 返回的 contextModification 被包装为 `<hook_context source="...">` 标签追加到 userContent 中。

---

## 11. 辅助防线 4：Rules/Skills/Workflows 三层配置

### 11.1 三者对比

| 维度 | Rules | Workflows | Skills |
|------|-------|-----------|--------|
| 注入层 | System Prompt 的 USER_INSTRUCTIONS | User Message（按需） | System Prompt（元数据）+ messages（按需） |
| 加载时机 | 每轮全量加载 | 用户输入 /name 时懒加载 | 元数据每轮，指令按需加载 |
| 作用范围 | 全局生效 | 单次任务 | 任务内可选调用 |
| 典型场景 | 编码规范、风格约束 | 复杂多步任务模板 | 可复用的 prompt 包 |

### 11.2 Rules 的 8 类注入源

固定顺序：preferredLanguage, globalClineRules, localClineRules, localCursorRules, localCursorRulesDir, localWindsurfRules, localAgentsRules, clineIgnore.

### 11.3 Skills 的三步加载

1. 元数据展示：在 System Prompt 中列出可用 Skills 的 name + description
2. 按需加载：LLM 调用 use_skill 工具时加载完整指令
3. 结果回流：技能内容以 tool_result 形式回流到 messages

---

## 12. 辅助防线 5：Tool 输出截断与压缩机制

### 12.1 定位与动机

Tool 的输出可能极长（例如读取大文件、搜索大量结果、运行长命令），如果**直接全量塞回 LLM 的 messages 数组**，会导致 Context window 快速耗尽、LLM 注意力分散、Token 费用增加。

因此 CygCode 在 **tool handler 层** 预先做"输出体积治理"。这与 ContextManager 的"消息历史治理"形成**双重防御**：

```
Tool 执行结果
    ↓
Layer A: Tool Handler 层（handler 内部裁剪）
  - 在 tool 结果返回 LLM 之前，先做体积控制
  - 例如：read_file 最多 1000 行、list_files 最多 200 个
    ↓
Layer B: ContextManager 层（消息历史裁剪）
  - 在 tool 结果进入 messages 后，再做整体去重/截断
  - 例如：重复 read_file 内容替换为 [NOTE]，25% 消息删除
    ↓
最终发给 LLM API

两层互相独立，互不耦合
```

### 12.2 各工具的截断点

| 截断机制 | 适用工具 | 默认值 | 说明 |
|---------|---------|--------|------|
| `truncateContent()` | read_file (PDF/DOCX/Excel/IPYNB)、MCP tools、MCP resources | **400 KB** | 全局字节级截断，后附截断提示 |
| `DEFAULT_MAX_LINES` | read_file | **1000 行** | 未指定 end_line 时，追加行号提示 |
| `listFiles(..., 200)` | list_files | **200 个文件** | 目录列表上限 |
| `extractTextFromExcel` | read_file (xlsx) | **50000 行/Sheet** | Excel 行级截断 |
| 20 MB 硬限制 | read_file (文本) | **20 MB** | 超限直接拒绝 |
| 无截断 | execute_command, web_fetch, search_files, attempt_completion 等 | - | 原样返回或用超时控制 |

### 12.3 Subagent 输出截断的移除

Subagent 的 `excerpt()` 截断函数（原上限 1200 字符）**已不再被调用**（2026-06-17 起）。当前仅做 `.trim()` 空白清理，主 agent 能看到 subagent 的完整输出。

但 subagent 内部仍受保护：read_file / MCP 工具的 400KB 全局限制、read_file 行数限制 1000 行、list_files 200 文件限制仍然有效。

### 12.4 Subagent 用户规则注入

Subagent 的 system prompt 同样通过 PromptRegistry 构建，componentOrder 中包含 USER_INSTRUCTIONS_SECTION，因此用户规则（`.clinerules/`, `.cursorrules`, `.agents/AGENT.md`, `.clineignore` 等）**自动注入到 subagent 的 system prompt** 中。无 `isSubagentRun` 过滤来排除规则，subagent 的 system prompt 结构与主 agent 几乎一致。

---

## 13. 核心结论：多轮不偏离的反馈闭环

```
第 1 轮：System Prompt 重建（宪法）+ User Message（任务 + 环境 + FocusChain 创建清单指令）
  -> LLM 输出：工具调用 + task_progress（含 todo list，完成项附结果标注）
  -> Harness 处理：写文件 + 通知 UI + 重置计数器 + 执行工具

第 N 轮：System Prompt 重建（同）+ User Message（新诉求 + 环境(精简) + FocusChain 当前进度提醒）
  -> LLM 同时看到：用户最新诉求 + 当前模式 + 自己之前承诺的清单（附结果标注）+ 催促提醒
  -> LLM 输出：工具调用 + task_progress（更新进度）
```

### 关键设计一览

| 设计 | 解决什么问题 |
|------|-------------|
| System Prompt 每轮重建 | 规则改动立即生效 |
| task_progress Interval 门控 | 默认 6 轮强制校验一次，避免每轮开销 |
| FocusChain 文件持久化 | 任务中断续接仍知道进度 |
| 用户可编辑清单 | 用户微调计划后系统感知 |
| 验证后再 attempt_completion | 防止目标偏移 |
| PLAN/ACT 双模式 | 强制先想再做 |
| Workflow override 标签 | 工作流不被忽略 |
| <environment_details> 精简 | 减少 token，LLM 注意力集中到模式切换 |
| Tool 输出 400KB 截断 | Handler 层预先控制体积 |
| File read 去重 | 重复文件节省 < 30% 仍触发截断 |
| Auto-condense + PreCompact Hook | 智能压缩 + 团队干预 |
| Subagent 规则自动注入 | 团队规范延伸到 subagent |

---

## 14. 核心工程原则

**原则一：不依赖模型记忆**——所有约束每轮重新推到模型面前。
**原则二：软硬约束分层**——软约束（System Prompt）模型应该遵守，硬约束（Tool schema）模型无法绕过。
**原则三：状态外化**——任务进度、环境状态都从模型内部搬到系统侧维护。
**原则四：每轮重建**——所有约束内容每轮重新计算、重新拼装、重新注入。
**原则五：多层冗余**——同一约束在多个地方独立表达，任何一处失效都有其他地方兜底。

---

> **一句话总结：CygCode Harness 的核心思想是把 LLM 当成一个"无状态、健忘、易分心"的协作者，所有约束通过 System Prompt + User Message + Tool 协议 + FocusChain + Tool 截断五个层面每轮重新注入，形成"对状态的外部控制"。它不做"模型自我管理"，而是做"系统侧强约束"。**

---

*本文整理自 CygCode 源码体系的 Harness 工程分析，聚焦方法论和设计思路，不涉及具体实现代码细节。*
*整合来源：CygCode Harness工程详解.md、FocusChain与TaskProgress提示词机制详解、Rules_Workflows_Skills加载机制详解、cygcode上下文管理*
*最后更新：2026-06-17*