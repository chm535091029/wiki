# DPO (Direct Preference Optimization)

**核心思想**：直接在语言模型上建模偏好损失函数，绕过reward model训练阶段，简化了训练流程。

## 算法原理

DPO将reward model的学习过程内化到LLM本身，直接优化语言模型：

```
L_{DPO} = -log σ(β * (log π(y_w|x) - log π(y_l|x)))
```

其中 `y_w` 是偏好的response，`y_l` 是不偏好的response。

## 代码生成下的数据要求

| 要求 | 说明 |
|------|------|
| 偏好对数据 | 需要成对的chosen vs rejected数据 |
| 区分度 | 偏好数据之间的区分度要足够明显 |
| 质量优先 | 数据量通常比PPO少，但质量要求更高 |

## 特点

- **训练范式**：偏好学习（无reward model）
- **数据需求**：偏好对数据
- **训练复杂度**：中（端到端）
- **适用场景**：简单偏好对齐
