---
aliases: [Agentic Search, Grep vs Vector, Agent Harness, Lexical Search, Semantic Search, Chronos, LongMemEval, Tool-Calling Architecture, Context Engineering, Inline vs File-Based, 代理检索, 工具调用架构, 检索策略对比, 上下文工程, Is Grep All You Need]
tags: [Agentic-Search, Grep-Retrieval, Vector-Retrieval, Lexical-Search, Semantic-Search, Agent-Harness, Chronos-Agent, LongMemEval, Tool-Calling-Architecture, Context-Engineering, Inline-Delivery, File-Based-Delivery, Claude-Code, Codex-CLI, Gemini-CLI, ReAct, BM25, Dense-Retrieval, RAG, Agentic-System, Context-Noise, Retrieval-Orchestration, Programmatic-Delivery, Provider-Native-CLI, Custom-Harness, LLM-Agent, Long-Memory, Tool-Calling, Context-Rot, Hybrid-Retrieval, RRF, ColBERT, DPR, SPLADE, Temporal-Reasoning, PwC-Research]
related:
  - "../Agent/memory/claude-code-memory.md"
  - "../Agent/skills/skill-os.md"
  - "../Agent/memory/agent-memory-survey.md"
  - "./llm-wiki-combined-rag.md"
---

# Is Grep All You Need? How Agent Harnesses Reshape Agentic Search

## 论文基本信息

- **论文标题**: Is Grep All You Need? How Agent Harnesses Reshape Agentic Search
- **作者**: Sahil Sen, Akhil Kasturi, Elias Lumer, Anmol Gulati, Vamse Kumar Subbiah (PricewaterhouseCoopers, U.S.)
- **发表**: arXiv:2605.15184v1 (2026年5月14日)

---

## 一、技术背景

### 1.1 LLM Agent 检索的现状

现代 LLM agent 越来越依赖 RAG 在推理时访问外部知识。通过工具调用（tool calling），agent 发出搜索查询、接收排序结果、并迭代优化理解。**两种检索范式**主导了这一领域：

| 范式 | 方法 | 特点 |
|------|------|------|
| **语义向量检索** (Semantic/Dense) | 将查询和文档嵌入共享隐空间，进行近似最近邻匹配 (ANN) | 擅长语义相似性、处理同义改写；依赖嵌入模型质量和向量索引基础设施 |
| **词法检索** (Lexical) | 如 grep, BM25, regex——对原始文本进行精确或模式匹配 | 不需要嵌入模型或向量索引，计算成本极低；简单、稳定 |

### 1.2 核心研究空白

已有研究的三个关键盲点：

1. **检索策略与 Agent 架构的交互未被系统研究**：IR 社区虽然广泛评测了词法和密集检索方法，但通常假设固定 pipeline（检索出的文档直接拼接到 prompt 中），忽略了 agent 系统中迭代的、工具介导的检索循环。
2. **工具结果呈现方式的影响未被考察**：结果是被注入（inline）到上下文窗口，还是写入文件由 agent 显式读取（file-based），这两种方式对性能的影响未知。
3. **Provider-Native CLI vs. Custom Harness 的架构差异未被比较**：Claude Code（Anthropic）、Codex（OpenAI）、Gemini CLI（Google）等 CLI 工具与自定义 harness（如 LangChain 构建的 Chronos）在检索有效性上存在根本差异。

### 1.3 检索对抗噪声的鲁棒性问题

随着无关文档与相关文档比例的增加，不同检索策略的退化速率不同。理解这种缩放行为对于在大型噪声语料库上部署 RAG 系统至关重要。

---

## 二、技术内容详解

### 2.1 实验整体设计

论文进行**两个实验**，使用 LongMemEval 116 个问题的子集，覆盖六类信息检索任务：

- **知识更新** (Knowledge-Update): 跟踪随时间推移的状态变化
- **多会话** (Multi-Session): 跨会话聚合信息
- **单会话助手** (Single-Session-Assistant): 回忆模型生成的内容
- **单会话偏好** (Single-Session-Preference): 用户个人偏好
- **单会话用户** (Single-Session-User): 用户陈述的事实
- **时间推理** (Temporal-Reasoning): 计算持续时间、事件排序、日期解析

