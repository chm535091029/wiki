# Codex Agent Loop 架构深度分析 — 第二章

> **本文核心**: 围绕每一轮对话，从代码实现层面详细拆解 Agent 的执行流程。
> **基于**: `codex-rs/core/src/` 中的实际代码。

---

## 目录

1. [一句话速览](#1-一句话速览)
2. [**每轮对话的完整执行流程**](#2-每轮对话的完整执行流程)
   - [2.1 宏观全景](#21-宏观全景)
   - [2.2 Step 0: 事件循环 submission_loop](#22-step-0-事件循环-submission_loop)
   - [2.3 Step 1: 提交 submit_with_id](#23-step-1-提交-submit_with_id)
   - [2.4 Step 2: 中断 interrupt_task](#24-step-2-中断-interrupt_task)
   - [2.5 Step 3: 派发 user_input_or_turn](#25-step-3-派发-user_input_or_turn)
   - [2.6 Step 4: 创建 TurnContext](#26-step-4-创建-turncontext)
   - [2.7 Step 5: 启动任务 start_task](#27-step-5-启动任务-start_task)
   - [2.8 Step 6: RegularTask::run](#28-step-6-regulartaskrun)
   - [2.9 Step 7: run_turn](#29-step-7-run_turn)
   - [2.10 Step 8: 工具调用循环](#210-step-8-工具调用循环)

---

## 1. 一句话速览

```
用户输入 → 系统拼装提示词 → 发大模型 → 模型回工具调用
→ 执行工具 → 结果送回模型 → 模型继续 → 直到完成
```

---

## 2. 每轮对话的完整执行流程

### 2.1 宏观全景

```
提交 Op::UserInput
  ↓
[0] 事件循环 submission_loop
    while let Ok(sub) = rx_sub.recv()
    → match op 找对应 handler
  ↓
[1] submit_with_id
    tx_sub.send(sub) → 送进异步信道
  ↓
[2] Op::UserInput → user_input_or_turn
    → interrupt_task() 中断当前任务
    → new_turn_with_sub_id() 创建回合快照
    → spawn_task() 或 steer_input()
  ↓
[3] spawn_task / start_task
    → 创建 CancellationToken + RunningTask
    → 发 TurnStarted 事件

### 2.2 Step 0: 事件循环 submission_loop

**代码位置**: `handlers.rs:738-745`。这是整个 Agent 的"心脏"。

```rust
pub(super) async fn submission_loop(
    sess: Arc<Session>,
    config: Arc<Config>,
    rx_sub: Receiver<Submission>,
) {
    while let Ok(sub) = rx_sub.recv().await {
        // 每个 Submission 包含: id, op, trace, client_user_message_id
        match sub.op.clone() {
            Op::Interrupt              => interrupt(&sess).await,
            Op::UserInput { .. }       => user_input_or_turn(...).await,
            Op::RealtimeConversation*  => handle_realtime*(...).await,
            Op::ExecApproval { .. }    => exec_approval(...).await,
            Op::Compact                => compact(...).await,
            Op::Review { .. }          => review(...).await,
            Op::Shutdown               => shutdown(&sess, sub.id).await,
            Op::RunUserShellCommand    => run_user_shell_command(...).await,
            // ... 共约 20 种 Op
        }
    }
}
```

**设计思想**:
- async_channel 实现松耦合：外部通过 tx_sub.send() 提交，事件循环在另一个 task 消费
- 每个 Op 的处理独立，不阻塞事件循环
- rx_sub.recv() 是阻塞式接收，信道关闭自动退出

---

### 2.3 Step 1: 提交 submit_with_id

**代码位置**: `session/mod.rs:716-725`

```rust
pub async fn submit_with_id(&self, mut sub: Submission) -> CodexResult<()> {
    if sub.trace.is_none() {
        sub.trace = current_span_w3c_trace_context();
    }
    self.tx_sub.send(sub).await
        .map_err(|_| CodexErr::InternalAgentDied)?;
    Ok(())
}
```

调用链:
```
TUI → CodexThread::submit(Op::UserInput)
  → Codex::submit()
    → Session::submit_with_id(Submission { op, id, trace })
      → tx_sub.send(sub)  → 事件循环收到
```

---

### 2.4 Step 2: 中断 interrupt_task

**代码位置**: `session/mod.rs:3307-3314`

```rust
pub async fn interrupt_task(self: &Arc<Self>) {
    self.abort_all_tasks(TurnAbortReason::Interrupted).await;
}
```

**abort_all_tasks 做的事情**:
```
① 取出现有 active_turn.task
② 调用 CancellationToken.cancel()
   → 让正在运行的任务优雅停止
③ 发 TurnAborted 事件
④ 清空 pending approvals
⑤ 检查是否需要启动新回合
```

中断标记会在历史中插入 developer 消息:
```
developer: "回合被用户中断，用户希望换方向。"
```

---

### 2.5 Step 3: 派发 user_input_or_turn

**代码位置**: `handlers.rs:194-296`

```
user_input_or_turn_inner() 的逻辑:

① 从 Op 提取 fields: items, environments, additional_context...

② 应用 SessionSettingsUpdate (环境、输出 schema 等)

③ new_turn_with_sub_id() → 创建 TurnContext

④ 尝试 steer_input()

   情况 A: 已有活跃回合(模型正在回复)
     → steer_input() 把输入排到 input_queue
     → 等待模型当前回复完成后再消费

   情况 B: 没有活跃回合(模型空闲)
     → spawn_task(turn_context, task_input, RegularTask)
     → 启动新任务执行完整回合
```

**Steer 机制** (`session/mod.rs:3221-3294`):
```rust
pub async fn steer_input(&self, input, additional_context, ...) -> Result<String, SteerInputError> {
    // 验证: 必须有活跃的 Regular 任务
    
    // 把输入合并到 input_queue
    self.input_queue.extend_pending_input(...).await;
    Ok(active_turn_id)
}
```

---

### 2.6 Step 4: 创建 TurnContext

**代码位置**: `turn_context.rs:588-660`

TurnContext 是一次回合的**不可变快照**，包含:
```
TurnContext:
  sub_id: String                ← 回合唯一 ID
  config: SessionConfiguration  ← 配置快照
  model_info: ModelInfo         ← 模型信息
  cwd: AbsolutePathBuf          ← 工作目录
  environments: ResolvedTurnEnvironments  ← 执行环境
  permission_profile: PermissionProfile  ← 权限
  approval_policy: ApprovalPolicy         ← 批准策略
  personality: Option<Personality>         ← 人格设定
  features: FeatureSet                    ← 功能开关
  turn_skills: TurnSkills                 ← 本回合技能
  collaboration_mode: CollaborationMode   ← 协作模式
  turn_timing_state: TurnTimingState      ← 计时
  turn_metadata_state: TurnMetadataState  ← 元数据
  extension_data: ExtensionData           ← 扩展数据
```

**设计思想**: 一旦创建就不可变。保证同回合内模型看到一致配置。

---

### 2.7 Step 5: 启动任务 start_task

**代码位置**: `tasks/mod.rs:316-390`

```
start_task 流程:

① 创建 CancellationToken (用于优雅取消)
② 记录开始时间 started_at
③ 注册到 active_turn.task
④ 发送 TurnStarted 事件给外部监听
⑤ 触发 Goals::TurnStarted 事件
⑥ spawn 后台任务:
    task.run(session_ctx, ctx, input, cancellation_token)
    完成后:
    - 记录 token 用量到状态
    - 更新历史版本号
    - 发 TurnComplete 事件
    - 触发 Goals 检查
```

**SessionTask trait**:
```rust
trait SessionTask: Send + Sync {
    fn kind(&self) -> TaskKind;      // Regular/Compact/Review/UserShell
    fn span_name(&self) -> &'static str;
    async fn run(...) -> Option<String>;
    async fn abort(...);
}
```

四种任务类型:
| TaskKind | 用途 | 触发方式 |
|----------|------|---------|
| Regular | 普通对话回合 | 用户输入 |
| Compact | 上下文压缩 | 自动/compact命令 |
| Review | 审查子回合 | review命令 |
| UserShell | Shell命令执行 | RunUserShellCommand |

    → 后台 spawn RegularTask::run
  ↓
[4] RegularTask::run (循环)
    → run_turn() → 执行一次采样+工具执行
    → 检查 input_queue 有无排队输入
    → 有则继续循环(同回合ID)，无则返回
  ↓
[5] run_turn() 内部流水线
    ① run_pre_sampling_compact()  → 回合前压缩
    ② record_context_updates()    → 注入上下文
    ③ build_skills_and_plugins()  → 解析技能
    ④ run_hooks_and_record_inputs()
    ⑤ loop { 采样-执行循环 }
       clone_history() → run_sampling_request()
       → 模型回工具: 执行 → continue
       → 模型回文本: 记录 → break
```

### 2.8 Step 6: RegularTask::run — 回合主循环

**代码位置**: `tasks/regular.rs:36-85`

```rust
impl SessionTask for RegularTask {
    async fn run(self: Arc<Self>, session: Arc<SessionTaskContext>,
                 ctx: Arc<TurnContext>, input: Vec<TurnInput>,
                 cancellation_token: CancellationToken) -> Option<String> {
        // 1. 发 TurnStarted 事件
        sess.send_event(ctx.as_ref(), EventMsg::TurnStarted(
            TurnStartedEvent { turn_id: ..., trace_id: ..., ... }
        )).await;

        // 2. 消费预热 session
        let prewarmed = sess.consume_startup_prewarm_for_regular_turn(...).await;

        // 3. run_turn 循环
        loop {
            let last = run_turn(sess, ctx, ext_data,
                next_input, prewarmed.take(), cancel_token).await;

            if !sess.input_queue.has_pending_input(&sess.active_turn).await {
                return last;  // 无排队输入 → 回合结束
            }
            next_input = Vec::new();  // 有排队 → 继续
        }
    }
}
```

**设计思想**:
- RegularTask::run 负责"多轮交互"，run_turn 负责"单轮采样+工具执行"
- 模型完成一轮后检查 input_queue → 有排队就继续，无排队就结束

---

### 2.9 Step 7: run_turn — 内部流水线

**代码位置**: `turn.rs:136-422`。这是最核心的函数。

```
                           输入: sess, turn_context, input, session, cancel_token

① run_pre_sampling_compact(sess, turn_context, client_session)
   → auto_compact_token_status() 检查 token
   → 超限则 run_auto_compact() 压缩

② record_context_updates_and_set_reference_context_item(turn_context)
   → reference_context_item 为空? → build_initial_context() 完整注入
   → 不为空? → build_settings_update_items() 只注入 diff
   → 记录到历史，更新 baseline

③ build_skills_and_plugins(sess, turn_context, input, cancel_token)
   → 解析 @-mention 的 Skill/Plugin
   → 返回 injection_items + connector set

④ run_pending_session_start_hooks()
   → 运行未完成的 session-start hooks

⑤ run_hooks_and_record_inputs()
   → 对每个输入运行 inspect_pending_input hook
   → Hook 可阻止/修改输入

⑥ ==== 采样-执行循环 ====
   loop {
     a. 获取 pending_input (排队输入)
     b. run_hooks_and_record_inputs(pending_input)
     c. clone_history().for_prompt() → 构建模型输入
     d. run_sampling_request(...) → 发送模型
        Ok(needs_follow_up=true)  → 模型调了工具 → continue
        Ok(needs_follow_up=false) → 模型回答了 → break
        Err(TurnAborted) → break
     e. auto_compact_token_status() → 超限则压缩 → continue
     f. run_turn_stop_hooks() → 检查 stop
   }

⑦ 返回 last_agent_message
```

**run_turn 代码片段**:
```rust
pub(crate) async fn run_turn(sess, turn_context, ..., input, ...) -> Option<String> {
    let mut client_session = prewarmed.unwrap_or_else(|| sess.services.model_client.new_session());

    // 回合前压缩
    run_pre_sampling_compact(&sess, &turn_context, &mut client_session).await?;

    // 记录上下文
    sess.record_context_updates_and_set_reference_context_item(turn_context.as_ref()).await;

    // 构建技能注入
    let (injection_items, _) = build_skills_and_plugins(&sess, turn_context, &input, &cancel).await?;

    // hooks
    run_pending_session_start_hooks(&sess, &turn_context).await;
    run_hooks_and_record_inputs(&sess, &turn_context, &input).await;

    // 采样-执行循环
    loop {
        let pending = if can_drain { input_queue.get_pending().await } else { Vec::new() };
        let hist = sess.clone_history().await.for_prompt(&model_info.input_modalities);
        match run_sampling_request(sess, turn_context, ..., hist).await {
            Ok(r) => if !r.needs_follow_up { break; } else { continue; }
            Err(_) => break,
        }
    }
}
```

---

### 2.10 Step 8: 工具调用循环 — run_sampling_request

**代码位置**: `turn.rs:999-1100`

这是实际调用模型 API 并处理工具调用的函数。

```
run_sampling_request 流程:
                           
① built_tools() → 装配 ToolRouter
   - 收集 MCP 工具、扩展工具、内置工具、动态工具
   - 按权限/功能开关/协作模式过滤
   - 返回 Arc<ToolRouter>

② get_base_instructions() → 获取系统指令
   - model_provider_info.base_instructions()
   - + review_prompt (可选)
   - + developer_instructions (可选)

③ 创建 ToolCallRuntime
   - 持有 ToolRouter + Session 引用
   - 负责并行/串行执行工具调用

④ 构建 Prompt
   Prompt {
     input: Vec<ResponseItem>,    ← 历史 + 上下文 + 当前输入
     tools: Vec<ToolSpec>,        ← 工具定义列表
     parallel_tool_calls: bool,   ← 是否允许并行调用
     base_instructions: BaseInstructions,  ← 系统指令
     personality: Option<Personality>,
     output_schema: Option<Value>,
   }

⑤ try_run_sampling_request 循环
   model_client.session_streaming_request(prompt)
   → 模型返回 SSE 事件流:

   事件流循环:
   ┌────────────────────────────────────────┐
   │ ResponseOutputText(text)                │
   │   → 发送 text delta 事件给 TUI          │
   │   → 累积到当前 assistant 消息           │
   │   → continue                            │
   │                                         │
   │ ResponseFunctionCall(name, args)        │
   │   → dispatch_tool_call(name, args)      │
   │     ├ PreToolUse Hook                   │
   │     ├ 权限检查 (Allow/Deny/OnRequest)    │
   │     ├ Guardian 审查 (如果需要)           │
   │     ├ 执行工具(沙箱内)                   │
   │     ├ PostToolUse Hook                  │
   │     └ 结果返回                           │
   │   → 记录工具调用结果到历史               │
   │   → needs_follow_up = true               │
   │                                         │
   │ ResponseComplete                        │
   │   → 完成，记录最终消息                   │
   │   → needs_follow_up = false              │
   │                                         │
   │ ResponseError                           │
   │   → 判断是否可重试                      │
   │   → 可重试: 重试 (最多 max_retries 次)   │
   │   → 不可重试: 返回 Err                  │
   └────────────────────────────────────────┘

⑥ 返回 SamplingRequestResult { needs_follow_up, last_agent_message }
```

**built_tools 函数** (`turn.rs:1101+`):
```rust
pub(crate) async fn built_tools(sess, turn_context, cancellation_token) -> CodexResult<Arc<ToolRouter>> {
    // 1. 获取 MCP 工具
    let mcp_tools = mcp_connection_manager.list_all_tools().await;
    
    // 2. 获取扩展工具
    let extension_tools = extension_tool_executors(...);
    
    // 3. 构建 ToolRegistry
    //    内置工具: shell, apply_patch, tool_search, view_image...
    //    MCP 工具: 外部服务暴露的工具
    //    扩展工具: 扩展注册的工具
    //    动态工具: 运行时动态添加的
    
    // 4. 过滤:
    //    - permission_profile 是否允许
    //    - feature flag 是否开启
    //    - collaboration_mode 是否允许(Plan模式限制)
    //    - @-mention 是否提及
    
    // 5. 返回 ToolRouter
    ToolRouter::new(tool_registry, params)
}
```

**工具执行的审批流程**:
```
FunctionCall → dispatch_tool_call()
  → PreToolUse Hooks (可阻止/修改)
  → 权限检查:
    Allow → 执行工具
    Deny  → 返回"操作被拒绝"给模型
    OnRequest → Guardian 审查
      Guardian: Allow → 执行
      Guardian: Deny  → 返回拒绝理由
      Guardian: Escalate → 问用户
  → PostToolUse Hooks (审计/记录)
  → 结果送回历史
```

---

## 3. 提示词/消息的最终面貌 — 每一轮怎么组装的

### 3.1 一句话概括

```
发给模型的"提示词" = base_instructions + 历史消息列表 + 工具定义

历史消息列表由两个阶段组装:
阶段一: run_turn → record_context_updates()
  把"上下文片段"打包成 developer/user 消息, 写入 ContextManager

阶段二: run_sampling_request → build_prompt()
  从 ContextManager 取出完整历史 + tools + instructions → 发模型
```

### 3.2 阶段一：build_initial_context — 完整注入

**代码位置**: `session/mod.rs:2737-2960`

第一轮或压缩后首次回复时调用, 生成所有上下文片段:

```
① 创建三个容器:
   developer_sections: Vec<String>       ← 放在 developer 消息里
   contextual_user_sections: Vec<String>  ← 放在 user 消息里
   separate_developer_sections: Vec<String>

② 依次注入开发者片段:
   1. model_switch_message (如果模型换过)
   2. PermissionsInstructions.render()
      → "你可以读写 /home/user/project"
      → "需要批准: 删除文件, 安装包"
   3. developer_instructions (用户自定义)
   4. CollaborationModeInstructions.render()
      → "当前模式: 编码模式"
   5. PersonalitySpecInstructions.render()
   6. AppsInstructions.render() (应用列表)
   7. AvailableSkillsInstructions.render() (技能列表)
   8. AvailablePluginsInstructions.render() (插件列表)
   9. Extension context contributors

③ 注入用户上下文片段:
   1. UserInstructions (AGENTS.md)
      → "使用 pnpm 而不是 npm"
   2. EnvironmentContext.render()
      → "工作目录: /home/user/project"
      → "OS: Linux, Shell: zsh"
   3. Extension PromptSlot::ContextualUser

④ 组装成消息:
   items = [
     build_developer_update_item(developer_sections)
       → 一条 developer 消息, 包含所有策略指令
     separate_developer_sections 各成一条
     multi_agent_v2_usage_hint (如果有)
     build_contextual_user_message(contextual_user_sections)
       → 一条 user 消息, 包含环境/规则
   ]
```

**实际输出示例**:
```
items[0] = ResponseItem::Message {
    role: "developer",
    content: [
        "## Permissions",
        "你可以读写 /home/user/project。",
        "删除文件需要用户批准。",
        "",
        "## Collaboration Mode",
        "当前模式: 编码模式。",
        "",
        "## Available Skills",
        "- python-testing: 运行测试用 `just test -p <包名>`",
    ],
}

items[1] = ResponseItem::Message {
    role: "user",
    content: [
        "## User Instructions",
        "来自 AGENTS.md:",
        "- 使用 pnpm 而不是 npm",
        "- 不要修改 node_modules/",
        "",
        "## Environment",
        "工作目录: /home/user/project",
        "OS: Linux",
    ],
}
```

### 3.3 增量更新 — build_settings_update_items

**代码位置**: `context_manager/updates.rs:209-243`

当 reference_context_item 存在时(不是第一轮/未压缩), 不完整注入, 只注入变化:

```
build_settings_update_items(previous, next, shell, exec_policy):

对比 previous TurnContextItem 和当前状态, 生成:
① build_environment_update_item()     → 环境变更
② build_model_instructions_update()   → 模型变更
③ build_permissions_update_item()     → 权限变更
④ build_collaboration_mode_update()   → 模式变更
⑤ build_realtime_update_item()        → 实时状态变更
⑥ build_personality_update_item()     → 人格变更

全合并成一条 developer 消息
```

**增量意义**:
```
第一轮: [完整上下文(大量)] [用户消息]
第二轮: [历史] [增量: 空] [用户消息]       ← 几乎零开销
第三轮: [历史] [增量: 权限变了] [用户消息]  ← 仅变化部分
```



### 3.4 ContextualUserFragment trait — 统一接口

**代码位置**: `codex-context-fragments/src/`

所有上下文片段实现统一 trait:

```rust
pub trait ContextualUserFragment: Send {
    fn format(&self) -> String;                    // 渲染为文本
    fn estimated_token_count(&self) -> usize;       // token估算
    fn can_skip(&self) -> bool;                     // 预算不够时跳过
    fn role(&self) -> &'static str;                 // "developer"/"user"
}
```

**role 分配**:

| developer (注入策略) | user (注入上下文) |
|---|---|
| PermissionsInstructions | UserInstructions (AGENTS.md) |
| CollaborationModeInstructions | EnvironmentContext |
| PersonalitySpecInstructions | SkillInstructions |
| AvailableSkillsInstructions | SubagentNotification |
| AvailablePluginsInstructions | UserShellCommand |
| AppsInstructions | LegacyModelMismatchWarning |
| ModelSwitchInstructions | InternalModelContextFragment |
| RealtimeStart/EndInstructions | AdditionalContextUserFragment |
| ImageGenerationInstructions | |
| HookAdditionalContext | |
| ApprovedCommandPrefixSaved | |
| NetworkRuleSaved | |

### 3.5 阶段二: build_prompt — 组装最终 Prompt

**代码位置**: `turn.rs:970-987`

```rust
pub(crate) fn build_prompt(
    input: Vec<ResponseItem>,    // 历史+上下文(阶段一的输出)
    router: &ToolRouter,         // built_tools() 的输出
    turn_context: &TurnContext,
    base_instructions: BaseInstructions,
) -> Prompt {
    Prompt {
        input,                              // 消息列表
        tools: router.model_visible_specs(), // 工具定义
        parallel_tool_calls: true/false,
        base_instructions,                   // 系统指令
        personality: turn_context.personality,
        output_schema: ...,
        output_schema_strict: ...,
    }
}
```

**BaseInstructions 构成**:
```
BaseInstructions.text = [
    model_provider.base_instructions(),  // 模型默认
    + review_prompt (可选),               // 审查模式
    + developer_instructions (可选),      // 用户自定义
].join("\n")
```

### 3.6 模型实际看到的完整结构

```
───────────────────────────────────
[system / base_instructions]
你是 Codex。可用工具: shell, apply_patch... 必须遵守权限...
───────────────────────────────────
[developer]  ← build_initial_context
## Permissions
可写 /home/user/project。删除文件需批准。

## Collaboration Mode
编码模式。

## Available Skills
- python-testing: run `just test -p <包名>`
───────────────────────────────────
[user]  ← contextual_user_sections
## User Instructions (AGENTS.md)
使用 pnpm 而不是 npm。

## Environment
工作目录: /home/user/project | OS: Linux
───────────────────────────────────
[user]  ← 历史: 用户问题
帮我写排序...
───────────────────────────────────
[assistant]  ← 历史: 助手回复
我来创建...
───────────────────────────────────
[tool: apply_patch]  ← 历史: 工具结果
文件已创建
───────────────────────────────────
[assistant]  ← 历史: 最终回复
完成...
───────────────────────────────────
[developer]  ← 增量更新(第二轮)
权限已更新: 现在也可读 /usr/local
───────────────────────────────────
[user]  ← 当前轮用户输入
加个测试
```

### 3.7 完整构建流程图

```
Session::build_initial_context(turn_context)
  │
  ├── developer_sections:
  │   [模型切换][权限][dev指令][协作模式]
  │   [人格][Apps][技能][插件][Extension]
  │
  ├── contextual_user_sections:
  │   [AGENTS.md][环境信息][Extension]
  │
  ├── build_developer_update_item() → developer 消息
  └── build_contextual_user_message() → user 消息
        ↓
  ContextManager.history 写入
        ↓
  run_sampling_request:
    ├── built_tools() → ToolRouter
    ├── get_base_instructions() → BaseInstructions
    └── build_prompt(history, tools, base_instructions)
          ↓
    Prompt → session_streaming_request(prompt)
```

### 3.8 关键设计思想

```
① 分层: base_instructions(系统) + developer(策略) + user(环境) + 历史(对话)
② 增量: 第一轮完整, 后续只变变化, 压缩后重建
③ 统一: 所有片段实现 ContextualUserFragment, 可动态裁剪
④ 分离: tools 在 Prompt.tools, 不混在消息里
⑤ role: developer = 指令, user = 上下文
```

---

## 4. 上下文管理策略

> 本章深入分析 Codex 如何管理对话历史、上下文注入、Token 预算和自动压缩。
> 核心文件: `context_manager/history.rs`, `compact.rs`, `state/session.rs`, `state/auto_compact_window.rs`

---

### 4.1 一句话概括

```
上下文管理 = 历史记录 + Token 预算跟踪 + 增量更新 + 自动压缩

ContextManager.history  = Vec<ResponseItem>    ← 所有历史消息
reference_context_item  = Option<TurnContextItem> ← 最近一次上下文快照
AutoCompactWindow       = { ordinal, prefill_tokens } ← 当前窗口基线
```

**三件大事**:
```
① 写: record_conversation_items → 追加到 history
② 读: for_prompt → 归一化后发给模型
③ 缩: auto_compact → 超限时摘要+替换+重建基线
```

---

### 4.2 ContextManager — 上下文核心数据结构

**代码位置**: `context_manager/history.rs:34-51`

```rust
pub(crate) struct ContextManager {
    /// 消息列表, 最旧在前
    items: Vec<ResponseItem>,

    /// 每次历史被重写(压缩/回滚)时递增
    history_version: u64,

    /// Token 用量信息 (来自 API 返回)
    token_info: Option<TokenUsageInfo>,

    /// 上下文基线快照, 用于增量更新 diff
    /// None → 下一轮完整注入
    /// Some → 只注入与当前状态的差异
    reference_context_item: Option<TurnContextItem>,
}
```

**历史记录写入流**:
```
record_items(items) → 对每个 item:
① is_api_message? → 跳过非 API 消息(内部事件)
② process_item() → 按 TruncationPolicy 截断工具输出
③ push → items 末尾
④ 并行: persist_rollout + send_raw 通知客户端
```

**for_prompt — 读历史准备发给模型**:
```
for_prompt(input_modalities) → normalize_history():
① ensure_call_outputs_present()   ← 补齐缺失的工具结果
② remove_orphan_outputs()         ← 移除孤立的工具结果
③ strip_images_when_unsupported() ← 不支持图片时替换占位符
④ 返回 self.items
```

---

### 4.3 reference_context_item — 增量更新基线

**代码位置**: `session/mod.rs:2996-3026`

这是上下文管理最巧妙的设计。核心思想:

```
reference_context_item 是"上下文基线快照"。

每个正常用户回合结束时, 记录当前配置快照为 TurnContextItem。

下一回合开始时:
  - reference_context_item == None → 完整 build_initial_context
  - reference_context_item == Some → 只 build_settings_update_items(diff)
```

**完整生命周期**:
```
Session 启动 → reference_context_item = None

第一轮用户输入:
  record_context_updates_and_set_reference_context_item()
  → reference 是 None
  → build_initial_context() ← 完整注入(10+个片段)
  → 写入 history + 设置 reference = 当前 TurnContextItem

第二轮用户输入:
  record_context_updates_and_set_reference_context_item()
  → reference 是 Some
  → build_settings_update_items() ← 只 diff 变化
  → 写入 history(如果变化不为空)
  → 更新 reference = 新 TurnContextItem

... 持续 ... 

压缩/回滚发生:
  → replace_history() + set_reference_context_item(None)
  → 下一轮: 完整 build_initial_context
```

**为什么增量重要**:
```
第一轮:  完整上下文(约3000 tokens) → developer + user 消息
第二轮:  增量(0-100 tokens)        → 仅"环境变了"的 diff
第三轮:  增量(0 tokens)            → 什么都没变, 不注入
...
第 N 轮: 增量(0 tokens)            → 不膨胀

对比"每轮完整注入": 10轮冗余浪费 30000 tokens
增量方案: 每轮约 0-200 tokens, 累积开销极低
```

---

### 4.4 Token 预算跟踪 — AutoCompactWindow

**代码位置**: `state/auto_compact_window.rs:1-70`

两级检测系统:

```
1️⃣ AutoCompactTokenLimitScope::Total
   → 直接比较: active_context_tokens > model.auto_compact_token_limit()
   → 超了 → 触发压缩

2️⃣ AutoCompactTokenLimitScope::BodyAfterPrefix
   → 减去前缀, 只算增长:
     scope = active_tokens - prefill_baseline
     scope > limit → 触发压缩
   → "前缀" = base_instructions + 不可变系统提示
   → 更精确地判断"增长空间还剩多少"
```

**AutoCompactWindow 结构**:
```rust
struct AutoCompactWindow {
    ordinal: u64,                       // 窗口序号(递增)
    prefill_input_tokens: Option<       // 基线 token 数
        AutoCompactWindowPrefill        // ServerObserved | Estimated
    >,
}
```

**检测调用点** (run_turn 采样循环):
```
采样请求完成后:
  auto_compact_token_status(sess, turn_context)
  → 检查 token_limit_reached

  如果 true && needs_follow_up:
    → 上下文超限 + 模型还需要继续
    → run_auto_compact(... MidTurn)
    → 压缩后继续

  如果 true && !needs_follow_up:
    → 上下文超限 + 模型回答完了
    → run_auto_compact(... MidTurn)
    → 压缩后结束

  否则: 正常运行
```

---

### 4.5 历史截断 — process_item

**代码位置**: `context_manager/history.rs:367-400`

每次记录新 item 时, 系统对工具输出截断:
```
process_item(item, policy):
  FunctionCallOutput / CustomToolCallOutput:
    → 用 truncation_policy * 1.2 截断输出
    → 防止过大的工具结果撑爆上下文
  Message / Reasoning / FunctionCall:
    → 直接克隆
```

---

### 4.6 回合前压缩 — run_pre_sampling_compact

**代码位置**: `turn.rs:784-860`

```
① maybe_run_previous_model_inline_compact()
   用户切换模型(大→小):
   - 旧模型窗口 > 新模型窗口
   - 当前 token > 新模型窗口
   → 用旧模型做压缩(旧窗口大, 能装下完整历史)
   → 摘要替换到历史中

② auto_compact_token_status() 检查
   token_limit_reached:
   → run_auto_compact(DoNotInject, ContextLimit, PreTurn)
   → reference_context_item 清空
   → 下一轮完整 build_initial_context
```

**模型降级压缩示例**:
```
用户: gpt-5.3-codex(128k) → gpt-4o(32k)
当前历史 50k tokens > 32k 窗口
→ 用 gpt-5.3-codex(128k 窗口) 读取完整历史生成摘要
→ 替换到历史中
→ gpt-4o 窗口够用
```


---

### 4.7 自动压缩 — run_auto_compact

**代码位置**: `turn.rs:862-917`, `compact.rs:70-200`

当 token 超限时, 触发自动压缩。支持三种实现:

```
run_auto_compact(reason, phase, initial_context_injection)
  │
  ├── 远程压缩 V2: 调用模型 API 做摘要 (Feature::RemoteCompactionV2)
  ├── 远程压缩 V1: 调用模型 API 做摘要
  └── 本地压缩: 也用模型, 但在本地会话中完成

  三种实现都会:
    ① 收集历史和工具定义
    ② 发送压缩 prompt 给模型
    ③ 用摘要替换历史
    ④ 清空 reference_context_item
    ⑤ 如果 initial_context_injection == BeforeLastUserMessage,
       在最后一个用户消息前注入完整上下文
```

**压缩后的历史结构**:
```
压缩前:
  [developer:上下文] [user:消息1] [assistant:回复1] [tool:结果1] ... [user:消息N]
                                                                       ↑ 当前

压缩后 (无注入):
  [摘要: "用户要求排序, 助手创建了文件..."]
  [user:消息N]                                    ← 保留最后的消息

压缩后 (BeforeLastUserMessage):
  [developer:上下文]                               ← 重新注入
  [user:消息1]                                    ← 用户消息
  [摘要: "用户要求排序, 助手创建了文件..."]
```

**压缩摘要示例**:
```
## Summary
**用户要求**: 帮我创建一个排序算法, 然后添加测试
**执行过程**: 创建了 bubble_sort.py, 包含冒泡排序实现
             创建了 test_bubble_sort.py, 包含单元测试
**关键决策**: 选择了 O(n²) 的冒泡排序
**当前状态**: 文件和测试都已就绪
```

---

### 4.8 持久化 — Rollout + TurnContextItem

上下文不仅存在内存中, 还会通过 rollout 系统持久化到磁盘。

**持久化的上下文**:
```
RolloutItem::TurnContext(turn_context_item)      ← 上下文基线快照
RolloutItem::Compacted(compacted_item)            ← 压缩结果
RolloutItem::EventMsg(TokenCount(info))            ← Token 用量
```

**回滚的上下文恢复**:
```
rollback(num_turns):
① flush() 持久化当前历史
② load_history() 从 store 加载历史
③ drop_last_n_user_turns(num_turns)
④ 如果回滚裁剪了上下文基线的 developer 消息
   → reference_context_item = None
   → 下一轮完整 build_initial_context
⑤ replace_history() 替换内存历史
```

---

### 4.9 上下文流完整时序图

```
时间轴
│
├─ 会话启动
│  SessionState { history: [], reference_context_item: None }
│
├─ 第一轮用户输入
│  record_context_updates_and_set_reference_context_item()
│  → reference=None → build_initial_context() → 完整注入
│  → history: [developer:权限/技能, user:环境/AGENTS.md]
│  → reference = TurnContextItem{config, env, ...}
│
│  run_sampling_request()
│  → clone_history().for_prompt()
│  → [developer][user][user:提问] → build_prompt(历史, tools)
│  → 发模型
│
│  模型回复(含工具调用) → history += [assistant, tool] → continue
│  模型回复(文本)       → history += [assistant] → break
│
├─ 第二轮用户输入
│  record_context_updates_and_set_reference_context_item()
│  → reference=Some(上一轮快照)
│  → build_settings_update_items() → 对比: 什么都没变
│  → 返回空Vec (不注入任何上下文!)
│  → reference = 新 TurnContextItem
│
│  run_sampling_request()
│  → history = [developer][user][第一轮历史][user:新提问]
│  → 没有新的上下文注入! 节省约3000 tokens
│
├─ 第六轮用户输入 (累积大量 history)
│  auto_compact_token_status() 检测: token_limit_reached = true
│  run_auto_compact(MidTurn)
│  → 压缩: history = [摘要:1-5轮][user:当前输入]
│  → reference_context_item = None
│  → 下一轮: 完整 build_initial_context
│
└─ 用户切换模型 (gpt-5.3-codex(128k) → gpt-4o(32k))
   → maybe_run_previous_model_inline_compact()
   → 旧模型容量 128k > 当前历史 50k, 能一次读完
   → 生成摘要 → 替换到新模型中
```

---

### 4.10 关键设计思想总结

```
① 增量更新: reference_context_item 做 diff
   非首轮 → 只注入变化, 节省 ~3000 tokens/轮

② 两级 token 检测: Total / BodyAfterPrefix
   Total: 简单粗暴, 超过就压缩
   BodyAfterPrefix: 减去前缀只算增长, 更精确

③ 三层压缩触发:
   回合前(run_pre_sampling_compact): 确保能发出去
   回合中(MidTurn): 模型继续但窗口不够
   手动(compact 命令): 用户主动触发

④ 三种压缩实现:
   远程 V2 / 远程 V1 / 本地

⑤ 模型降级特殊处理:
   大→小模型时用旧模型压缩, 确保能装下

⑥ 归一化保证一致性:
   每次读历史 normalize
   补齐缺失工具结果, 移除孤立, 裁剪图片

⑦ 持久化保证可恢复:
   TurnContextItem 持久化到 rollout
   启动/回滚时重建基线
```

---

---

## 5. 防跑偏体系 — 如何确保模型遵循规则、Skill 和用户意图

> 本章全面分析 Codex 如何在多步推理中防止模型偏离预设规则、不遵循 Skill 和
> 用户指令。这是整个项目最重要但也最容易被忽视的工程质量。
> 
> 核心文件: `guardian/`, `tools/registry.rs`, `hook_runtime.rs`,
> `session/turn.rs`, `context/`, `session/mod.rs`

---

### 5.1 四层防御总览

```
┌────────────────────────────────────────────────────────────────────┐
│  Layer 1: Prompt 层（软约束）                                         │
│  base_instructions + developer 消息 + 输出 Schema                    │
│  → 告诉模型该做什么/不该做什么                                         │
│                                                                     │
│  Layer 2: 工具池过滤（硬约束）                                         │
│  built_tools → ToolRouter → model_visible_specs                      │
│  → 模型只能看到被允许的工具, 不可用的完全不可见                          │
│                                                                     │
│  Layer 3: 执行前拦截（Hook + Guardian + 审批）                         │
│  PreToolUseHook → 阻止/重写                                           │
│  PermissionCheck → 是否有权限                                         │
│  Guardian 自动审查 → 风险评估                                         │
│  用户审批 → 高风险操作等待确认                                          │
│                                                                     │
│  Layer 4: 执行后验证（PostToolUseHook + Guardian + 中止）              │
│  PostToolUseHook → 检查结果, 可替换反馈                                │
│  StopHook → 回合结束整体审查                                           │
│  Guardian Followup + CircuitBreaker → 后续审查/阻断                    │
└────────────────────────────────────────────────────────────────────┘
```

---

### 5.2 Layer 1: Prompt 层软约束

#### 5.2.1 base_instructions — 系统级指令

**代码位置**: `turn.rs:1011`

每个采样请求都携带:
```rust
BaseInstructions {
    text: [
        model_provider.base_instructions(),  // 模型默认指令
        + review_prompt,                       // 审查模式追加
        + developer_instructions,              // 用户自定义
    ].join("\n")
}
```

模型始终能看到"我是谁, 能做什么, 不能做什么"。

#### 5.2.2 Developer 消息 — 策略/规则注入

40+ 种 ContextualUserFragment 通过 developer role 注入:

| 约束片段 | 作用 | role |
|---|---|---|
| PermissionsInstructions | 文件读写范围、审批要求 | developer |
| CollaborationModeInstructions | 工作模式(编码/审查) | developer |
| PersonalitySpecInstructions | 回复风格 | developer |
| AvailableSkillsInstructions | 技能规则 | developer |
| AvailablePluginsInstructions | 插件约束 | developer |
| AppsInstructions | App 可用范围 | developer |
| UserInstructions (AGENTS.md) | 用户规则 | user |
| EnvironmentContext | 当前环境 | user |

**软约束变"硬"的机制**:
```
① developer role: 模型对 developer 消息更重视(API 定义)
② 最前面: 最先被模型"看到"
③ 一致性: 每轮重复注入, 不会被遗忘
④ 分层: base_instructions > developer > user
```

#### 5.2.3 output_schema_strict — 强制格式

**代码位置**: `turn.rs:970-987`, `guardian/prompt.rs`

Guardian 审查使用 structured output:
```json
{
    "riskLevel": "low" | "medium" | "high" | "critical",
    "userAuthorization": "automatic" | "userRequired",
    "outcome": "approved" | "denied",
    "rationale": "原因..."
}
```

`output_schema_strict=true` → API 强制校验格式 → 格式不对自动重试

---

### 5.3 Layer 2: 工具池过滤（硬约束）

#### 5.3.1 built_tools — 选择性暴露

**代码位置**: `turn.rs:1101-1180`

```rust
async fn built_tools(sess, turn_context, cancellation_token) -> Arc<ToolRouter>

ToolRouter.model_visible_specs() 控制模型能看到哪些工具
```

**过滤维度**:
```
① 权限: 不可用工具不注册
② 沙箱模式: readonly 下写工具不可见
③ App 启用状态: 未启用 App 工具不暴露
④ MCP 连接: 未连接 Server 工具不暴露
⑤ 插件: 未加载插件工具不暴露
⑥ 特性门控: 未启用特性工具不暴露
```

**为什么是硬约束**: 模型只能调用"它看得到"的工具。看不到 → 无法提议。

---

### 5.4 Layer 3: 执行前拦截

#### 5.4.1 PreToolUseHook — 执行前检查/阻止/重写

**代码位置**: `hook_runtime.rs:160-217`

工具分派流程中:
```
dispatch_any_with_terminal_outcome(invocation)
  → tool.pre_tool_use_payload()
    → 提取 hook payload (command/patch/...)
    → None → 跳过 hook (wait/write_stdin 等)
  → run_pre_tool_use_hooks()
    → 用户配置检查
    → 返回: Continue / Blocked + optional updated_input
  → Blocked → 错误返回模型: "命令被阻止: ..."
  → Continue + new_input → 重写后执行
```

#### 5.4.2 权限检查 — Approval Policy

```
approval_policy 控制级别:
  never       → 直接拒绝
  always      → 必须用户确认
  on-request  → Guardian 自动审查 + 高风险用户审批
  granular    → 按类型分别配置

routes_approval_to_guardian(turn) 判断是否走自动审批
```

#### 5.4.3 Guardian 自动审查 — 专用 AI 审核员

**核心文件**: `guardian/mod.rs`, `guardian/review.rs`, `guardian/review_session.rs`

这是最核心的防跑偏机制。关键思路:

```
每次操作不直接问用户, 先让专用 AI 审核:
① 独立的 review session, 锁定配置
   → approval_policy=never, 只读沙箱, 无工具
② 只能输出严格 JSON(output_schema_strict)
③ 90 秒超时, Fail Closed
```

**完整流程**:
```
review_approval_request(session, turn, request)
  ├── routes_approval_to_guardian? → No → 交用户
  ├── run_guardian_review_session()
  │   ├── 锁定配置: never + readonly
  │   ├── 编译 action transcript (最多 10K tokens)
  │   ├── 构建用户意图 + 最近上下文
  │   ├── 发送含 JSON Schema 的审查请求
  │   └── 解析 { riskLevel, userAuthorization, outcome, rationale }
  └── 返回: Approved / Denied (超时=Denied)
```

**Guardian Prompt 概要**:
```
Action: Shell 命令
Detail: "git push origin main"
User intent: 用户想推送代码

最近操作:
- 修改了 src/lib.rs (添加排序算法)
- 运行了测试

评估标准:
- 是否符合用户目标?
- 是否存在安全风险?
- 是否在权限范围内?

必须输出 JSON: { riskLevel, userAuthorization, outcome, rationale }
```

**Circuit Breaker** (`guardian/mod.rs:77-80`):
```
MAX_CONSECUTIVE_DENIALS_PER_TURN = 3
  → 连续拒绝 3 次 → 断路器打开
  → 后续操作直接拒绝(除非用户手动批准)
MAX_RECENT_DENIALS_PER_TURN = 10 in last 50 actions
  → 同样打开断路器
```


```
┌────────────────────────────────────────────────────┐
│ ① 松耦合事件驱动                                    │
│    外部 → tx_sub → 事件循环 → handler → 任务 spawn  │
│    每层通过独立信道通信，互不阻塞                      │
│                                                     │
│ ② 回合快照不可变                                    │
│    TurnContext 创建后不可变                          │
│    保证同回合内模型看到一致的配置                      │
│                                                     │
│ ③ 采样-执行循环                                     │
│    模型输出工具调用 → 执行 → 结果送回 → 模型继续      │
│    直到模型输出文本回复 → 回合自然结束                 │
│                                                     │

```
---

### 5.5 Layer 4: 执行后验证

#### 5.5.1 PostToolUseHook — 结果检查

**代码位置**: `hook_runtime.rs:261-292`, `tools/registry.rs:578-634`

工具执行成功后触发:
```
run_post_tool_use_hooks(session, turn, id, name, input, response)
  → 用户配置的 hook
  → 返回 PostToolUseOutcome:
    ├─ should_stop + feedback → 拦截, 替换输出
    ├─ !should_stop + feedback → 替换但继续
    └─ !should_stop + None    → 原始输出
```

典型用法: 检查 shell 输出中是否含敏感信息、patch 是否改了不允许的文件。

#### 5.5.2 StopHook — 回合结束审查

**代码位置**: `hook_runtime.rs:294-362`

每轮对话结束时触发:
```
run_turn_stop_hooks(session, turn_context, last_assistant_message)
  → 用户配置的 Stop hook
  → 返回 StopOutcome
  → 可中止回合
```

子 Agent 回合会转成 `SubagentStop`。

#### 5.5.3 Guardian Followup — 长期监督

**代码位置**: `context/guardian_followup_review_reminder.rs`

某些操作执行后才能判断风险, 后续轮次注入提醒:
```
"以下操作被标记为需要后续审查: [操作列表]"
```

---

### 5.6 沙箱隔离 — 最后物理防线

```
sandbox 模式        允许操作
─────────────────────────────────
readonly             只能读文件
workspaceWrite       读写工作区文件
dangerFullAccess     无限制

如果模型骗过所有逻辑层 → 沙箱 OS 级别兜底
```

---

### 5.7 Skill 遵循机制

```
Skill 遵循 = Prompt层(Tell) + 工具层(Show) + Schema层(Force) + 审查层(Check)

① Prompt层: AvailableSkillsInstructions.render()
   注入技能规则: "做 X 时用 Y 方法"

② 工具层: 技能不激活 → 对应工具不可见

③ Schema层: final_output_json_schema 强制输出格式

④ 审查层: Guardian 审查时检查技能遵循

Skill Workspace约束:
  Skills 可声明 workspace_roots
  → 不在范围内 → skill 不激活 → 工具不暴露
```

---

### 5.8 工具调用完整安全检查流程

```
模型输出 { tool: "shell", args: { command: "git push" } }

Step 1: built_tools 过滤（硬约束）
  → shell spec 是否可见? → 否 → 模型根本不会提议

Step 2: tool.pre_tool_use_payload（载荷构造）
  → 提取 command → 传给 PreToolUseHook

Step 3: PreToolUseHook（用户配置）
  → Blocked → 错误返回
  → Continue → 可重写

Step 4: Permission 检查（审批策略）
  → Guardian 自动审查 / 用户审批 / 拒绝

Step 5: 沙箱限制（物理隔离）
  → readonly → OS 阻止写操作

Step 6: 执行工具

Step 7: PostToolUseHook（结果检查）
  → 可替换输出
```

---

### 5.9 防跑偏工具箱总结

```
防御层级  | 机制                | 强度 | 执行时机
─────────────────────────────────────────────────
Layer 1  | base_instructions   | 软   | 每轮采样前
(Prompt) | developer 消息       | 软   | 每轮上下文注入
         | output_schema_strict | 硬   | API 强制校验
Layer 2  | built_tools 过滤     | 硬   | 每轮采样前
(工具池) | model_visible_specs | 硬   | 整个回合
Layer 3  | PreToolUseHook      | 硬   | 每次工具调用前
(执行前) | Permission 策略      | 硬   | 每次工具调用前
         | Guardian 自动审查    | 硬   | 高风险操作前
         | 用户审批             | 硬   | 高风险操作前
         | Circuit Breaker     | 硬   | 连续违规时
         | 沙箱限制             | 硬   | OS 级别
Layer 4  | PostToolUseHook     | 硬   | 每次工具执行后
(执行后) | StopHook             | 硬   | 回合结束时
         | Guardian Followup   | 软   | 后续轮次
         | TurnContext 不可变   | 硬   | 整个回合
```

---

### 5.10 关键设计思想

```
① "Trust but Verify" — 不信任模型输出
   每个工具调用前多层检查, 每层独立, 一层被绕过还有下一层

② Fail Closed — 所有审查失败 = 拒绝
   Guardian 超时 → 拒绝, Hook 异常 → 阻断
   不给模型"猜测"的机会

③ 审查者与被审查者隔离
   Guardian 用独立 review session
   approval_policy=never, 只读, 无工具

④ 断路器保护 — 防止 DoS
   连续拒绝 3 次 → 断路器打开

⑤ 物理兜底 — 沙箱 OS 级别限制
   模型骗过所有逻辑层 → 沙箱说"不能写"就是不能写
```

---

## 6. 关键设计思想总结
│ ④ 分层防御                                          │
│    每步工具调用都有独立的安全检查                      │
│    Prompt 层 + 中间件层 + 系统层 三层兜底              │
│                                                     │
│ ⑤ 上下文增量更新                                    │
│    第一轮完整注入，后续只注入变化的部分                  │
│    超限时自动压缩摘要                                 │
└────────────────────────────────────────────────────┘
```

---

> **文档版本**: v2.3 | **本章聚焦**: 上下文管理策略
> **基于**: codex-rs (`codex-rs/core/src/`)
> **关键文件**:
> - `context_manager/history.rs:34-51` — ContextManager 结构
> - `context_manager/normalize.rs:14-60` — 历史归一化
> - `session/mod.rs:2576-2587` — record_conversation_items
> - `session/mod.rs:2996-3026` — reference_context_item 增量更新
> - `state/session.rs:24-43` — SessionState 全部状态
> - `state/auto_compact_window.rs:16-70` — AutoCompactWindow
> - `turn.rs:732-782` — auto_compact_token_status 检测
> - `turn.rs:784-860` — run_pre_sampling_compact 回合前压缩
> - `turn.rs:862-917` — run_auto_compact 自动压缩
> - `compact.rs:70-200` — 压缩实现(本地/远程)
