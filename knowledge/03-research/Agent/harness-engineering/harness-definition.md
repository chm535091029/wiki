---
aliases: [Agent Harness 定义, Harness 构成条件, Harness Inclusion Test, Agent Harness Genealogy]
tags: [Agent, Harness, Agent-Harness-Definition, T1-T4-Test, Boundary-Delimitation, Design-Axes, Paper]
related:
  - "./harness-engineering.md"
  - "./claude-code-harness.md"
  - "./hook.md"
  - "../context-engineering/claude-code-context-and-rules.md"
---

# What Makes a Harness a Harness: Necessary and Sufficient Conditions for an Agent Harness

## 论文基本信息

- **论文标题**: What makes a harness a harness: necessary and sufficient conditions for an agent harness
- **作者**: Sanderson Oliveira de Macedo (Federal Institute of Goiás)
- **发表**: arXiv:2606.10106v1 [cs.SE], June 8, 2026
- **核心贡献**: 提出 agent harness 的操作性定义（constitutive definition），包含四个必要条件（T1-T4），以及 inclusion/exclusion test，从概念上区分 harness 与相邻概念

---

## 一、技术背景

### 研究背景

术语 **agent harness** 在 SE with GenAI 领域广泛流通，但用法松散多义（polysemous）：
- 有时指整个产品（Claude Code, Codex CLI）
- 有时指 evaluation scaffold（SWE-bench harness）
- 有时与 agent framework、SDK、IDE plugin、orchestrator 混淆

**核心问题**：缺少一个可作为 instrument 的参考定义（reference definition），能一致地包括和排除某个系统是否属于 agent harness。

**实践后果**：Agent 遇到障碍时撒谎报告成功（hallucinate success），常见反应是调 prompt，但语言模型在压力下倾向于产生让用户满意的答案。**健壮的解法是 engineering around the model**——用确定性代码检测声明与真实状态的差异，而不是信任模型的言辞。

### 术语演变谱系（Genealogy）

| 阶段 | 含义 | 控制时机 |
|------|------|---------|
| Old French *harneis* (12th c.) | 战甲、战争装备 | — |
| 14th c. English | 挽具（连接役畜与车的皮带组） | — |
| 经典软件测试（test harness） | 运行测试的脚本、mock、stub 等基础设施 | 执行后（事后观察）|
| ML 评估（eval harness） | 跑标准化任务并打分 | 执行后（事后测量）|
| **Agent harness**（本文目标） | 运行中控制、限制、验证、纠正执行 | **运行时实时控制** |

**关键变化**：前两个 sense 从外部事后（afterward）观察；agent harness 在运行时（during, at runtime）实时控制。这是 agent harness 区别于 eval harness 的根本。

---

## 二、技术内容详解

### 核心定义（Constitutive Definition）

```
An agent harness is the runtime engineering layer that wraps one or more language models
and turns them into an agent able to accomplish tasks over an external environment,
by coupling to the model:
  (i)   an agent loop that interleaves reasoning, action, and observation;
  (ii)  a tool interface that lets the model perceive and alter the environment;
  (iii) context management that decides what enters and leaves the model's window;
  (iv)  control mechanisms (limits, verification, deterministic actions) that make
        execution more trustworthy, auditable, and contained.

A system is an agent harness IF AND ONLY IF it instantiates the four elements above at runtime.
```

### Inclusion and Exclusion Test (T1-T4)

| Test | Question | If "no" → |
|------|----------|-----------|
| **T1** | 是否存在 reasoning-action-observation 循环（runtime loop）？ | 单次生成器或固定管线；不是 agent |
| **T2** | 是否存在让模型感知和改变外部环境的工具接口？ | 孤立模型或未构建循环的 SDK |
| **T3** | 是否存在对进入/离开上下文的内容的主动管理？ | 朴素 wrapper（只截断）；长任务脆弱 |
| **T4** | 是否存在至少一个独立于模型的**控制机制**？ | 演示级 demo；信任模型的自述 |

**可验证的标准**：
- **T3** 的判定：上下文管理决策是否**依赖于任务内容或当前观察**，而不仅仅是缓冲区大小。纯粹的按大小机械截断不满足 T3。
- **T2** 的判定：接口是否让模型**改变**环境（编辑文件、运行命令），而不仅仅是读取或建议文本。
- **T4** 的判定：机制的有效性是否**不依赖模型选择合作**。单纯打印日志不满足 T4；工具调用上限或确定性检查满足。

### 非必要条件（What is NOT necessary）

- ❌ 不需要 multi-agent（单模型 + loop + 工具 + 控制已经是 harness）
- ❌ 不需要 learning 或 fine-tuning
- ❌ 不需要特定模型（模型可切换是控制机制而非依赖）
- ❌ 不需要用户界面（可以是无面库）

