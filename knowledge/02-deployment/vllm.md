# vLLM 部署方案

vLLM支持本地部署模型和工具调用功能。

## 基本部署

```bash
# vLLM 基本部署
vllm serve <model_name>
```

## 工具调用部署

vLLM支持通过命令行参数启用工具调用功能：

```bash
# vLLM 工具调用部署命令
vllm serve <model_name> \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder
```

## 主要特性

| 特性 | 说明 |
|------|------|
| 高吞吐量 | PagedAttention优化显存管理 |
| 工具调用 | 支持Function Calling |
| 多模型 | 支持多种开源模型 |

## 应用场景

- **本地部署**：无需API调用，直接本地运行
- **工具增强**：为模型添加工具调用能力
- **定制化**：灵活的推理配置
