# SGLANG模型部署框架

SGLANG是高性能的大模型推理框架，支持高效的批量推理和服务化部署。

## 部署用法

```bash
# 基本部署命令
SGLANG_USE_MODELSCOPE=true python -m sglang.launch_server \
    --model-path <model_name> \
    --port 30000
```

## 高可用配置

结合supervisor实现进程自动重启：

```ini
# supervisor配置示例
[program:sglang]
command=python -m sglang.launch_server ...
autostart=true
autorestart=true
```

## 常见问题及解决方案

| 问题类型 | 表现 | 解决方案 |
|----------|------|----------|
| **依赖错误** | 运行时找不到模块 | 检查Python版本和依赖包版本 |
| **编译错误** | CUDA相关编译失败 | 重新编译或使用预编译镜像 |
| **2卡卡住** | 多卡推理无响应 | 检查NCCL配置和通信超时 |

## 性能特点

- ⚡ 高效批量推理
- 🔄 自动批处理调度
- 🌐 HTTP服务接口
