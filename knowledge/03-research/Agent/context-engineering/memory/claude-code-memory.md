---
aliases: [Claude Code Memory, Auto Memory, AutoMem, 记忆系统]
tags: [AI-Memory, Claude-Code, Context-Engineering, Agent, Memory-Management, Long-Term-Memory, Team-Memory, Extract-Memories, Auto-Dream, 多层级记忆]
related:
---

# Claude Code Memory System

Claude Code 的 Auto Memory 是一个持久化的、基于文件的 AI 记忆系统，它让 Claude 能够跨会话记住用户的偏好、项目背景、工作习惯等信息。

## 核心设计原则

| 原则 | 说明 |
|------|------|
| **文件即记忆** | 所有记忆以 Markdown 文件存储在磁盘上，用户可直接查看和编辑 |
| **两阶段存储** | 记忆内容存于独立 topic 文件，索引存于 MEMORY.md 入口文件 |
| **自动提取** | 后台子代理在每轮对话结束后自动从会话中提取值得记住的信息 |
| **智能检索** | 使用 Sonnet 模型进行相关性判断，仅注入最相关的记忆 |
| **四类分类法** | 严格的四种记忆类型：user / feedback / project / reference |

## Memory 体系架构

Claude Code 的 Memory 系统包含多个层次，按优先级从低到高加载：

```
优先级从低到高：
┌─────────────────────────────────────────────────────┐
│  1. Managed Memory                                  │
│     /etc/claude-code/CLAUDE.md                      │
│     (管理员级别的全局策略指令，所有用户都会加载)        │
├─────────────────────────────────────────────────────┤
│  2. User Memory                                     │
│     ~/.claude/CLAUDE.md                             │
│     ~/.claude/rules/*.md                            │
│     (用户私有全局指令，适用于所有项目)                 │
├─────────────────────────────────────────────────────┤
│  3. Project Memory                                  │
│     CLAUDE.md、.claude/CLAUDE.md、.claude/rules/*.md │
│     (项目级指令，会提交到代码仓库)                     │
├─────────────────────────────────────────────────────┤
│  4. Local Memory                                    │
│     CLAUDE.local.md                                 │
│     (项目级私有指令，不提交到仓库)                     │
├─────────────────────────────────────────────────────┤
│  5. Auto Memory (AutoMem)      ← 本报告核心分析对象   │
│     ~/.claude/projects/<path>/memory/               │
│     (AI 自主管理的持久化记忆系统)                      │
├─────────────────────────────────────────────────────┤
│  6. Team Memory (TeamMem)                           │
│     ~/.claude/projects/<path>/memory/team/          │
│     (团队共享记忆，跨用户同步)                        │
├─────────────────────────────────────────────────────┤
│  7. Agent Memory                                    │
│     (子代理的持久化记忆，按 agent 类型隔离)            │
└─────────────────────────────────────────────────────┘
```

**加载顺序**：Managed → User → Project（从根目录到 CWD 遍历）→ Local → AutoMem → TeamMem

**优先级规则**：后加载的文件优先级更高，离当前工作目录越近的文件越后加载，因此具有更高优先级。

## Auto Memory 核心设计

### 1. 存储路径

Auto Memory 的存储路径按以下优先级解析：

1. `CLAUDE_CODE_REMOTE_MEMORY_DIR` 环境变量 → 用于远程模式
2. `CLAUDE_COWORK_MEMORY_PATH_OVERRIDE` 环境变量 → 用于 Cowork 场景
3. `settings.json` 中的 `autoMemoryDirectory` → 用户自定义路径
4. 默认路径：`~/.claude/projects/<sanitized-git-root>/memory/`

**存储目录结构示例**：

```
~/.claude/projects/
  github.com_anthropics_claude-code/
    memory/                        ← Auto Memory 根目录
      MEMORY.md                    ← 索引入口文件
      user_role.md                 ← 用户角色记忆
      feedback_testing.md          ← 反馈记忆
      project_auth_rewrite.md      ← 项目背景记忆
      team/                        ← Team Memory 子目录
        MEMORY.md
        deploy_policy.md
```

### 2. 入口文件（MEMORY.md）

MEMORY.md 是 Auto Memory 的索引文件，不是记忆内容本身。它充当目录角色：

```markdown
- [User Role](user_role.md) — senior data scientist focused on observability
- [Testing Policy](feedback_testing.md) — integration tests must hit real DB
- [Auth Rewrite](project_auth_rewrite.md) — compliance-driven middleware replacement
```

**限制**：
- 最大 200 行
- 最大 25,000 字节
- 超出部分会被截断并附加警告

### 3. 四种记忆类型

所有记忆被严格分为四种类型，每种类型有明确的用途：

| 类型 | 用途 | 示例 |
|------|------|------|
| **user** | 用户角色、目标、偏好 | "用户是高级数据科学家，关注可观测性" |
| **feedback** | 用户给出的行为指导 | "集成测试必须用真实数据库，不要 mock" |
| **project** | 不可从代码推导的项目背景 | "合并冻结从 2026-03-05 开始" |
| **reference** | 外部系统的指针 | "流水线 bug 在 Linear 项目 INGEST 中追踪" |

