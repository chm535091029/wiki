# TorchServe 部署

torchserve是PyTorch官方提供的模型Serving框架，适合生产环境批量推理。

## 主要特性

| 特性 | 说明 |
|------|------|
| 多线程部署 | 支持多worker并发处理 |
| 批量推理 | 高效的批量请求处理 |
| 版本管理 | 内置模型版本管理 |

## 版本建议

⚠️ **重要**：建议使用 **0.7.1** 版本，避免token认证问题。

## 部署命令

```bash
# TorchServe 基本部署
torchserve --model-name llm-model --model-file model.py --handler handler.py
```

## 适用场景

- 生产环境批量推理
- 多实例部署
- 需要稳定SLA的服务
