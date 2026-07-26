# Harness-Bench：Harness 配置级效应诊断基准

> **论文**: Harness-Bench: Measuring Harness Effects across Models in Realistic Agent Workflows
> **作者**: Yilun Yao, Xinyu Tan, Chao-Hsuan Liu, Yaoming Li, Zhengyang Wang, Wenhan Yu, Zhewen Tan, Yuxuan Tian, Guangxiang Zhao, Lin Sun, Xiangzheng Zhang, Tong Yang (北京大学, 奇瀛科技)
> **发布日期**: 2026年5月27日
> **arXiv**: arXiv:2605.27922v1 [cs.AI]
> **代码**: https://github.com/Qihoo360/harness-bench
> **网站**: http://www.harness-bench.ai/

---

## 核心贡献

Harness-Bench 是一个**诊断性基准测试**，用于研究和评估在真实 Agent 工作流中**配置级 harness 效应**。该 benchmark 使 harness 成为主要评估轴，在共享外部任务条件下跨多个模型后端评估代表性 harness 配置。

**核心公式**:
```
Agent = Model + Harness
```

**核心主张**: Agent 能力应在 **model-harness 配置级别**报告，而不是归因于基础模型本身。

---

## 1. Harness 的精确定义

### 1.1 定义

**Harness** 是条件模型调用并将模型输出转化为外部工作区中行动的系统层。一个 harness 可能包括：

| 组件 | 功能 |
|------|------|
| Prompt Templates | 提示模板 |
| Action Formats | 行动格式定义 |
| Context Construction | 上下文构建策略 |
| Tool Invocation | 工具调用机制 |
| Workspace Access | 工作区访问权限 |
| Permissions | 权限管理 |
| Budget Control | 预算控制 |
| Tracing | 执行追踪 |
| Recovery | 恢复机制 |

### 1.2 为什么 Harness 重要

- 现有基准要么抽象掉执行层、要么将 harness 与完整 Agent 系统混淆、要么固定 harness 来比较模型
- 缺乏诊断性协议来研究 **model-harness 配置**如何影响成功率、Token 成本、鲁棒性和可追溯性
- 同一模型配合不同 harness 表现差异可达 **23.8 个百分点**

### 1.3 6个可配置 Harness 对比

| Harness | 设计类别 | 主要定位 | 执行层重点 |
|---------|----------|----------|------------|
| **OpenClaw** | 长期运行运行时 | 多渠道助手运行时 | 插件、网关、广泛生态系统 |
| **ZeroClaw** | 长期运行运行时 | 自托管系统控制运行时 | 提供商路由、功能开关、单二进制部署 |
| **Hermes** | 长期运行运行时 | 研究导向记忆/技能Agent | 记忆、技能、插件、ACP风格执行 |
| **Moltis** | 安全本地运行时 | 持久化自托管Agent服务器 | 沙箱、密钥库、钩子、本地安全 |
| **NullClaw** | 轻量级运行时 | 低开销自托管执行 | 最小运行时、沙箱、资源效率 |
| **NanoBot** | 轻量级Agent运行时 | 超轻量个人AI Agent | 小核心循环、记忆、MCP、轻量部署 |

---

## 2. Harness-Bench 基准测试设计

### 2.1 任务套件

**规模**: 106个沙盒离线任务（sandboxed offline tasks），8个工作流类别

**任务验证标准（四项准入标准）**：
| 标准 | 含义 |
|------|------|
| **Realism（真实性）** | 反映一个可信的用户工作流 |
| **Solvability（可解性）** | 任务能够使用提供的沙盒资源完成 |
| **Oracle-checkability（可验证性）** | 成功可通过确定性检查或指定标准进行验证 |
| **Integrity（完整性）** | 代理不能通过读取隐藏答案、修改受保护 fixtures 或绕过约束来获取分数 |

