---
aliases: [SkillOS, Skill Curation, Self-Evolving Agents, 技能策管, 自我进化Agent, Skill Repository, SkillRepo, Grouped Task Streams, Composite Reward, GRPO, 分组任务流, 组合奖励, Procedural Memory, Reusable Skills]
tags: [SkillOS, Skill-Curation, Self-Evolving-Agents, Agent-Memory, Procedural-Memory, Reusable-Skills, SkillRepo, Skill-Curator, Agent-Executor, Grouped-Task-Streams, Composite-Reward, RL-Training, GRPO, BM25, ReAct, Chain-of-Thought, Meta-Skills, Skill-Evolution-Dynamics, Curator-Executor-Mismatch, Streaming-Settings, Markdown-Skills, YAML-Frontmatter, Insert-Update-Delete, Task-Outcome-Reward, Function-Call-Reward, Content-Quality-Reward, Compression-Reward, ALFWorld, WebShop, AIME24, AIME25, GPQA-Diamond, DeepMath-103k, Qwen3-8B, Qwen3-32B, Gemini-2.5-Pro, ReasoningBank, MemP, SkillRL, D2Skill, ARISE, Anthropic-Skills, Cross-Task-Generalization, Multi-Agent-Modular-Design]
related:
  - "./claude-code-memory.md"
  - "../memory/agent-memory-survey.md"
  - "../../RAG/llm-wiki/llm-wiki-combined-rag.md"
---

# SkillOS: Learning Skill Curation for Self-Evolving Agents

## 论文基本信息

- **论文标题**: SkillOS: Learning Skill Curation for Self-Evolving Agents
- **作者**: Siru Ouyang, Jun Yan, Yanfei Chen, Rujun Han, Zifeng Wang, Bhavana Dalvi Mishra, Rui Meng, Chun-Liang Li, Yizhu Jiao, Kaiwen Zha, Maohao Shen, Vishy Tirumalashetty, George Lee, Jiawei Han, Tomas Pfister, Chen-Yu Lee
- **机构**: UIUC, Google Cloud AI Research, MIT
- **发表**: arXiv:2605.06614v1 (2026年5月)

---

## 1. 研究背景

### 1.1 LLM Agent 的现状与局限

LLM-based agent 正在越来越多地被部署到真实世界的流式任务场景中（streaming settings），即任务按时间顺序逐个到达，agent 需要连续处理这些任务。然而，目前的 agent 大多是"一次性"（one-off）的问题解决者——每个新任务都从零开始，无法从过去的交互中学习经验。这种范式严重限制了 agent 在流式场景中的长期效能。

### 1.2 自我进化（Self-Evolution）的需求

要使 agent 能够持续进步，必须引入**自我进化**（self-evolution）机制：agent 不应每次都从头开始，而应不断积累、优化和重用过去的经验。自我进化的关键支撑是**程序性记忆**（procedural memory），其中最核心的形式就是**可重用技能**（reusable skills）——将过去的交互经验提炼为结构化的技能，供未来任务使用。

### 1.3 技能策管（Skill Curation）的挑战

在流式场景中，基于技能的自我进化 agent 通常遵循闭环工作流：对于每个新任务，retrieve 相关技能 → 使用技能指导执行 → 根据执行结果更新技能集合。这个流程中，**技能策管**（skill curation）——即从经验中提取高质量的教训并将其整合到技能集合中——是整个系统的关键瓶颈。

### 1.4 现有方法的局限性

| 方法类别 | 代表工作 | 局限性 |
|---------|---------|--------|
| 人工策管 | Anthropic's skills repository | 需要大量人工专业知识，无法扩展到 agent 可能遇到的各种任务 |
| 提示/启发式方法 | 基于固定规则指定记忆操作 | 缺乏下游性能反馈，无法适应 executor 的实际需求 |
| 现有 RL 方法 | SkillRL, D2Skill, ARISE, MemP | 要么只关注教 agent 使用技能，要么在短任务流中优化技能操作，对复杂的策管操作（如技能更新和删除）提供的学习信号不足 |

**核心矛盾**: 技能策管的反馈是**间接且延迟的**（indirect and delayed feedback）——一个策管决策的好坏，只有通过后续任务中 executor 的性能才能体现出来。这使得学习长期的策管策略变得非常困难。

---

## 2. 技术背景

### 2.1 技能作为 Agent 记忆的范式

Anthropic 将每个技能概念化为一个包含指令、脚本和支持资源的文件夹，这已成为社区最广泛采用的设计。技能相对于其他记忆形式（如原始轨迹、检索增强）的优势在于：

