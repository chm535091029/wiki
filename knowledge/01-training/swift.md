# SWIFT：ModelScope开源训练框架

SWIFT是ModelScope团队开源的大模型训练框架，集成多种训练范式。

## 主要特性

- ✅ **多训练范式**：支持SFT、RL、DPO等多种训练方式
- ✅ **分布式训练**：内置分布式训练能力
- ✅ **数据流水线**：内置数据处理流水线
- ✅ **多模型支持**：Qwen、Llama、ChatGLM等主流开源模型

## 基本用法

```bash
# SWIFT 基本用法示例
SGLANG_USE_MODELSCOPE=true python -m sglang.launch_server ...
```

## 训练模式

| 模式 | 说明 |
|------|------|
| SFT | 有监督微调，直接在标注数据上训练 |
| RL | 强化学习，结合reward进行策略优化 |
| DPO | 直接偏好优化，基于偏好对训练 |

## 支持的模型

```python
# 模型列表
- Qwen系列
- Llama系列
- ChatGLM系列
- 其他主流开源模型
```