### 2.2 检索实现细节

#### 词法检索 (Grep)
- 将会话轮次和提取的时间事件从每问题文件加载到内存
- 对原始文本字段执行正则表达式 (regex) 匹配
- 按匹配数量评分并返回——不依赖嵌入模型、向量索引或外部服务

#### 语义检索 (Vector)
- 在 ingestion 时填充搜索索引——每个会话轮次和时间事件被嵌入并存储在每问题索引中
- 查询时嵌入自然语言查询，使用 ANN 检索最相关结果
- 在返回 top-k 结果前进行 **reranking** 步骤（k 由 agent 选择）

#### 结构化事件预处理（Chronos 层）
- 使用 Chronos preprocessing pipeline 从 LongMemEval 对话转录中提取结构化时间事件（显式日期、间隔、相关时间跨度）
- 目的：将时间表达式作为紧凑的平行通道，确保时间推理任务的成功反映的是"能否定位相关证据"，而非"能否从分散的片段重建日期"
- 这模拟了长期记忆 agent 在部署中会使用的预处理配置

### 2.3 Agent Harnesses

#### 自定义 Harness（Chronos）
- 使用 LangChain 构建，配备四种搜索工具（grep/vector over turns/events）
- **动态提示**（dynamic prompting）：系统指令、搜索提示、工具使用指导**依赖于检测到的问题类别**（如时间推理 vs. 偏好回忆），而非对所有项目使用静态提示
- 以 top-15 向量结果的初始上下文块开始，然后进入工具调用循环
- 循环持续直到模型生成最终答案

#### Provider-Native CLI Harnesses
- **Claude Code** (Anthropic)
- **Codex** (OpenAI)
- **Gemini CLI** (Google)
- 接收问题 + 动态生成的搜索策略，可通过绝对路径调用可被 bash 调用的 grep 和向量搜索包装脚本
- 标准模式下在沙箱中生成进程

### 2.4 工具调用架构

| 模式 | 机制 | 特点 |
|------|------|------|
| **标准 (Inline)** | 搜索结果直接返回为工具响应消息，追加到对话上下文中 | 简单直接，但大结果集与系统 prompt、对话历史等争夺上下文窗口——即"上下文腐烂"（context rot） |
| **编程式 (File-Based)** | 搜索结果写入磁盘，模型只收到文件路径/摘要指针，必须显式行动（如 read_file, grep）来获取结果 | 解耦检索结果大小与上下文压力；支持渐进式披露（progressive disclosure）；增加延迟和模型理解文件工作流的负担 |

### 2.5 评测模型

- Claude Opus 4.6, Claude Haiku 4.5（Anthropic）
- GPT-5.4（OpenAI）
- Gemini 3.1 Pro, Gemini 3.1 Flash-Lite（Google）

评测使用 GPT-4o 作为辅助 LLM 评分器，按类别条件指令输出二元判断。

---

### 2.6 实验一：检索模式、Harness 与工具调用方法

#### 设计
隔离检索模式（grep-only vs. vector-only）、agent harness（Chronos vs. Claude Code vs. Codex vs. Gemini CLI）、工具调用方法（inline vs. programmatic），在完整每问题 haystack 上的联合影响。

#### 关键结果

| 观测 | 具体发现 |
|------|----------|
| **Inline Grep > Inline Vector** | 在所有 harness–model pair 上，inline grep 准确率都超过 inline vector。最大差距: Chronos + Gemini Flash-Lite (86.2% vs. 62.9%)；最小: Claude Code + Opus (76.7% vs. 75.0%) |
| **Chronos 上 grep 优势显著** | Inline grep: 83.6–93.1%, Inline vector: 62.9–83.6% |
| **Harness 改变性能天花板** | 同一 Claude Opus 4.6: Chronos 达 93.1%，Claude Code 仅 76.7%——切换 harness 带来的差异 ≈ 切换检索器 |
| **Programmatic 改变排序** | Programmatic vector 在 5/10 的 harness–model pair 上超过 programmatic grep |
| **Codex 极端退步** | Inline grep 达 93.1%，但 programmatic grep 骤降至 55.2%——grep 本身快速准确，但 programmatic 模式使每次命中变为多步工作流 |