**八个工作流类别与任务分布**：
| 类别 | 任务数 | 代表任务示例 |
|------|--------|-------------|
| Software Engineering & Codebase Maintenance | 22 | Code fix, CI repair, DB migration |
| Data, BI & Finance Analytics | 14 | SQL analysis, Metrics audit, A/B analysis |
| Workspace, Tool Use & Multimodal Operations | 15 | File operations, Shell commands, Local web pages |
| Knowledge, Evidence & Retrieval | 13 | Offline QA, Citation check, Multi-source conflict |
| Office & Business Communication | 12 | Meetings, Email drafting, Contracts |
| Vertical Professional Workflows | 12 | Legal, HR, Medical administration |
| Long-running Autonomy & State Adaptation | 11 | Interruption recovery, Multi-day state, Async injection |
| SRE, DevOps & Release Ops | 7 | Kubernetes, Alerts, Capacity planning |
| **总计** | **106** | |

### 2.2 评估协议设计

**核心设计哲学**: 固定外部任务条件，变化 harness 配置。

**控制与变化因素**：
| 因素 | 处理方式 |
|------|----------|
| Task prompt 和 fixtures | **固定** |
| 初始沙盒状态 | **固定** |
| Budget, timeout, evaluator | **固定** |
| Model backend | **变化**（因子矩阵） |
| Harness configuration | **变化**（因子矩阵） |
| Prompting 和 action format | 保留各 harness **原生**行为 |
| Tool interface 和 state policy | 保留各 harness **原生**行为 |
| Retry 和 recovery behavior | 保留各 harness **原生**行为 |
| Permissions 和 tools | 启用完成任务所需的**最小集合** |

**设计思想解读**：
1. **诊断性而非因果分解**：评估完整的 harness 配置，结果应解释为 model-harness 配对配置级别的诊断
2. **互补而非竞争**：与 SWE-bench、AgentBench 等基准互补
3. **配置级别报告**：代理能力应在 model-harness 配置级别报告

### 2.3 评分体系

**顶层评分公式**：
```
TaskScore_i = Security_i × Completion_i × Process_i
```

**Process 分数的构成**：
```
Process_i = (Robustness_i + ToolUse_i + Consistency_i) / 3
```

| 维度 | 含义 | 评估方式 |
|------|------|----------|
| **Security（安全门控）** | Security ∈ {0, 1}，违反明确权限或安全约束时设为 0 | 二进制门控 |
| **Completion（完成度）** | 任务特定输出质量 | 确定性验证器优先，必要时 LLM 评判 |
| **Robustness（鲁棒性）** | 代理是否妥善处理工具或环境失败 | LLM-based process rubric |
| **ToolUse（工具使用适当性）** | 工具是否被适当选择和应用 | LLM-based process rubric |
| **Consistency（一致性）** | 动作、观察、中间状态和最终输出是否一致 | LLM-based process rubric |

**评分流水线**：
```
① Create workspace → ② Call agent → ③ Execute tasks → ④ Task output
                                      ↓
                    ⑤ Oracle grader → Completion score
                    ⑥ Stitch traces → ⑦ LLM judge → Security score + Process score
                                                      → Tool use, Consistency, Robustness
                    ⑧ Combined score = Security × Completion × Process
```

### 2.4 四源证据收集

每次运行产生四个证据来源：
1. **最终工作区状态**（Final workspace state）
2. **执行轨迹**（Execution trace）
3. **使用统计**（Usage statistics）
4. **验证器输出**（Validator outputs）

---

## 3. 实验设置

### 3.1 实验矩阵

- **规模**: 6 harness × 8 model backend × 106任务 = **5,088轨迹**
- **额外**: Codex 106轨迹（模型绑定编码Agent参考点）
- **总计**: **5,194轨迹**

### 3.2 Model Backends (8个)

| 模型 | 提供商 |
|------|--------|
| anthropic/claude-opus-4.6 | Anthropic Claude |
| anthropic/claude-sonnet-4.6 | Anthropic Claude |
| google/gemini-3.1-pro-preview | Google Gemini |
| qwen/qwen3.6-plus | Qwen |
| z-ai/glm-5.1 | GLM |
| moonshot/kimi-k2.5 | Moonshot Kimi |
| openai/gpt-5.4 | OpenAI GPT |
| deepseek/deepseek-v4-flash | DeepSeek |

### 3.3 评判者

- 统一使用 `claude-sonnet-4.6` 作为固定外部评判者

---

## 4. 主要实验结果

### 4.1 Harness 综合得分（Table 2）