### 4. 记忆文件格式

每个记忆文件使用 YAML frontmatter：

```yaml
---
name: Testing Policy
description: Integration tests must hit a real database, not mocks
type: feedback
---

Integration tests must hit a real database, not mocks.

**Why:** Prior incident where mock/prod divergence masked a broken migration.

**How to apply:** When writing tests that touch the database layer, always configure
them to connect to a real test database instance rather than using in-memory mocks.
```

### 5. 新鲜度管理

记忆可能过时，系统通过新鲜度标记帮助模型判断记忆的可靠性：

- 今天/昨天的记忆不需要警告
- 超过 30 天的记忆会被标记为 "stale"

## Memory 数据流

### 写入流程

```
用户对话中产生有价值信息
         │
         ├──→ 主代理直接写入
         │         │（hasMemoryWritesSince() 检测到直接写入）
         │         └──→ extractMemories 跳过该轮
         │
         └──→ 主代理未写入
              │
              └──→ extractMemories 后台子代理
                    │
                    ├──→ 扫描现有记忆清单
                    ├──→ 构建提取 prompt
                    ├──→ 运行提取子代理（最多 5 轮）
                    │       ├──→ 读取可能需要更新的文件
                    │       └──→ 写入/更新记忆文件 + 更新 MEMORY.md
                    │
                    └──→ 通知 UI
```

### 读取/注入流程

```
用户发送消息
       │
       ├─[并行]─→ 预取相关记忆
       │              │
       │              ├──→ 扫描记忆文件头
       │              ├──→ 查找相关记忆（Sonnet 模型选择最相关的 5 个）
       │              └──→ 读取选中文件内容
       │
       ├─→ 主模型运行（工具执行等）
       │
       └─→ 工具执行后：注入记忆到上下文
            │
            ├──→ 去重过滤
            └──→ 添加 system-reminder 消息
```

## 后台 Memory 提取机制（Extract Memories）

### 概述

extractMemories 是一个在每轮对话结束后自动运行的后台子代理，它分析最近的对话内容，提取值得跨会话持久化的信息并写入 memory 目录。

### 运行条件

- 仅主代理运行（非子代理）
- feature flag 'tengu_passport_quail' 启用
- autoMemory 已启用
- 非远程模式

### 运行机制

1. **互斥检测**：检查主代理是否已直接写入 → 如果是，跳过并推进游标
2. **节流控制**：由 'tengu_bramble_lintel' 控制（默认每轮都运行）
3. **运行 forked agent**：最多 5 轮对话
4. **尾随执行**：当提取正在运行时，新到的请求会被暂存。当前提取完成后，会自动执行一次尾随提取

### 工具权限沙箱

提取子代理的权限被严格限制：

- **允许**：Read、Grep、Glob（无限制，只读）
- **允许**：Bash（仅只读命令：ls/find/cat/stat/wc/head/tail）
- **允许**：Edit/Write（仅限 memory 目录内的路径）
- **拒绝**：所有其他工具（MCP、Agent、写操作 Bash 等）

## Memory 相关性检索（Relevant Memories）

### 概述

findRelevantMemories 使用 AI 模型（Sonnet）从大量记忆文件中筛选出与当前用户查询最相关的前 5 个。

### 工作流程

1. scanMemoryFiles() → 扫描所有记忆文件头
2. 过滤已展示过的文件
3. 格式化为文本清单
4. 发送 side query 给 Sonnet 选择最相关的记忆
5. 验证返回的文件名是否有效
6. 返回选中文件的路径

### 选择器 Prompt

> "You are selecting memories that will be useful to Claude Code as it processes a user's query. Return a list of filenames for the memories that will clearly be useful (up to 5). Only include memories that you are certain will be helpful."

输入包含：用户查询 + 记忆清单 + 最近使用的工具列表。

### 去重机制

过滤掉模型已通过 FileRead/FileEdit/FileWrite 访问过的文件。

## 自动整合机制（Auto Dream）

### 概述

Auto Dream 是一个后台记忆整合服务，它会定期运行来清理、合并和优化记忆文件。

### 触发条件（三重门控）

| 门控 | 条件 | 默认值 |
|------|------|--------|
| 时间门控 | 距上次整合 ≥ minHours | 24 小时 |
| 会话门控 | 距上次整合的会话数 ≥ minSessions | 5 次 |
| 锁门控 | 没有其他进程正在进行整合 | — |

### 整合流程（四阶段）

- **Phase 1: Orient（定位）**：查看 memory 目录，读取索引
- **Phase 2: Gather（收集）**：检查日志，识别漂移记忆，搜索会话记录
- **Phase 3: Consolidate（整合）**：写入/更新主题文件，合并信号，修复矛盾
- **Phase 4: Prune and Index（清理与索引）**：保持 MEMORY.md 在限制内，移除过时指针

### 用户可调用技能

- `/dream`：触发记忆整合
- `/remember`：审查所有 memory 层级，生成变更提案报告（不直接修改）

## Agent Memory 子系统

### 概述