- **模块性**: 技能可以独立创建、更新和删除
- **可编辑性**: 技能内容可以审查和修改
- **可组合性**: 多个技能可以协同工作
- **跨任务泛化**: 好的技能可以迁移到相关任务

### 2.2 用 RL 训练记忆/技能策管

将 RL 应用于训练基于 LLM 的 agent 系统的记忆能力是一个新兴方向：

- **长上下文管理**: 用预定义操作（如压缩）训练
- **记忆工具调用**: 学习额外的记忆相关函数调用
- **技能发展**: 如 SkillRL 和 D2Skill 教小模型使用大模型策管的技能；ARISE 训练共享策略同时作为检索器和 worker

但现有工作的关键缺陷是：它们的监督信号主要局限于**短任务流中的局部适应**，偏好立即有用的操作（如技能插入），而对复杂管理操作（如修订过时技能、删除有害技能）提供的信号有限。

### 2.3 GRPO（Grouped Reward Policy Optimization）

由 DeepSeek 提出的策略优化方法，相比 PPO 具有更好的训练稳定性和样本效率。SkillOS 使用 GRPO 作为核心优化算法。

---

## 3. 技术内容详解

### 3.1 整体架构：多 Agent 模块化设计

SkillOS 采用**解耦的多 Agent 模块化框架**，包含两个核心组件：

#### (a) Agent Executor（agent 执行器）$\pi_L$

- **冻结不变**（frozen）——在训练过程中不更新
- 职责：接收当前任务和检索到的相关技能，完成任务执行
- 技能检索使用 BM25 算法从 SkillRepo 中获取相关子集
- 使用 ReAct（agentic 任务）或 CoT（推理任务）进行推理

#### (b) Skill Curator（技能策管器）$\pi_S$

- **可训练**——通过 RL 优化
- 职责：在 executor 完成任务后，观察执行轨迹、自判断正确性以及检索到的相关技能，生成结构化的策管操作序列
- 操作类型：
  - `insert_skill`: 插入新技能
  - `update_skill`: 更新已有技能
  - `delete_skill`: 删除技能

#### (c) SkillRepo（技能仓库）

- 外部存储，随时间演化
- 每个技能是一个 Markdown 文件，包含：
  - **YAML frontmatter**: 技能名称和自然语言描述（何时使用）
  - **Markdown 指令**: 可执行的知识、工作流、约束和可重用启发式

**设计思路**: 将策管和执行解耦，使得技能策管可以在不重新训练底层 executor 的情况下进行模块化优化。这类似于操作系统的设计理念——策管器像 OS 内核一样管理"文件"（技能），而 executor 像应用程序一样使用这些文件。

### 3.2 训练实例构建：分组任务流

这是 SkillOS 最核心的设计创新之一。

#### 问题

技能策管的反馈是间接且延迟的——一个策管操作的好坏，只有通过 executor 在未来相关任务上的表现才能体现。如果训练实例是独立的单个任务，则无法提供这种长期反馈信号。

#### 解决方案

**构建分组任务流**（Grouped Task Streams）作为每个训练实例：

1. **属性标注**: 对于每个任务 $x_i$，使用 Gemini-2.5-Pro 生成一组技能相关属性标签 $Z_i$（如"代数"、"傅里叶变换"等），作为任务相关性和潜在技能依赖的代理。

2. **任务分组**: 根据属性相似性，将数据集 $D$ 划分为 $M$ 个任务组 $G_m = \{x_{m,1}, x_{m,2}, ..., x_{m,|G_m|}\}$，组内任务具有显著的技能依赖关系。

3. **顺序执行**: 在每个训练步中，采样一个任务组，初始化空的 SkillRepo，然后组内任务按顺序执行：
   - 任务 1：使用空 SkillRepo 执行 → 策管器根据经验创建技能
   - 任务 2：使用更新后的 SkillRepo 执行 → 策管器进一步优化
   - ...依此类推

**设计思路**: 通过分组构造，模拟了测试时的流式场景，将技能策管置于长期效用的背景下。技能从早期经验中产生，它们的价值由是否能够帮助完成后续相关任务来评估。这种方法与现有方法（如 Wang et al. 2025a; Ye et al. 2026）的关键区别在于，现有方法关注短期转移，而 SkillOS 构造了更长的技能演化轨迹，为学习复杂策管操作提供了更密集的反馈。

### 3.3 组合奖励设计

为了将延迟和间接的监督转化为技能策管的学习信号，SkillOS 设计了**四部分组合奖励**：

#### (a) 任务结果奖励 $r_{\text{task}}$

- 定义: 组内除第一个任务外的平均成功率
- 公式: $r_{\text{task}} = \frac{1}{|G|-1} \sum_{i=2}^{|G|} \mathbb{1}(\xi_i)$
- 目的: 提供 executor 层面的下游性能信号，这是对策管决策最直接的评估