| Harness | Score(%) | Comp.(%) | Secur.(%) | Tool(%) | Cons.(%) | Rob.(%) | Tok.(K) | Turns |
|---------|----------|----------|-----------|---------|----------|---------|----------|-------|
| **NanoBot** | **76.2** | **81.6** | 100.0 | **93.7** | **93.7** | **91.7** | 68.7 | 7.3 |
| Hermes | 71.2 | 80.4 | 100.0 | 88.5 | 88.4 | 85.5 | 139.7 | 22.6 |
| Moltis | 68.8 | 78.4 | 100.0 | 86.3 | 87.3 | 84.1 | 134.9 | 8.0 |
| NullClaw | 64.4 | 75.9 | 100.0 | 85.3 | 81.4 | 78.3 | 175.1 | 12.1 |
| ZeroClaw | 61.4 | 69.9 | 100.0 | 84.1 | 83.2 | 79.0 | 133.2 | 8.6 |
| OpenClaw | 52.4 | 60.0 | 100.0 | 74.0 | 70.9 | 82.1 | — | 5.0 |
| **Codex** (参考) | **80.4** | **86.5** | 100.0 | 92.4 | 93.9 | 91.6 | 86.1 | 5.0 |

**关键发现**：
- NanoBot 最高分 76.2%，OpenClaw 最低 52.4%，**差距 23.8 分**
- NanoBot 以比 Hermes 更少的 Token（68.7K vs 139.7K）实现更高分，说明更长的轨迹本身不决定性能

### 4.2 Harness 依赖性分析

**核心发现**：更强模型后端倾向于实现更高平均分，同时表现出更低的跨 harness 方差。

- **强模型对 harness 差异更容忍**：跨 harness 方差低
- **弱模型对 harness 更敏感**：跨 harness 方差大，性能更容易受周围执行层影响

### 4.3 类别级 Harness 依赖性

| 任务类别 | 跨 Harness 方差 | 敏感度 |
|----------|----------------|--------|
| Data, BI & Finance Analytics | **最高** (0.0155) | 最敏感 |
| Workspace, Tool Use & Multimodal Operations | 高 (0.0130) | 敏感 |
| Software Engineering & Codebase Maintenance | 中高 (0.0102) | 中等敏感 |
| Knowledge, Evidence & Retrieval | 中 (0.0094) | 中等 |
| Long-running Autonomy & State Adaptation | 中 (0.0091) | 中等 |
| Vertical Professional Workflows | 低 (0.0056) | 较低 |
| SRE, DevOps & Release Ops | 低 (0.0049) | 低 |
| Office & Business Communication | **最低** (0.0020) | 最不敏感 |

**关键洞见**：需要结构化数据分析、工具序列化和工作区操作的任务最能暴露不同 harness 配置之间的差异。以语言生成为主的任务对 harness 配置敏感度最低。

---

## 5. 失败模式和执行对齐

### 5.1 五类主要失败模式（Table 3）

| 失败模式 | 出现率 | 典型表现 |
|----------|--------|---------|
| **Contract/Format（合约/格式）** | **36.4%** | JSON 格式错误、缺少分类账行、不完整的清单 |
| **Tool/Recovery（工具/恢复）** | **24.6%** | 工具错误或命令阻塞后无有效恢复或计划修订 |
| **Evidence/Grounding（证据/依据）** | **14.6%** | 来源覆盖不完整，声明缺乏支持或验证缺失 |
| **Artifact Commitment（工件提交）** | **11.1%** | 推理合理但未提交所需输出或工作区工件 |
| **State/Continuation（状态/继续）** | **9.3%** | 未能保留持久进度或在中断/多轮任务中可靠恢复 |

### 5.2 执行对齐（Execution Alignment）

**定义**: harness 在以下方面保持对应关系的程度：
- 代理的推理（reasoning）
- 观察到的工作区状态（observed workspace state）
- 通过工具采取的操作（actions through tools）
- 评估器检查的条件（evaluator conditions）

**失败轨迹中的对应关系崩溃表现**：
- 工具反馈未纳入下一步行动
- 证据未与声明联系
- 部分进度未保存
- 预期结果未提交为有效工件

### 5.3 为什么相同模型不同 Harness 表现不同

根本原因：各 harness 对**操作化表示**的定义不同：
- 什么算待履行义务（pending obligation）
- 什么算观察到的证据（observed evidence）
- 什么算可恢复的工具失败（recoverable tool failure）
- 什么算已完成工作（completed work）