Agent Memory 是为**子代理（Sub-Agent）**设计的独立记忆系统，按代理类型隔离，与主会话的 Auto Memory 分离。

### 三种作用域

| 作用域 | 路径 | 特点 |
|--------|------|------|
| user | ~/.claude/agent-memory/<agentType>/ | 跨项目，仅限当前用户 |
| project | <cwd>/.claude/agent-memory/<agentType>/ | 版本控制，团队共享 |
| local | <cwd>/.claude/agent-memory-local/<agentType>/ | 项目级但不在 VCS 中 |

### 快照初始化

Agent Memory 支持快照种子化机制，当项目配置了快照时：
- **initialize**：本地无记忆时，从快照复制初始文件
- **prompt-update**：本地记忆存在但快照更新时，提示更新
- **none**：已同步或无快照

这使得团队可以预配置 Agent 的"起始记忆"。

### 与主会话 Memory 的区别

| 主会话 Auto Memory | Agent Memory |
|---------------------|--------------|
| 内容注入：通过 user context 消息 | 内容注入：同步读取并嵌入 system prompt |
| 不支持 Team Memory | 支持 Team Memory |
| 有提取机制 | 无提取机制 |

## Team Memory 团队记忆

### 概述

Team Memory 是 Auto Memory 的扩展，支持团队成员之间共享记忆。

### 启用条件

需要同时满足：
- Auto Memory 已启用
- feature flag 'tengu_herring_clock' 开启

### 存储结构

```
~/.claude/projects/<path>/memory/
  （私有记忆）
  team/                  ← 团队记忆（子目录）
    MEMORY.md
    deploy_policy.md
```

### 安全验证

Team Memory 的写入路径经过多层安全检查：
- 空字节拒绝
- 路径遍历检测（.. 段）
- URL 编码遍历检测
- Unicode 标准化攻击检测
- 符号链接逃逸检测

## CLAUDE.md 文件体系

### 文件类型

| 文件 | 用途 | 提交到 VCS |
|------|------|-----------|
| CLAUDE.md | 项目级公开指令 | 是 |
| .claude/CLAUDE.md | 项目级公开指令（替代位置） | 是 |
| .claude/rules/*.md | 条件规则 | 是 |
| CLAUDE.local.md | 项目级私有指令 | 否（gitignore） |
| ~/.claude/CLAUDE.md | 用户全局指令 | N/A |

### 条件规则

.claude/rules/ 目录下的 .md 文件可包含 frontmatter 中的 paths 字段，指定该规则仅对匹配的文件路径生效：

```yaml
---
paths:
  - "src/api/**"
  - "src/routes/**"
---

API 路由使用 kebab-case 命名约定。
所有 API 响应必须包含 request-id 头。
```

### @include 指令

Memory 文件支持通过 @ 语法引入其他文件：

```
@path             → 相对路径
@./relative/path  → 相对路径
@~/home/path      → 主目录路径
@/absolute/path   → 绝对路径
```

特性：
- 最大嵌套深度：5 层
- 循环引用检测
- 仅支持文本文件扩展名

## 安全机制

### 文件系统权限沙箱

Auto Memory 文件享有特殊的文件系统写入权限（绕过危险目录限制）。

### 路径验证

验证规则：
- 拒绝：相对路径、根路径、Windows 驱动器根、UNC 路径、空字节
- 支持 ~/ 展开但拒绝展开到 HOME 或其祖先的路径

### Settings 安全层级

autoMemoryDirectory 设置仅接受来自可信源的配置：
- policySettings（管理员策略）
- flagSettings（功能标志）
- localSettings（本地配置）
- userSettings（用户配置）

**不接受** projectSettings（.claude/settings.json 提交到仓库），防止恶意仓库将记忆路径指向敏感目录。

### 排除机制

用户可通过 claudeMdExcludes 设置排除特定的 CLAUDE.md 文件：

```json
{
  "claudeMdExcludes": [
    "/home/user/monorepo/CLAUDE.md",
    "**/code/CLAUDE.md"
  ]
}
```

排除仅适用于 User、Project、Local 类型。

## 不应保存的内容

系统明确定义了不应作为记忆保存的内容：
- 代码模式、约定、架构（可通过读取代码推导）
- Git 历史（可通过 git log 获取）
- 调试解决方案（修复已在代码中）
- 已在 CLAUDE.md 中记录的内容
- 临时任务细节

## 性能优化策略

| 策略 | 说明 |
|------|------|
| **Memoize 缓存** | getMemoryFiles 使用缓存，只在首次调用或缓存清除后重新加载 |
| **预取并行** | Relevant memories 的检索与主模型运行并行执行 |
| **入口文件截断** | MEMORY.md 双重限制（200 行 / 25,000 字节） |
| **扫描优化** | 仅读取前 30 行获取 frontmatter，文件数上限 200 个 |
| **Prompt Cache 友好** | 使用预计算的 header，保持跨轮次稳定，提高 prompt cache 命中率 |
| **节流与合并** | 提取器暂存最新上下文，执行尾随运行 |

---

*源文档：Claude Code 博客分析*