### 边界划分（Boundary Delimitation vs 5 Neighbors）

| 概念 | T1 | T2 | T3 | T4 | 分离逻辑 |
|------|----|----|----|----|---------|
| **Agent harness** | ✅ | ✅ | ✅ | ✅ | 参考基准 |
| **Agent framework** (AutoGen, CrewAI, LangGraph) | ❌ | ❌* | ❌ | ❌ | 组合 agent，本身没有对外部环境的 action loop 和工具 |
| **Agent SDK** | ❌ | ✅ | ❌ | ❌ | 提供构建块，不在运行时组装 loop |
| **IDE plugin** (autocomplete) | ❌ | ❌ | ❌ | ❌ | 从光标建议代码，不维护任务状态或作用仓库 |
| **Eval harness** (SWE-bench) | ❌ | ✅ | ❌ | ❌ | 有外部 loop（遍历任务）但无内部 loop（reason-act-observe）；事后测量 |
| **Orchestrator** (固定管线) | ❌ | ✅ | ❌ | ❌ | 有固定图，但选择不是观察驱动的；不满足 T1 和 T3 |

*Framework 可能在协调的每个 agent 中嵌入 harness；❌ 指 framework 本身而非嵌入的 harness。

### 六种真实 Harness 的分类

| 系统 | T1 | T2 | T3 | T4 | 区分性控制特征 |
|------|----|----|----|----|---------------|
| **Claude Code** | ✅ | ✅ | ✅ | ✅ | 运行时 guardrails；破坏性操作确认 |
| **Codex CLI** | ✅ | ✅ | ✅ | ✅ | 分级权限模式 |
| **Aider** | ✅ | ✅ | ✅ | ✅ | 通过版本控制的审计和回滚能力 |
| **Cline** | ✅ | ✅ | ✅ | ✅ | 敏感操作前的人工审批 |
| **OpenHands** | ✅ | ✅ | ✅ | ✅ | 沙箱执行（确定性隔离） |
| **SWE-agent** | ✅ | ✅ | ✅ | ✅ | 带限制的结构化动作接口 |

### 四个设计张力轴（Research Agenda）

| 轴 | 两端 | 关键问题 |
|----|------|---------|
| **Axis 1: Autonomy vs Control** | 自主性 ↔ 安全控制 | 如何为任务类测量最优自主-监督平衡点？可随自主性扩展的 verifier 如何设计？ |
| **Axis 2: Broad vs Curated Context** | 全库倾倒 ↔ 精心策展 | 哪种策展策略使每 token 性能最大化？如何独立于底层模型评估上下文管理？ |
| **Axis 3: Generalist vs Specialized** | 通用 ↔ 领域专用 | 多少 harness 可跨域复用，多少必须定制？是否存在可组合领域扩展的通用控制核心？ |
| **Axis 4: Open Permission vs Containment** | 用户权限 ↔ 沙箱隔离 | 如何在强隔离和高实用性之间平衡？哪些隔离模式可跨 harness 迁移？ |

### 三个跨领域发现

1. **Control (T4) 是差异化最大的设计维度**——文献中尚未被充分研究
2. **模型与 harness 的分离有战略意义**——harness 越好，对单一昂贵模型的依赖越少（模型切换成为控制机制）
3. **当前评估衡量的是 model-harness pair**，缺少将 harness 贡献独立出来的方法论——这是本文定义帮助打开的核心方法学缺口

---

## 三、特别标签观点与核心关联内容

### 观点 1：Harness 的核心是"运行时控制"，而非评估

- **标签**: `Runtime-Control`, `Eval-vs-Agent-Harness`
- **核心论点**: Agent harness 区别于 eval harness 的根本不是组件，而是**控制发生的时间**——agent harness 在运行时（during）实时控制，eval harness 事后（afterward）测量。
- **关键证据**: 两种 harness 都有 loop（eval harness 有外 loop 遍历任务），但 agent harness 的内 loop（per-task reasoning-act-observe）是本质性的。Eval harness 不决定下一步，仅记录系统决定。
- **深层含义**: 这意味着任何仅用于评估的系统不能称为 agent harness。这是一个基于时间维度的严格边界。

### 观点 2：四个必要条件中，任何一个缺失就摧毁概念

- **标签**: `T1-T4-Integrity`, `Necessary-Conditions`
- **核心论点**: T1-T4 每个条件都是**必要的**——取走任何一个，系统就不成其为 agent harness。
- **关键证据**: 
  - 无 agent loop = generator
  - 无工具接口 = 模型困在窗口内
  - 无上下文管理 = 长任务不可行
  - 无控制机制 = 信任模型的自述（正是该领域试图解决的问题）
