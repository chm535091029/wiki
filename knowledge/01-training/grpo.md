# GRPO (Group Relative Policy Optimization)

**核心思想**：DeepSeek提出的新型强化学习框架，通过组内相对排序的方式进行策略优化。

## 算法原理

GRPO在同个prompt下生成多个候选response，通过组内相对比较来确定优势：

```python
# 伪代码
for prompt in batch:
    responses = model.generate(prompt, n=G)  # 组大小G
    rewards = [reward_fn(prompt, r) for r in responses]
    # 组内相对排序
    advantages = relative_ranking(rewards)
    policy_update(advantages)
```

## 代码生成下的数据要求

| 要求 | 说明 |
|------|------|
| 组样本 | 需要同个prompt下的多个候选response |
| 多样性 | 候选response之间要有合理的多样性 |
| 区分信号 | 奖励信号需要能区分出质量差异 |

## 特点

- **训练范式**：组内相对排序
- **数据需求**：组样本数据
- **训练复杂度**：中（简化版PPO）
- **适用场景**：代码/推理任务对齐