#### 分析洞察

**为什么 grep 在 LongMemEval 上表现好？** LongMemEval 奖励恢复字面证据（确切日期、计数、偏好、时间跨度）。词法工具无需嵌入瓶颈就能直接定位这些字符串。**Grep 刻意窄化**：奖励模型生成高精度模式，但惩罚词汇不匹配。**密集检索刻意宽泛**：能找到同义改写和间接提及，但也会提出语义上"接近"的干扰项。

Key Insight: **"检索模式"并非孤立测量——Harness 塑造了系统 prompt、工具描述、命中结果如何渲染回对话，所有这些都影响模型如何安排查询和决定何时停止。** 因此，只报告 BM25 vs. ANN 在静态 pipeline 中的表现，低估了 agent 脚手架引入的方差。

**File-Based 的双刃剑**：File-based 以"缓解上下文压力"为动机，当模型可靠地完成"读取→整合→重试"循环时确实有效。但如果这个循环不可靠，准确率可能独立于检索质量而崩溃。Programmatic 路由在上下文带宽和组合工具能力之间做权衡——只有当 agent 可靠地"闭环"时收益才能实现。

---

### 2.7 实验二：噪声上下文缩放

#### 设计
设置每问题会话上限为 s5, s10, s20, s30, full（29–66 会话），保持 oracle 会话不变，剩余槽位填充采样自其他会话的干扰项。保持工具交付方式固定（inline）。

#### 关键结果

| 观测 | 具体发现 |
|------|----------|
| **Grep 准确率非单调** | Chronos + Opus: s20 时升至 90.5%，s30 降至 85.3%，full 回升至 89.7% |
| **Vector 在低会话数时更强** | s5 时 Chronos vector: 87.9–94.0% vs. grep: 83.2–89.7% |
| **Harness 决定跨交叉点** | Claude Code 偏向 grep；Gemini CLI Pro 偏向 vector；Chronos 随会话数增加出现交叉 |
| **Provider 偏见稳定存在** | Gemini CLI 上 Gemini Pro 始终 vector 领先；Claude Code 上始终 grep 领先——暗示 provider 工具化的归纳偏差 |

#### 分析洞察

核心规律：**密集检索倾向于探索嵌入空间邻域**（能恢复间接提及，但随着会话累积也会引入主题上"虚假朋友"）；**词法检索倾向于利用表面线索**（对措辞脆弱，但一旦发现判别性模式就极其精确）。

Scaling 曲线的价值在于压力测试交互：检索家族并非随着"噪声增加"平行退化——它们与 (i) 每个会话限制配置的干扰项重新采样方式、(ii) harness 特定的工具转录、(iii) 模型何时停止搜索的隐式策略三者交互。

**"30 个会话比 20 个更容易"的现象原因**：干扰项在会话限制变化时重新抽取，中间网格峰值不一定意味着"30 个会话绝对更容易"，而可能反映特定采样的干扰项集合与 agent 搜索轨迹之间的有利干扰。

---

## 三、特别标签观点与核心关联内容

### 观点 1：Grep（词法检索）是 Agent 的有效默认选择

- **标签**: `Grep-Advantage`, `Lexical-Retrieval`, `Agentic-Search`
- **核心论点**: 在 agent 循环的上下文中，inline grep 在几乎所有 model-harness pair 上都优于 inline vector，这与 RAG 领域默认选择向量检索的常见做法形成鲜明对比。
- **关键证据**: 在所有 10 个 harness-model pair 上 inline grep > inline vector，最大差距 23.3 个百分点（Chronos + Gemini Flash-Lite）。
- **深层原因**: LongMemEval 的任务分布中，答案往往由少量字面跨度决定，词法匹配的精度偏见在命中被 inline 注入且立即可用时获得优势。