#### (b) 函数调用奖励 $r_{\text{fc}}$

- 定义: 策管器生成的函数调用中有效且成功执行的比例
- 公式: $r_{\text{fc}} = \frac{1}{|G|} \sum_{i=1}^{|G|} \text{Valid}(c_i)$
- 目的: 确保策管器产生语法正确且可执行的技能操作

#### (c) 内容质量奖励 $r_{\text{cnt}}$

- 定义: 由外部评判模型（Qwen3-32B）评估策管技能的质量分数
- 公式: $r_{\text{cnt}} = \frac{1}{|G|} \sum_{i=1}^{|G|} \text{Judge}(c_i)$
- 目的: 评估策管的技能在语义上是否有意义、是否可能对未来任务有用

#### (d) 压缩奖励 $r_{\text{comp}}$

- 定义: 鼓励简洁的仓库更新，防止逐字复制轨迹
- 公式: $r_{\text{comp}} = \frac{1}{|G|} \sum_{i=1}^{|G|} \left(1 - \frac{|S_i|}{|\chi_i|}\right)$
- 目的: 鼓励策管器蒸馏可重用技能而非存储原始轨迹

#### 总奖励

$$r = r_{\text{task}} + \lambda_f \cdot r_{\text{fc}} + \lambda_u \cdot r_{\text{cnt}} + \lambda_c \cdot r_{\text{comp}}$$

其中 $\lambda_f=1.0$, $\lambda_u=0.1$, $\lambda_c=0.05$（经验设置）

**设计思路**: 这个奖励结构体现了"端到端+过程监督"的混合理念。$r_{\text{task}}$ 提供了最终目标信号（executor 表现是否提升），但仅靠它信号太稀疏。辅助奖励（$r_{\text{fc}}$, $r_{\text{cnt}}$, $r_{\text{comp}}$）在中间步骤提供过程信号，引导策管器生成格式正确、内容有用、结构简洁的技能。这种组合设计是将延迟的间接反馈转化为可学习信号的关键。

### 3.4 训练流程（Algorithm 1）

每个训练步的工作流程：

```
1. 采样任务组 G = (x_1, ..., x_|G|)，初始化 SkillRepo S = ∅
2. for i = 1 to |G|:
   a. 从 S 中 BM25 检索与 x_i 相关的技能 S̃
   b. executor π_L 使用 S̃ 执行任务 x_i，生成轨迹 ξ_i
   c. 策管器 π_S 观察 ξ_i 和 S̃，采样策管操作 c_i
   d. 将 c_i 应用到 S：S → ApplyOps(S, c_i)
3. 计算组合奖励 r
4. 使用 GRPO 更新策管器 π_S
```

**关键细节**:
- 每个任务组采样 $N$ 个独立 rollout，每个 rollout 演化不同的仓库历史
- GRPO 优势计算: $A_n = r_n - \frac{1}{N}\sum_{n'=1}^N r_{n'}$
- 优化目标: $\mathcal{L} = \mathbb{E}_n[\min(\rho_n A_n, \text{clip}(\rho_n, 1-\epsilon, 1+\epsilon)A_n)]$
- 丢弃 GRPO 中的 KL 项以鼓励策略探索
- 优势 $A_n$ 均匀分配给 $c_n$ 中的所有 token

### 3.5 实验设置

#### 数据集
- **Agentic 任务**: ALFWorld（文本交互式家居任务）、WebShop（模拟购物环境）
- **推理任务**: AIME24、AIME25、GPQA-Diamond
- 训练数据: ALFWorld/WebShop 的训练集 + DeepMath-103k 中随机抽样的 33,000 个数据点

#### 实现细节
- 基础策管模型: Qwen3-8B
- 训练期间 frozen executor: Qwen3-8B
- 优化算法: GRPO
- 学习率: 1×10^-6
- Batch size: 32, Group size: 8
- 硬件: 16 块 H100 GPU
- 训练时间: ALFWorld ~3天, 推理任务 ~2.5天, WebShop ~5天
- 推理时使用 ReAct（agentic）或 CoT（推理）

### 3.6 主要结果

#### 性能提升
- **ALFWorld**: 以 Qwen3-8B 为 executor，SkillOS 将平均成功率从 55.7（最强基线 ReasoningBank）提升到 61.2
- **WebShop**: 一致提升，同时减少交互步数
- **推理任务**: 以 Qwen3-8B 为 executor，平均准确率从 69.6 提升到 73.8
- **8B 策管器甚至超过 Gemini-2.5-Pro 直接策管**（SkillOS-gemini），证明针对性训练小策管器可以超越大模型的零样本策管能力