- **深层含义**: 这提供了一个概念诊断工具——当某个系统自称 harness 时，可以逐一检查 T1-T4 来确定它是否真的属于该概念。

### 观点 3：上下文管理的门槛是"内容感知"，而非"大小截断"

- **标签**: `Context-Curation-Threshold`, `T3-Verifiable-Criterion`
- **核心论点**: T3 满足的条件是上下文管理决策**依赖于任务内容或当前观察**，而非仅基于缓冲区大小。纯按大小机械截断不满足 T3。
- **关键证据**: 文献确认，有用信息在历史累积中稀释会降低模型质量。主动的、任务感知的选择（如 Aider 的仓库地图）是满足 T3 的标准。
- **深层含义**: 很多看似有上下文管理的 wrapper 实际上未通过 T3。这为判定体系增加了实质性门槛。

### 观点 4：控制机制必须"不依赖模型合作"才是有效的 T4

- **标签**: `Model-Independent-Control`, `T4-Verifiable-Criterion`
- **核心论点**: 一个机制只有其有效性**不依赖于模型选择合作**时，才满足 T4。单纯打印日志不满足 T4；工具调用上限或确定性检查满足。
- **关键证据**: 作者明确指出 prompt guardrail 是最弱的控制形式（依赖模型服从），而确定性隔离（如 OpenHands 沙箱）是最强的。
- **深层含义**: 这提供了控制机制的"强度等级"——从软约束（提示词）到硬约束（沙箱），T4 的满足需要一个最低门槛（至少一种硬约束）。

### 观点 5：Guardrail vs Harness——部分与整体的关系

- **标签**: `Guardrail-vs-Harness`, `Part-Whole-Relation`
- **核心论点**: Guardrail 是 harness 的一部分，不是同类。Guardrail **限制**（阻挡、拦截、设定边界），Harness **赋能**（上下文管理帮记住，memory 避免重复，retry 处理失败）。
- **关键证据**: "If it limits, it is a guardrail. If it helps, it is a harness." Guardrails are inside the harness; the harness is not inside the guardrails.
- **深层含义**: 这意味着 guardrail 是 T4 的一个子类（控制机制），不是与 harness 并列的邻域概念。Guardrail 研究应被视为 harness 研究的一个子领域。

### 观点 6：模型与 harness 的分离——战略级工程选择

- **标签**: `Model-Harness-Separation`, `Strategic-Consequence`
- **核心论点**: 越好的 harness，对单一昂贵模型的依赖越小——模型切换变成一种控制机制，而非重写。
- **关键证据**: 论文提出这是一个"猜想"（conjecture），作为未来工作的假设——但逻辑上，当 harness 承担控制、验证、上下文管理等职能时，模型退化带来的风险被 harness 隔离。
- **深层含义**: 如果这个猜想成立，工程差异可能从模型侧转向 harness 侧。这意味着投资 harness 工程（而非更大模型）可能是获得更可靠 agent 的路径。

### 观点 7：成员资格是二元的，但质量是渐进的

- **标签**: `Binary-Membership`, `Gradual-Quality`
- **核心论点**: T1-T4 测试决定是否属于 harness（二元），但**成熟度**（robustness）是渐进的。最简 harness 重新运行测试套件就满足 T1-T4，但远不如 Claude Code 或 OpenHands 成熟。
- **关键证据**: "A minimal loop that re-runs the repository's test suite and declares success only if the suite passes satisfies T1 through T4 to the letter and is, in fact, an embryonic harness."
- **深层含义**: 概念判定和质量评价是两个独立的问题。目前大量讨论将两者混淆——这是术语混乱的根源之一。本文只解决前者。

### 观点 8：Control (T4) 是 harness 设计中最开放的工程前沿

- **标签**: `Control-Frontier`, `T4-Open-Questions`
- **核心论点**: 六个真实 harness 在核心四要素上一致，但在 T4（控制）形式上差异最大——且这正是形式化文献中最不成熟的部分。
- **关键证据**: 每个 harness 的控制特征都不同：Claude Code 用 runtime guardrails，Codex CLI 用分级权限，Aider 用版本控制审计，Cline 用人工审批，OpenHands 用沙箱，SWE-agent 用结构化动作接口。
- **深层含义**: 控制机制的设计空间是开放的——没有公认的最佳实践。这意味着控制研究方向包括：可扩展的 verifiers、可组合的 guardrails、问题特定的控制核心。

### 观点 9：相邻概念的本质区别在于"我是否在运行时拥有 loop"

