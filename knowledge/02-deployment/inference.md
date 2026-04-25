# ONNX 推理优化

ONNX (Open Neural Network Exchange) 提供跨框架的模型推理能力。

## 性能对比

| 环境 | 性能表现 |
|------|----------|
| **CPU推理** | 相比PyTorch原生推理速度更快 |
| **GPU推理** | 内部算子来回搬数据，可能比PyTorch更慢 |

## 使用注意

⚠️ **重要**：需要将输入转换为ONNX模型期望的形状。

## 输入预处理示例

```python
# ONNX 推理输入预处理示例
import numpy as np

# 确保输入张量形状与模型期望一致
input_tensor = preprocess(raw_input)
onnx_input = np.array(input_tensor).astype(np.float32)

# 执行推理
output = onnx_session.run(None, {'input': onnx_input})
```

## 优化策略

| 策略 | 说明 |
|------|------|
| 算子融合 | 减少核函数切换 |
| 形状适配 | 预处理输入匹配模型期望 |
| 内存优化 | 复用输入输出buffer |

## 适用场景

- CPU推理优化
- 跨平台部署
- 量化推理