当这些表示薄弱或隐式时，合理的推理会漂移，远离任务评判条件。

---

## 6. 关键设计启示

### 6.1 对 Harness 设计的启示

1. **执行对齐优先于模型能力**：harness 必须保持推理、状态、行动和评估条件之间的对应关系
2. **操作表示必须显式化**：义务、证据、失败、完成都需要明确的表示
3. **合同格式边界是最常见失败点**：36.4% 的失败发生在语义合理性和机器可检查输出之间
4. **恢复机制需要基于观察重新定向**：而非简单重试
5. **状态持久化对多轮任务关键**：9.3% 的失败来自状态/继续问题

### 6.2 对 Agent 能力评估的启示

1. **单一 harness 评估存在严重偏差**：可达 23.8 分的偏差
2. **Model-Harness 存在耦合效应**：不能简单分离
3. **Benchmark 应跨多 harness 测试并报告方差**
4. **强模型提供跨平台一致性**：弱模型对 harness 更敏感
5. **Data/BI 类任务优化 harness 比换模型更有效**

---

## 7. 与现有基准的比较

| 基准 | 评估焦点 | Harness 处理方式 |
|------|----------|-----------------|
| **Harness-Bench** | **Harness 配置级效应** | **主要评估轴** |
| SWE-bench | 完整 Agent 系统 | 抽象掉执行层 |
| AgentBench | 模型后端比较 | 固定执行设置 |
| Claw-Eval | 异构 Agent 堆栈 | 混淆 harness 与系统 |
| MMLU/GSM8K | 静态文本能力 | 无执行层 |
| WebArena/OSWorld | 端到端 Agent 能力 | 完整系统评估 |

---

## 8. 局限性和边界

1. **评估完整 harness 配置**：观察到的差异应解释为配置级效应
2. **沙盒离线工作流**：改进可复现性，但缺少对在线服务、用户反馈、变化外部状态的覆盖
3. **部分过程级分数依赖 LLM 辅助评估**：解释为诊断性测量，而非部署保证
4. **描述性测量而非统计声明**：在固定任务套件上的测量，不推广到所有可能的 Agent 工作流

---

## 9. 代表任务示例

### 任务 1: 文档和电子表格工作流（010-office-docs）
- **输入**: sales.csv, policy.pdf, template.docx
- **目标**: 读取策略文档，应用策略到销售表，排除退货行，按区域聚合收入，生产机器可读摘要和正式 Word 备忘录
- **输出**: summary.json + report.docx
- **验证**: 检查策略遵循、数值聚合、JSON 结构、结构化摘要与生成报告的一致性

### 任务 2: 迭代代码修复（011-code-debug）
- **输入**: 有 bug 的 Python 程序
- **目标**: 检查当前可见失败，最小化编辑修复代码，运行验证，逐层修复
- **输出**: buggy_code_fixed.py + fix_log.md
- **验证**: 结合验证层修复、轮次效率和修复质量

### 任务 3: 数据库迁移安全（043-db-migration-safety）
- **输入**: SQLite 模式、不安全迁移草稿、迁移策略
- **目标**: 修复迁移 SQL，保留用户和依赖订单，添加非空状态列，强制邮件约束，确定性清理脏数据，保持幂等性
- **输出**: 修复后的 migration.sql + preflight_report.md + rollback.sql + postcheck.sql + migration_report.md

---

## 10. 总结

Harness-Bench 提供了可复现的诊断性基础，用于诊断和改进可靠、高效、权限感知和可审计的 Agent 执行堆栈。

**核心洞见**：
- Agent 性能是嵌入在执行系统中的模型的属性，不是基础模型本身的属性
- 即使更强的模型仍然需要可靠的执行底层：权限边界、持久状态、可解释追踪、证据记录和客观验证
- 未来 Agent 基准应同时报告模型和 harness 条件

---

**相关文件**：
- 概念定义论文: `2606.10106v1.pdf`（Harness 概念形式化定义）
- 基准测试论文: `2605.27922v1.pdf`（Harness-Bench 基准）
- [Harness Engineering 概述](./harness-engineering.md)
- [Hook 机制详解](./hook.md)
- [Harness 对比分析](./harness-compare-claude-vs-cygcode/)