#### 效率提升
- ALFWorld 上减少 2.2-3.1 个交互步（vs. 无记忆基线）
- 说明学习到的策管能力使 executor 能识别程序捷径，避免冗余探索

#### 跨任务泛化
- 在推理任务上训练的策管器迁移到 agentic 任务效果最好
- 在 agentic 任务上训练的策管器迁移到其他 agentic 任务效果尚可
- 跨域迁移最弱的模式：WebShop ↔ ALFWorld（环境特定知识过强）

### 3.7 消融实验与分析

#### 奖励消融（ALFWorld）
- SkillOS-GRPO: 61.2 SR
- w/o $r_{\text{cnt}}$（内容质量）: 58.6 → 过程监督的重要性
- w/o $r_{\text{comp}}$（压缩）: 60.0 → 简洁仓库的重要性
- w/o grouping（随机任务序列）: 57.3 → 分组任务流的重要性最大

#### 策管器行为演化

在训练过程中，策管器的操作分布发生了显著变化：

**初期**: 
- 插入操作主导（>80%）
- 集中精力从经验中蒸馏新知识填充 SkillRepo

**训练后期**:
- 更新操作比例上升，插入比例下降
- 表明策管器从"原始扩展"转向"优化现有技能"
- 删除操作保持小比例但略有上升，表明压缩奖励有效

#### 技能演化动力学

**单个技能内容演化**:
- 初期: 引入通用章节（如附加指导、提示、建议）→ 技能冗长但操作价值有限
- 后期: 转向可操作结构（如失败处理逻辑、条件分支）→ 执行导向的技能优化

**技能全局组织演化**:
- 初期: 窄域、任务特定的技能为主
- 后期: 元策略技能多样化，涵盖验证、回退规划、系统搜索、策略调整等
- 说明策管器从"孤立的任务局部流程"向"可组合的跨任务控制知识"转变

#### 技能使用归因分析
- SkillOS 在所有评估样例中都调用了技能（vs. 基线 87.9%）
- 技能使用成功率更高（100% vs. 88.6%）
- 更大比例的策管技能被实际使用
- 每个样例使用的技能数更少 → 更精确的技能选择

### 3.8 跨 Executor 泛化

训练时使用 Qwen3-8B 作为 executor，测试时泛化到：
- Qwen3-8B：一致提升 +13.3 ALFWorld SR
- Qwen3-32B：一致提升 +14.1 ALFWorld SR
- Gemini-2.5-Pro：一致提升 +13.8 ALFWorld SR

关键发现：Gemini-2.5-Pro 直接作为策管器（SkillOS-gemini）反而不如训练后的 8B 策管器，特别是在配合小 executor 时 → 存在"策管器-executor 不匹配"问题：大模型策管的技能可能与小 executor 的能力或使用模式不匹配，而 RL 训练学会了 executor-grounded 的策管行为。

---

## 4. 总结与意义

SkillOS 提出了一个**经验驱动的 RL 训练方案**，用于学习自我进化 agent 中的技能策管能力。其核心贡献包括：

1. **模块化设计**: 将技能策管器与 agent 执行器解耦，实现模块化策管优化
2. **分组任务流**: 构造具有技能依赖关系的任务组，将策管决策与下游任务结果关联
3. **组合奖励**: 结合任务结果、函数调用有效性、技能质量和压缩度，将延迟间接反馈转化为学习信号
4. **实证效果**: 在多个基准和 LLM 骨架上一致提升性能和效率，且学习的策管策略可跨执行器和任务域泛化

**局限与未来方向**:
- 当前主要验证了单轮策管（每个任务后策管一次），更细粒度的实时策管有待探索
- 技能表示目前限于 Markdown 文件，更丰富的技能形式（如代码脚本）可能带来更多收益
- 跨域泛化中环境特定知识与通用策略的平衡仍需进一步研究

---

## 5. 关键引用

- Anthropic. Skills. https://github.com/anthropics/skills, 2025b. —— Markdown 技能格式的来源
- Shao et al., 2024. GRPO: Grouped Reward Policy Optimization. —— 训练算法
- Fang et al., 2025b. MemP: Procedural memory with advanced memory-management strategies. —— 主要基线方法之一
- Ouyang et al., 2026. ReasoningBank: Distilling reusable insights from past experiences. —— 主要基线方法之一
- Xia et al., 2026. SkillRL: Teaching smaller models to use skills. —— 技能学习的相关工作
- Tu et al., 2026. D2Skill: Iterative skill curation from powerful LLMs. —— 技能学习的相关工作