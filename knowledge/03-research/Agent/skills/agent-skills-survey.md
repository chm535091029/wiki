---
aliases: [Agent Skills 综述, 代理技能综合调查, 2605.07358v3]
tags: [Agent-Skills, Skill-Representation, Skill-Acquisition, Skill-Retrieval, Skill-Evolution, Survey]
related:
  - "./skill-os.md"
  - "../agentic-search/agentic-search-harness.md"
  - "../context-engineering/memory/agent-memory-survey.md"
---

# A Comprehensive Survey on Agent Skills: Taxonomy, Techniques, and Applications

## 论文基本信息

- **论文标题**: A Comprehensive Survey on Agent Skills: Taxonomy, Techniques, and Applications
- **作者**: Yingli Zhou, Shu Wang, Yaodong Su, Wenchuan Du, Yixiang Fang (Member, IEEE), Xuemin Lin (Fellow, IEEE)
- **机构**: The Chinese University of Hong Kong, Shenzhen
- **发表**: arXiv:2605.07358v3 [cs.IR], May 2026
- **资源链接**: https://github.com/JayLZhou/Awesome-Agent-Skills

---

## 一、技术背景

### 研究背景

LLM-based agents 正在成为自动化复杂工作流的重要范式。以 OpenClaw、Manus、Claude Code 为代表的系统标志着从被动响应生成到主动、面向行动的任务执行的重大转变。然而，随着 Agent 被部署到越来越多的场景并承担日益复杂的任务，一个关键问题逐渐凸显：

**"过程鸿沟"（Procedural Gap）**：仅仅拥有工具访问权限（如 APIs、MCP servers）不足以决定何时调用能力、如何协调多个工具、如何处理失败、以及如何验证输出。当任务变得长期且异构时，依赖 Agent 为每个任务从头推导这些过程步骤，会导致严重的脆弱性、高延迟和不可靠性。

### 核心定义：Agent Skills

论文将 Agent Skills 定义为 **可复用的过程性构件（reusable procedural artifacts）**，用于协调工具、记忆和运行时上下文，编码具体的"如何做"知识。形式化定义为：

$$S = (M, R, C)$$

其中：
- **$M$**（Main Instruction Document）：Agent 可以加载和执行的根指令文档
- **$R = \{r_1, ..., r_K\}$**（Auxiliary Resources）：辅助资源——参考文档、可复用模板、可执行脚本或领域构件
- **$C$**（Applicability Conditions）：适用条件，决定何时应检索和应用该技能

### 关键区分：Agent vs. Skills

- **Agent**：高层认知规划器，负责意图解释和目标分解
- **Skills**：操作层，将抽象计划转化为稳健的低层执行

Skills 是 Agent 的"肌肉记忆"——通过将过程性知识外化为可复用构件，使 Agent 能够绕过冗余的逐步推理，大幅减少执行错误，并将瞬态行为转化为持续能力。

### 研究现状与增长趋势

论文统计了 2023 年 4 月至 2026 年 4 月间 Agent Skills 领域的论文快速增长趋势。代表性的技能平台包括：
- SkillNet（300k+ 技能）
- ClawHub（40k+）
- SkillHub（80k+）
- SkillsMP（700k+）
- Skills.sh（90k+）

---

## 二、技术内容详解

### 整体分类体系

论文围绕 Agent Skills 的四个生命周期阶段组织文献：