### 观点 2：Harness 不是被动基础设施——它是检索的统一组成部分

- **标签**: `Harness-Retrieval-Interaction`, `Retrieval-Plus-Orchestration`
- **核心论点**: 切换 harness 带来的准确率变化 ≈ 在同一 harness 内切换检索器。同一模型在不同 harness 上表现差异巨大（Claude Opus 4.6: Chronos 93.1% vs. Claude Code 76.7%）。
- **关键证据**: Chronos 的类别条件动态提示 + 受控工具表面积与 CLI agent 的 provider 特定工具人体工程学、沙箱、转录格式化之间的差异。
- **深层含义**: 在 benchmark 中只报告"BM25 vs. ANN 在静态 pipeline 中的表现"会显著低估 agent 脚手架引入的方差。"检索"实际上是检索加编排（retrieval-plus-orchestration）。

### 观点 3：程序化（File-Based）交付改变任务本质

- **标签**: `File-Based-Delivery`, `Tool-Calling-Stress-Test`, `Compositional-Tool-Competence`
- **核心论点**: 程序化交付将任务从"阅读工具消息"变为"定位、打开并集成工件"——当第二阶段脆弱时，准确率独立于检索质量而崩溃。
- **关键证据**: Codex + GPT-5.4 inline grep 达 93.1%，但 programmatic grep 仅 55.2%（下降 37.9 个百分点）。Programmatic vector 在多个 pair 上反超 grep。
- **深层含义**: File-based 路由本身就是"工具使用压力测试"（tool-use stress test）。它用上下文带宽换取组合工具能力，收益只有在 agent 可靠闭环时才能实现。

### 观点 4：词法和密集检索优化不同的故障模式

- **标签**: `Lexical-vs-Dense-Failure-Modes`, `Precision-vs-Recall-in-Agent-Loop`
- **核心论点**: Grep 刻意窄化——奖励高精度模式但惩罚词汇不匹配；密集检索刻意宽泛——能恢复同义改写但也会吸引语义近似的干扰项。
- **关键证据**: 在 Chronos 的缩放网格上，vector 在较小会话限制时更强，但 grep 能在后期关闭或超越——说明语义检索在范围可控时提供早期覆盖，而 regex 的证据稳定性在 needle-from-haystack 场景下更加突出。
- **深层含义**: "默认使用向量检索"的建议应该**取决于 backbone 强度**和**任务是否奖励字面跨度恢复 vs. 概念融合**——aggregate leaderboard 比较往往掩盖这种细微差别。

### 观点 5："较弱模型"在密集检索上退化更严重

- **标签**: `Weaker-Model-Dense-Degradation`, `Backbone-Strength-Conditioning`
- **核心论点**: 较弱的模型（Claude Haiku 4.5 on Claude Code）在 inline grep 与 vector 之间表现出尤其巨大的差距（55.2% vs. 44.0%）。——较弱模型在迭代查询细化和 reranker 感知阅读上一致性较差，当证据以字面形式存在时，密集检索比模式触发的词法恢复受损更多。
- **关键证据**: Claude Haiku 4.5 on Claude Code: 55.2% inline grep vs. 44.0% inline vector（差距 11.2 个百分点）

### 观点 6：Grep 在 Provider CLI 中并非单一原语——它是 Grep+Shell+Prompting

- **标签**: `Grep-Plus-Shell-Plus-Prompting`, `Vendor-Stable-Bias`
- **核心论点**: Claude Code 上持续的 grep 优势 和 Gemini CLI 上持续的 vector 优势 暗示 provider 工具化的稳定归纳偏差——包括默认提示、stdout 如何分块到 transcript、工具错误界面、CLI agent 的搜索措辞文化等。
- **关键证据**: Claude Code 上 Opus/Haiku grep 始终领先；Gemini CLI 上 Gemini Pro vector 始终领先。即使磁盘语料库按字节相同，CLI 栈之间的迁移也无法在检索上互换。
- **深层含义**: 在生产环境中，"grep"很少是单一原语——它是 grep+shell+prompting 的组合。这在实践中意味着替换 CLI 套件不仅仅是更换调用接口，其检索行为也会随之改变。