- **标签**: `Concept-Boundary`, `Loop-Ownership`
- **核心论点**: Agent harness 与 framework、SDK、IDE plugin、eval harness、orchestrator 的根本区别不在于"有没有 loop"，而在于**谁拥有这个 loop** 以及**这个 loop 是否是自适应的**。
- **关键证据**: Eval harness 有 loop（遍历任务）但不是内部 loop；Orchestrator 有 loop（固定管线）但不是自适应的；Framework 给协调的 agent 装 loop，本身无 loop。
- **深层含义**: 这提供了一个概念边界判定的简洁方法——检查：① loop 存在吗？② loop 的所有者是谁？③ loop 的下一步选择是观察驱动的吗？

### 观点 10：评估方法论的根本缺口——无法独立测量 harness 贡献

- **标签**: `Evaluation-Gap`, `Model-Harness-Pair`
- **核心论点**: 当前所有基准测试（SWE-bench 等）衡量的是 model-harness pair，无法分离 harness 的独立贡献。这是最核心的方法学缺口。
- **关键证据**: 论文作为结论提出："Knowing what the harness is was the necessary step toward knowing, next, how much it is worth."
- **深层含义**: 只有有了本文的精确定义，才能提出"如何控制模型因素来测量 harness 效应"的研究问题。这为未来基准测试设计提供了概念基础。

### 观点 11："通道化 brute force"是贯穿所有 sense 的单一隐喻

- **标签**: `Unifying-Metaphor`, `Channeling-Force`
- **核心论点**: 从 horse tack → test harness → eval harness → agent harness，不变的隐喻是："take a brute force and channel it safely to produce work."（horse = model power, cart = task, tack = harness）。
- **关键证据**: "The idea never changes: take a brute force and channel it safely to produce work. That is the parent metaphor of everything that follows."
- **深层含义**: 这个隐喻本身就是定义理解工具——当对某个组件是否属于 harness 存疑时，问"它是在 channel the force 还是被 channeled？"答案指向 harness。

---

## 四、总结与局限

### 总结

本文提供：
1. **术语谱系**：从旧法语 harnois（战甲）→ 挽具 → test harness → eval harness → agent harness 的完整迁移
2. **操作性定义**：agent harness = T1 (agent loop) + T2 (tool interface) + T3 (context management) + T4 (control mechanisms)，运行时实时控制
3. **边界划分**：与 agent framework、SDK、IDE plugin、eval harness、orchestrator 的清晰界限
4. **分类工具**：T1-T4 test 的一致包括/排除能力（6 个真实系统 + 2 个边缘案例验证）
5. **研究议程**：四个设计张力轴 + 三个跨领域发现

### 局限

- 论文明确将其定位为"概念性工作"（definitional），不提出新 agent、不测量 benchmark 表现
- 模型与 harness 分离的猜想未经过实证检验（留给未来工作）
- "如何独立测量 harness 的贡献"仍为开放问题
- Hooks（Claude Code 中的关键控制机制）未被特别纳入本文框架，而是作为 T4 的子类

---

## 五、关键引用

1. Jimenez et al. (2023) "SWE-bench: Can Language Models Resolve Real-World GitHub Issues?" — eval harness 的典型
2. Yang et al. (2024) "SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering" — agent-computer interface 的代表
3. Wang et al. (2024) "OpenHands: An Open Platform for AI Software Developers as Generalist Agents" — 沙箱隔离的代表
4. Yao et al. (2022) "ReAct: Synergizing Reasoning and Acting in Language Models" — 推理-行动循环的基础模式
5. Liu et al. (2023) "Lost in the Middle: How Language Models Use Long Contexts" — 上下文管理的重要性
6. Bubeck et al. (2023) "Sparks of Artificial General Intelligence" — 模型在压力下产生满意回答的核心观察
7. Madaan et al. (2023) "Self-Refine: Iterative Refinement with Self-Feedback" — 验证/自纠正
8. Rebedea et al. (2023) "NeMo Guardrails" — guardrails 的技术基础

---

## 六、对实践的启示

1. **判定你的系统是否为 harness**：对所有自称 harness 的系统跑 T1-T4 test
2. **关注控制机制（T4）的强度**：prompt 要求的控制是最弱的形式，确定性沙箱是最强的
3. **上下文管理必须有内容感知**：纯截断不满足 T3，需要 task-aware selection
4. **Harness 质量 ≠ 概念归属**：先判定"是否"，再评估"多好"
5. **投资 harness 工程，而非更大模型**：如果 harness 承担了足够多的控制，对单一模型的依赖会下降
6. **注意区分 guardrail 和 harness**：guardrail 是限制，harness 是赋能；两者是部分与整体的关系
7. **评估时分离 model 和 harness 的贡献**：概念基础已建立，benchmark 设计可以跟进