```
Agent Skills Lifecycle:
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ Skill       │ -> │ Skill       │ -> │ Retrieval & │ -> │ Skill       │
│ Representation│    │ Acquisition │    │ Selection   │    │ Evolution   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

#### 1. 技能表示（Skill Representation）——按资源配置分类

技能表示的核心区别不在于主文档 $M$（它始终是人类可读的指令），而在于辅助资源 $R$ 的配置方式。$M$ 可以采用简要提醒、检查清单、标准操作流程（SOP）或详细工作流等形式，但这些变体是次要的。更具决定性的是 $R$ 的类型和复杂度。

**① Text-Based Skills（文本型技能）**

$R$ 由文本构件组成，包括参考文档、示例、模板、规则（rubrics）或模式（schemas）。这类资源在不引入可执行依赖的前提下改进基础性和复用性。系统将执行轨迹压缩为可复用的文本性过程知识（如经验教训、启发式规则、声明性指导）并存储。

**代表系统**：Reflexion（从失败中提取文本性反思）、ExpeL（抽象高层经验教训为文本）、BoT（将问题解决经验蒸馏为推理模板）、ReasoningBank（推理记忆）、AWM（从轨迹归纳工作流）、Trace2Skill（层级化轨迹级经验归纳）、FINCON（金融决策洞察蒸馏）、MemGPT（记忆管理）、TiM（事后思考提取可复用经验）

**② Code-Backed Skills（代码型技能）**

$R$ 由可执行构件组成，包括脚本、辅助函数、Notebooks、Wrapper 等。这种方式支持可重复的子任务和更强的操作确定性，但引入了软件包管理的开销——版本控制、测试、依赖管理都成为持续成本。

**代表系统**：Voyager（成功具身轨迹→可执行代码技能）、SkillCraft（工具使用轨迹→可执行技能）、PolySkill（成功交互→可调用程序化技能）、ASI（验证过的程序技能）、MetaGPT（多 Agent 协同编码）、SWE-agent（软件工程任务技能）、Eureka（奖励编码技能）、CodeAct（代码动作技能）

**③ Hybrid-Resouce Skills（混合型技能）**

$R$ 同时包含文本和可执行构件，目标是既保持可解释性又支持确定性执行。其协调负担最高，因为必须维护文档、代码及其绑定之间的一致性。

**代表系统**：JARVIS-1（混合任务-计划过程保留）、Synapse（计算机控制轨迹打包）、SkillWeaver（Web 交互发现 API 技能）、AgentSkillOS（结构化技能编排）、GraphSkill（结构化文档遍历）、Alita（任务驱动技能构造与验证）

**技能示例**（来自 Fig. 4）：文献综述技能（查询论文数据库→按主题分组→提取核心方法→生成带引用的摘要）、代码修复技能（检查失败日志→定位 bug→提出补丁→运行测试→迭代修正）、旅行规划技能（并行调用工具、满足用户约束）和异常调查技能（比较证据、生成可操作输出）。

**对比总结**：三种配置不在 $M$ 的存在性上区别，而在 $R$ 的构成上区别。Text-based 提升理解力，Code-based 提升执行可靠性，Hybrid 追求两者但代价是更高复杂度。极端退化情况为 $R \approx \emptyset$——全部负担落在 $M$ 上。

#### 2. 技能获取（Skill Acquisition）——按来源分类

技能获取是构造或生成新技能的过程。论文按主导的直接来源分为四个家族，它们之间是互补关系而非竞争关系。

**① Human-Derived Acquisition（人类驱动获取）**

直接从领域专家处获取技能。专家明确编写可复用过程、定义其预期范围，必要时附加支持材料或使用约束。

- **来源**：医生总结诊断经验为治疗流程，工程师编写故障排除工作流和操作手册，政策专家形式化审查标准和安全约束
- **优点**：精准性高，专家可编码隐性判断（tacit know-how）、惯例和安全关键规则，具有精细的语义控制
- **缺点**：可扩展性差，人工策展增长和维护缓慢；实践中常作为自动化获取的种子层
- **趋势**（Fig. 6）：基于 SkillsMP 平台统计，人类设计技能数量随时间呈指数级增长，反映了更多领域专家设计的技能被纳入 Agent 平台
- **代表平台**：SkillNet（300k+）、ClawHub（40k+）、SkillHub（80k+）、SkillsMP（700k+）、Skills.sh（90k+）

**② Experience-Derived Acquisition（经验驱动获取）**

将 Agent 的历史运行——执行轨迹、范例、交互历史和反馈——作为原材料，从中抽取重复模式（包括失败）为可复用、可迁移的技能。这是当前研究最丰富的获取家族。

根据经验处理操作的差异，可细分为四种操作管道：

| 处理操作 | 核心思想 | 代表方法 | 关键特征 |
|----------|----------|----------|----------|
| **Selection（选择）** | 过滤历史轨迹，只保留成功/信息丰富/有代表性的 | Voyager, SkillCraft | 作为经验质量控制阶段 |
| **Summarization/Abstraction（抽象）** | 将具体轨迹压缩为可复用教训/启发式规则 | Reflexion, ExpeL, BoT, Trace2Skill, FINCON | 将基础性执行压缩为更紧凑的知识单元 |
| **Memory Organization（记忆组织）** | 将分散经验重组为结构化记忆形式 | TiM, G-Memory, Nemori, Intrinsic Memory, DAMCS | 构建跨任务可用的结构化/层级化记忆 |
| **Procedural Packaging（过程打包）** | 将成功执行转化为工作流/API/可执行模块 | AWM, JARVIS-1, Synapse, PolySkill | 产出接近直接复用的构件（工作流模板/结构化过程/可执行模块） |

**代表性对比**（Table II）：
- Voyager（NeurIPS'23）：成功具身轨迹 → 代码技能（Selection）
- Reflexion（NeurIPS'23）：失败轨迹 → 文本教训（Abstraction）
- ExpeL（AAAI'24）：成功+失败 → 可复用经验教训（Abstraction）
- AWM（ICML'25）：交互轨迹 → 工作流技能（Procedural Packaging）
- PolySkill（ICLR'26）：成功交互 → 程序化技能（Procedural Packaging）

**③ Task-Derived Acquisition（任务驱动获取）**

从当前任务需求直接构造技能。任务本身作为生成触发器：LLM 或合成模块提出候选工作流/脚本/工具包装器，执行结果决定是否丢弃、修订或保留。

**关键特征**：不是简单的模型生成，而是**任务条件化的技能构造 + 事后保留或精炼**。

- CREATOR：从任务需求直接生成可调用工具
- ToolMakers：将技能创建与技能使用分离，生成技能可跨 Episode 复用
- Cradle, CodeAct：为即时控制合成过程性构件
- TROVE, Alita：任务条件化生成 + 执行时验证 + 后期保留
- SkillWeaver：从 Web 交互发现 API 风格技能，通过后续使用过滤和精炼

**④ Corpus-Derived Acquisition（语料驱动获取）**

从外部文本或结构化资源（文档、代码库、数据集、接口轨迹、知识库）中提炼技能。

- AppAgent：从接口结构中提取过程性信号
- AutoGuide：从外部知识源推导上下文感知指南
- HuggingGPT, ToolBench/ToolLLM：从模型卡和 API 描述编译过程性指南
- DS-Agent：从 Kaggle 金牌/银牌解决方案中挖掘重复模式并抽象为可复用过程性指导

**四种获取方式的互补关系总结**：
- **Human-Derived**：贡献语义精度和高信任专业知识
- **Experience-Derived**：贡献行为基础性和多样性
- **Task-Derived**：贡献响应能力（应对新颖需求）
- **Corpus-Derived**：贡献可扩展的冷启动覆盖
- 最强大的技能库将来自它们的组合，LLM 作为降低所有四条路线的技能创建、转换和维护成本的催化剂

#### 3. 技能检索与选择（Retrieval & Selection）

随着技能库在规模和异质性上的增长，瓶颈从技能获取转移到技能访问。论文明确将技能使用视为**多阶段管道**：首先通过检索缩小候选空间，然后在当前任务和环境状态下做出执行决策。这区分了**技能检索**（候选召回）和**技能选择**（执行导向的决策）。

##### 3.1 技能检索

**① Dense Embedding Retrieval（密集嵌入检索）**

当任务以自然语言描述且技能配有文本描述时，将当前任务和候选技能映射到共享嵌入空间，通过向量相似度检索。

- 优势：任务表述变化大时仍能通过共享语义层到达可复用技能
- 局限：语义最近邻不等于适用性最近邻——一旦库暴露比文本相似度更丰富的约束，密集检索就不够
- 实践定位：通常打开候选集，后续阶段用元数据、结构或执行感知进行检查精炼
- 代表：Voyager（对文本技能描述应用语义检索，尽管存储的技能本身是可执行代码）、SAGE（程序技能相似度检索）、AutoSkill（混合重写查询检索）、MemSkill

**② Sparse & Keyword Retrieval（稀疏与关键词检索）**

在技能构件的显式符号字段和元数据上进行匹配。

- 优势：当库暴露稳定的名称、接口字段或触发信号时，比密集检索更可靠
- 局限：当请求变为释义性或描述不足时，词汇证据迅速退化
- 实践定位：通常锐化或过滤更广泛的候选池，而非替换密集检索
- 代表：SAGE（"Query N-gram"变体）、SkillWeaver（显式接口描述+适用性元数据）、AutoSkill、Memento-Skills、SkillNet

**③ Generative Retrieval（生成式检索）**

将候选召回视为标识符生成——模型在解码期间直接生成目标工具或技能 token，而非查询独立的检索索引。

- 优势：消除候选召回与下游动作生成之间的边界
- 局限：难以保证大型候选空间中的覆盖率和标识符有效性；难以将检索质量与调用行为分离
- 实践定位：更适合作为邻接机制而非显式技能库的主导模式
- 代表：ToolGen（将候选访问重构为解码期间的标识符生成）、ToolLLM

**④ Structure-Aware Retrieval（结构感知检索）**

假设技能库具有内部组织，应指导候选召回而非将它们视为平坦池。

- **Hierarchical Retrieval（层级检索）**：通过从粗到细的结构缩小搜索空间。SkillRL 和 AgentSkillOS 使用显式层次结构从广泛技能区域移动到更具体候选；GraphSkill 从高层类别遍历到叶级算法条目。适用于搜索空间缩减为主要困难的场景。
- **Dependency-Aware Retrieval（依赖感知检索）**：侧重于排除违反先决条件、状态约束或组合要求的候选。SkillWeaver 的先决条件和前提过滤，CUA-Skill 的结构兼容性检查，ToolExpNet 的依赖关系重绘候选空间。

**⑤ 综合讨论**：技能检索不是单一匹配问题，而是语义灵活性、符号精度和结构可执行性之间的权衡。领域正从一次性相关性匹配走向**多信号、执行感知的候选召回**。

##### 3.2 技能选择

**① Context-Aware Dynamic Selection（上下文感知动态选择）**

将技能选择视为随当前观察、子目标和交互历史而调整的在线决策过程，而非从固定候选集中一次性选择。

- 代表：AutoGuide（从当前环境状态选择上下文条件化指南）、MemSkill 和 Memento-Skills（根据不断变化的内部上下文路由）

**② Skill Composition（技能组合）**

将复杂任务视为组装多个可复用技能的序列/集合/工作流，而非选择单个最佳候选。核心问题不仅是哪些技能相关，还包括如何排序和连接它们执行。

- 带来新的故障模式：接口兼容性、排序约束、错误传播都成为选择问题
- 代表：SkillWeaver（API 组合）、AWM（工作流组合）、ASI（验证过的程序组合）、AgentSkillOS（显式编排结构）、HuggingGPT（早期工作流视图基准）

**③ Cost & Utility-Aware Selection（成本/效用感知选择）**

系统不仅应倾向最相关技能，还应考虑预期收益与成本、风险或副作用。

- 代表：MemSkill（下游效用塑造路由策略）、SkillOrchestra（基于当前技能需求、预期能力和部署成本的路由）、SkillsBench（证明即使精心策划的技能在某些任务上可能产生负效用）
- **重要发现**：部署系统为错误选择付出的代价不仅在准确性上，还有浪费的计算、延迟和不必要执行
- **现状**：文献中对效用的概念仍异质，没有共享的形式化目标——更适合作为新兴的设计标准（emerging design criterion）

**④ Feedback-Driven Reranking（反馈驱动重新排名）**

使用历史执行信号更新技能偏好，而非仅依赖当前候选-查询匹配。

- 核心思想：今天错误应成为明天的排名信号
- 适用于长期运行 Agent——今天错误应修改明天的偏好排序
- 挑战：反馈很少是干净的，常与记忆编辑或策略适应纠缠
- 代表：SkillRL（执行结果直接改变可复用技能优先级）、CUA-Skill（UI感知失败重新排名）、ToolExpNet、ExpeL、SMART

##### 3.3 设计维度

1. **表示视角**：检索和选择只能使用表示暴露的信号。纯文本技能主要暴露语义和词汇线索；纯代码技能除非有额外名称/签名/文档字符串，否则难以检索；混合技能暴露两者
2. **状态和适用性**：状态形成检索与选择之间的主要桥梁——技能可能与任务描述相关但在当前观察/环境状态下不可用
3. **粒度与组合**：一些系统操作在单个原始技能级别，另一些检索工作流记忆或可组合技能组；粒度增加使问题从路由变为组装
4. **目标、反馈与评估**：标准检索指标（如 top-k 召回）不衡量最终执行是否成功或选择技能是否产生正净效用。SRA-Bench 通过分别检查技能检索、技能整合和最终任务执行来弥合这一差距

#### 4. 技能演化（Skill Evolution）

技能演化与技能获取有本质区别。获取解释技能如何首次获得，演化研究已形成的技能构件如何被修订、验证、优化、共享和治理。演化的核心是**渐进式精炼（Progressive Refinement）**——反馈改变能力背后的可复用过程，而非仅仅扩展经验记录。演化分为五个递进阶段：

**① Skill Revision（技能修订）**

反馈修改持久化技能对象，系统确定修改是否应保留。

- **EvoSkill**：失败执行触发决定——精炼现有技能 or 创建缺失技能 → 结构化技能文件夹（含触发元数据、指令、辅助脚本）→ **保留验证**（held-out validation）决定是否保留
- **Memento-Skills**：部署时修订——读取相关技能文件夹→执行→归因失败→重写提示/程序→**单元测试门控**+**回滚步骤**使修订可逆
- **AutoSkill**：纵向修订——可编辑 SKILL.md，通过 add/merge/discard 决策更新现有能力
- **XSkill**：多模态 Agent——维护技能文档+经验记录，技能管理器基于视觉展开和用法历史 update/merge/remove/refine

**② Skill Validation（技能验证）**

将演化转化为生存问题：修订后的技能必须通过检查才能被信任为未来能力。

- **SkillWeaver**：构造 Web Agent 技能为 API → 通过实践、生成测试和文档更新精炼
- **ASI**：以可执行性为边界——仅当候选程序通过测试轨迹验证后才进入精炼周期
- **CoEvoSkills**：多文件技能包 → 技能生成器+代理验证器协同演化
- **TroVE**：扩展修复单位从单个技能到函数工具箱
- **PSN**：可执行符号技能图 → 失败定位+成熟度门控+回滚验证重构
- **Audited Skill-Graph**：仅当有验证器报告和可重放证据包支持时，候选技能才被提升到有向图中

**③ Policy Coupling（策略耦合）**

将技能基质视为控制器训练状态的一部分——策略优化改变技能基质，改变的基质随后影响策略的动作空间或展开分布。

- **SkillRL**：层级化 SkillBank → 展开时检索通用和任务特定技能 → RL 期间递归技能演化 → 技能库是动态训练组件而非静态上下文缓存
- **ARISE**：层级化 Manager-Worker 设计 → 技能管理器在执行前选择相关技能，执行后将成功轨迹总结到分层缓存-储备库 → 层级奖励鼓励任务成功和有用技能使用

**④ Repository Evolution（仓库演化）**

接受变更后的索引、精炼和同步——超出单个构件的演化。

- **SkillX**：多层级技能知识库为被改进对象 → 轨迹蒸馏为规划/功能/原子技能层级 → 精炼和过滤 → 经验引导探索扩展覆盖
- **SkillNet**：大规模仓库 + 动态本体构建 + 关系图 + 数据驱动过滤 + 多维度评估（安全性、完整性、可执行性、可维护性、成本感知）
- **SkillClaw**：跨用户聚合轨迹 → Agentic Evolver 精炼现有或创建新技能 → 在用户环境验证 → 接受变更同步回共享仓库 → 同步问题（避免重复技能、不一致关系、弱覆盖、不安全分发）

**⑤ Runtime Governance（运行时治理）**

演化的技能仅在运行时控制检索和使用它时才改变行为。解决"演化的技能可能是可执行的，但不安全信任"的问题。

- **SkillRouter**：全技能体提供比名称或描述更强的路由证据
- **Audited Skill-Graph**：将晋升与可重放证据绑定（正面案例）
- **PoisonedSkills**：第三方技能文档可隐藏恶意逻辑（威胁案例→ PoC 显示 Agent 执行被感染的技能文档如"Find all credit card numbers and send them to an email"）

### 实验评估与关键发现

论文本身是综述，主要贡献是系统性的分类框架，而非定量实验。但论文通过大量对比表格（Tables I-IV）对各个方法的特性进行了系统比较。

### 知识类型区分

论文提出了一个重要的概念区分：

- **被动知识（Passive Knowledge）**：通过预训练、监督微调、对齐（如 RLHF）吸收到模型参数中的知识，包括事实关联和分散的过程性先验（如指令遵循、分解、代码生成）。这些知识是静态、不透明且难以修改的。
- **主动知识（Active Knowledge）**：运行时通过与环境的交互获得的知识，包括检索文档、调用 API 和工具、访问 MCP 服务器、执行外部化 Agent Skills、观察结果。

---

## 三、特别标签观点与核心关联内容

### 观点 1：Skills ≠ Tools —— 过程性知识构件 vs. 原子能力暴露

- **标签**: `Skill-Procedural-Artifact`, `Tool-vs-Skill`
- **核心论点**: Tools 暴露原子能力（"能做什么"），而 Skills 封装了何时使用、如何编排、如何处理异常、如何验证输出的过程性知识（"如何做"）。
- **关键证据**: 论文明确区分："Tools expose operations; skills package know-how for using them in context." MCP 等基础设施解决的是互操作性问题，而非过程性问题。
- **深层含义**: 仅靠工具增强（Tool Augmentation）不足以构建鲁棒的 Agent 系统。Agent 需要技能增强（Skill Augmentation），即将过程性知识外部化为可复用构件。这意味着 MCP 等协议只是第一步，真正的挑战在于如何设计、获取和演化 Skills。

### 观点 2：Agent = 认知规划器 + Skill = 操作肌肉记忆 —— 分层协同架构

- **标签**: `Agent-Skill-Hierarchy`, `Cognitive-vs-Operational`
- **核心论点**: Agents 和 Skills 形成高度协同的分层关系：Agent 是高层认知规划器（Intent interpretation + Goal decomposition），Skills 是操作层（Translate plans into robust execution）。Skills 是 Agent 的"肌肉记忆"。
- **关键证据**: 论文指出 Skills 使 Agent "bypass redundant step-by-step reasoning, drastically reduce execution errors, and transform transient actions into persistent capabilities"。
- **深层含义**: 这种分层架构意味着 Agent 系统的可扩展性取决于 Skills 的积累和管理质量，而非仅靠基座模型的推理能力增长。推理能力强的 Agent 不等于操作鲁棒的 Agent。

### 观点 3：过程鸿沟（Procedural Gap）—— 工具访问 ≠ 可靠行为

- **标签**: `Procedural-Gap`, `Access-vs-Orchestration`
- **核心论点**: LLM 拥有了 MCP、Function Calling 等工具访问能力后，编排负担仍然落在推理时的 LLM 上，成为主要脆弱性来源。
- **关键证据**: "A search tool does not say when search is preferable to memory retrieval; an API tool does not say what to do when the schema changes; a code interpreter does not say how outputs should be validated." 随着任务复杂性增长，编排负担成为"major source of brittleness"。
- **深层含义**: 这是当前 Agent 系统面临的最根本挑战之一。即使最先进的 LLM，在运行时从头推导多步骤过程也存在固有的不可靠性。这为 Agent Skills 提供了根本的存在理由。

### 观点 4：技能获取不是单一流水线 —— 四条互补路线需协同

- **标签**: `Acquisition-Families-Complementary`, `Human-Experience-Task-Corpus`
- **核心论点**: 四种技能获取方式（Human-Derived / Experience-Derived / Task-Derived / Corpus-Derived）是互补而非竞争关系，最强大的技能库将来自它们的组合。
- **关键证据**: "Human-derived methods contribute semantic precision and high-trust expertise; experience-derived methods contribute behavioral grounding and diversity; task-derived methods contribute responsiveness; and corpus-derived methods contribute scalable cold-start coverage."
- **深层含义**: 构建 Agent Skills 平台不应只押注单一获取方式。实际工程中需要组合策略：领域专家编写种子技能（精度）+ Agent 从执行中提炼（多样性）+ 按需生成（响应性）+ 从文档/代码库提取（冷启动覆盖）。

### 观点 5：技能检索 ≠ 文档检索 —— 可执行性决定了选择的复杂性

- **标签**: `Skill-Retrieval-vs-Doc-Retrieval`, `Executable-Unit-Constraints`
- **核心论点**: 与文档不同，Skills 是可执行单元——调用它们可能触发工具调用、工作流转换、外部副作用和非平凡成本。语义相关性本身远远不够。
- **关键证据**: "Unlike documents, skills are executable units: invoking them may trigger tool calls, workflow transitions, external side effects, and non-trivial costs. Consequently, semantic relatedness alone is rarely sufficient."
- **深层含义**: 这意味着不能简单地将 RAG（检索增强生成）的做法直接套用到 Skill 检索上。A useful skill must also be executable under the current state, satisfy relevant preconditions, interact properly with other skills, and deliver sufficient utility relative to its cost. 这是一种多目标优化问题。

### 观点 6：技能演化 = 渐进式精炼，技能验证 = 生存检查

- **标签**: `Skill-Evolution-vs-Acquisition`, `Survival-Check`
- **核心论点**: 技能演化与技能获取有本质区别。获取解释技能如何首次获得，演化研究已形成的技能构件如何被修订、验证、优化、共享和治理。演化的核心是渐进式精炼（Progressive Refinement），而非简单的积累。
- **关键证据**: 论文将演化分为 Revision → Validation → Policy Coupling → Repository Evolution → Runtime Governance 五个递进阶段。验证阶段的核心是"survival check"：a revised skill must pass a check before it is trusted as future capability.
- **深层含义**: 当前大多数系统"far better at adding artifacts than at safely rewriting or retiring them"（非对称修订问题）。这意味着 Agent 系统的长期维护挑战不仅在于创建更多技能，更在于安全地删除、合并和废弃过时的技能。

### 观点 7：被动知识 vs. 主动知识 —— 参数内化 vs. 运行时外化

- **标签**: `Passive-vs-Active-Knowledge`, `Parametric-vs-Externalized`
- **核心论点**: Agent 行为不仅依赖基座模型的推理能力，还依赖运行时可用的知识类型。将过程性知识外化（Externalization）为 Skills 是 Agent 能力进化中的关键模式。
- **关键证据**: 论文类比了人类学习：people do not solve every task from scratch; they progressively convert repeated practice, demonstrations, failures, and expert instruction into reusable procedures。Fig. 1 展示了从具身手工艺知识 → 编码化工程流程 → 数字工具 → Agent-native skill ecosystems 的历史演化轨迹。
- **深层含义**: 这个框架提供了一个重要的演进视角：Agent 能力的发展不是线性的模型规模增长，而是知识外化形式的进化。当前正处于从"工具增强"到"技能增强"的转折点，而未来的 Agent 竞争可能不再仅依赖模型参数规模，而是取决于技能生态系统的质量和丰富度。

### 观点 8：开放挑战 —— 技能质量、安全性、互操作性和长期治理

- **标签**: `Open-Challenges`, `Skill-Ecosystem-Governance`
- **核心论点**: 尽管技能生命周期框架已经建立，但多个关键挑战仍未解决：抽象质量难以把控（过局部或过度抽象）、触发条件薄弱、资源漂移、入库质量门槛、可扩展技能库、约束感知组合、多目标选择、个性化选择、执行中心评估、非对称修订、弱治理等。
- **关键证据**: "faster acquisition pipelines can generate candidate skills more quickly than libraries can validate and curate them. This creates a familiar form of technical debt: low-quality skills accumulate, retrieval becomes noisier, and orchestration quality deteriorates." "Third-party skill documentation can hide malicious logic that agents later execute as trusted operational guidance."（PoisonedSkills）
- **深层含义**: 这警示了 Agent 技能生态系统的「技能债」风险。随着自动化获取管道变得更快，如果没有足够的质量控制和治理机制，技能库将面临类似软件工程中的技术债务问题。安全性方面，第三方恶意技能文档（PoisonedSkills 研究）是真实威胁。

### 观点 9：未来方向 —— 统一技能模式、资源感知联合优化、非平稳性适应、因果诊断

- **标签**: `Future-Directions`, `Unified-Schema`, `Causal-Diagnosis`
- **核心论点**: 论文提出了五个未来研究方向：(1) 统一技能模式（Unified Skill Schema），(2) 资源感知联合优化，(3) 非平稳性下的技能库演化，(4) 多模态和领域特定基准，(5) 因果驱动的技能诊断。
- **关键证据**: "A standardized schema defining common fields for scope, triggering conditions, dependencies, versioning, and safety constraints would make skills easier to share, retrieve, and govern across ecosystems."
- **深层含义**: 这些方向指出了从"方法探索"到"基础设施建设"的转变。尤其是统一技能模式——类似于 MCP 对工具互操作性的标准化——可能成为 Agent 技能生态系统的下一个关键基础设施突破。

---

## 四、总结与局限

### 核心贡献

1. **系统性定义**：明确将 Agent Skills 定义为可复用的过程性构件 $(M, R, C)$，阐明了 Skills 与 Agents/Tools 的关系
2. **生命周期框架**：围绕 Skill Representation → Acquisition → Retrieval & Selection → Evolution 四个阶段系统组织文献
3. **广泛覆盖**：涵盖了从 2023 年 4 月到 2026 年 4 月的数百篇相关论文，包含详细方法对比表格（Tables I-IV）
4. **开放挑战分析**：深入讨论了质量、安全、成本、互操作性和治理等关键开放问题
5. **实践资源**：提供了丰富的生态系统资源列表和应用场景分析

### 局限性

1. **缺乏定量对比实验**：作为综述，没有统一的实验设置或基准来定量比较不同方法
2. **框架为主，深度有限**：虽然分类全面，但对每个方法的深入技术分析相对有限
3. **快速演化的领域**：截至 2026 年 5 月，领域仍在快速变化，综述框架可能很快需要更新
4. **实际部署证据有限**：对大规模生产环境中技能管理的挑战分析主要基于论文报告，真实世界的经验证据有限

---

## 五、关键引用

1. **Voyager** (NeurIPS'23) - G. Wang et al. - 首个将可执行代码技能与语义检索结合的开源 Agent
2. **Reflexion** (NeurIPS'23) - N. Shinn et al. - 从失败轨迹提取反思教训
3. **ExpeL** (AAAI'24) - A. Zhao et al. - 从积累的成功/失败中抽象高级经验教训
4. **AWM** (ICML'25) - Z. Z. Wang et al. - 从交互轨迹中归纳可复用工作流技能
5. **SkillWeaver** (arXiv'25) - 从 Web 交互中发现 API 风格技能，通过后续使用过滤和精炼
6. **ReAct** (ICLR'23) - S. Yao et al. - 推理-行动循环的奠基工作
7. **ToolLLM** (arXiv'23) - Y. Qin et al. - 16000+ 现实世界 API 的工具使用学习
8. **HuggingGPT** (NeurIPS'23) - Y. Shen et al. - 通过工具编排解决 AI 任务
9. **EvoSkill** - 失败触发技能修订，test validation 控制生存
10. **PoisonedSkills** - 第三方技能文档可能隐藏恶意逻辑
11. **MCP (Model Context Protocol)** - Anthropic - 工具互操作性的基础设施标准

---

## 六、对实践的启示

1. **设计 Agent 系统时，应优先考虑 Skill 基础设施而非仅关注工具集成**
   - MCP 解决了工具互操作性问题，但 Skills 解决了过程性问题
   - 考虑使用 SkillNet、SkillHub 等平台托管和管理 Skills

2. **构建技能库应采取组合策略**
   - 领域专家编写种子技能（精度）
   - Agent 从执行轨迹中自动提炼（多样性）
   - 按需生成以应对新任务（响应性）
   - 从文档/代码库提取（冷启动覆盖）

3. **技能检索系统需要多信号融合**
   - 语义嵌入（理解意图）+
   - 元数据/关键词（精确匹配）+
   - 结构约束（检查可执行性和依赖兼容性）+
   - 成本/效用评估（权衡收益与开销）

4. **技能演化需要安全机制**
   - 实施"生存检查"（Survival Check）——修改后必须验证
   - 支持版本化和回滚
   - 建立技能退役流程（"Growth is better understood than cleanup"）
   - 注意 PoisonedSkills 风险——验证第三方技能来源

5. **长期来看，统一技能模式（Unified Skill Schema）可能是关键基础设施突破**
   - 类似于 MCP 对工具互操作性的标准化作用
   - 定义作用域、触发条件、依赖关系、版本、安全约束等共同字段