### 观点 7：缩放曲线应视为随机外循环的样本，而非平滑容量定律

- **标签**: `Stochastic-Outer-Loop`, `Scaling-Curve-Sampling`
- **核心论点**: 干扰项在会话限制变化时重新抽取，中间网格峰值可能反映特定采样干扰项集合与 agent 搜索轨迹之间的有利干扰，而非平滑的容量规律。但这不削弱两两比较——grep 和 vector 面对的是每个配置下的同一采样捆绑。
- **关键证据**: 多个模型在 s20 的准确率 > s10 > s30（非单调），如 Claude Opus on Chronos: s10 89.7% → s20 90.5% → s30 85.3%。

---

## 四、总结与局限

### 贡献
1. **检索、Harness 和呈现的三维联合分析**：首次系统比较词法/密集检索在 agent 循环中的表现，结合 harness 和工具交付方式分析。
2. **噪声缩放特征**：刻画了随着无关内容增长时端到端行为的变化，包括检索器行为与 agent 循环的交互。
3. **Agent 栈异质性比较**：直接比较显示即使底层文本语料固定，检索有效性在不同架构的 harness 之间不稳定。

### 核心结论
- **在 LongMemEval 任务分布上，grep 在 inline 模式下普遍优于 vector 检索**
- **但"grep beats vector"不应被视为通用结论**——它取决于任务是否奖励字面证据、harness 架构、工具交付方式、模型能力
- **整体分数强烈依赖于哪些 harness 和工具调用风格被使用**——即使底层对话数据相同，file-based 交付和 provider CLI 也能在不对语料库做任何改变的情况下逆转或消除词法优势

### 局限
- 结论局限于**长记忆会话对话 QA**：问题基于多会话聊天、显式时间表达、个人/用户事实。词法工具在这个分布中可能因为答案依赖逐字跨度而获得不成比例的好处。
- 在证据很少是字面意义的领域（如科学论文摘要综合、视觉密集文档、代码语义），密集检索和混合路由可能表现不同。
- Codex vector 的中间配置数据不完整，无法获得跨供应商的完整画面。

---

## 五、关键引用

- LongMemEval: Wu et al., 2025 — Benchmark for long-term interactive memory
- Chronos: Sen et al., 2026 — Temporal-aware conversational agents with structured event retrieval
- ReAct: Yao et al., 2023 — Synergizing reasoning and acting in language models
- BEIR: Thakur et al., 2021 — Benchmark for zero-shot IR evaluation
- SPLADE: Formal et al., 2021 — Sparse lexical and expansion model
- DPR: Karpukhin et al., 2020 — Dense passage retrieval
- RAG: Lewis et al., 2020 — Retrieval-augmented generation
- ColBERT: Khattab & Zaharia, 2020 — Late interaction over BERT
- MemGPT: Packer et al., 2023 — LLMs as operating systems
- ToolLLM: Qin et al., 2024 — 16000+ real-world APIs
- SWE-agent: Yang et al., 2024 — Agent-computer interfaces

---

## 六、对 Agent 系统的实践启示

1. **检索策略不是孤立选择**——它与 harness、工具呈现方式紧密耦合，应作为整体系统设计的一部分来评测。
2. **对于多数长记忆对话查询，优先考虑词法检索作为第一手工具**——其精度偏见在需要恢复字面证据时占优。
3. **File-based 交付应该谨慎对待**——它带来了额外的工具使用复杂度，可能抵消缓解上下文压力的好处。
4. **Provider CLI 之间的切换不仅仅是更换调用接口**——它隐含地改变了检索行为、工具错误处理和搜索策略的内置偏好。
5. **"默认使用向量检索"的建议需要在 backbone 强度和任务类型上做条件化**——较弱模型和字面跨度奖励型任务更受益于词法检索。