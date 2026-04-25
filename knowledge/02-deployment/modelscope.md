# ModelScope 部署

直接使用模型名称和魔搭平台API Key进行调用，无需本地部署模型。

## 优势

| 优势 | 说明 |
|------|------|
| 零部署 | 无需本地部署模型 |
| 快速调用 | 通过SDK直接调用 |
| 模型丰富 | 海量开源模型 |

## 调用方式

```python
# ModelScope SDK 调用示例
from modelscope import snapshot_download
model_dir = snapshot_download('qwen/Qwen-7B')

# API调用示例
from modelscope import Qwen
model = Qwen(api_key='your_api_key')
response = model.generate('Hello')
```

## 使用流程

1. 获取ModelScope API Key
2. 选择目标模型
3. 通过SDK调用或API接口

## 适用场景

- 快速验证和原型开发
- 无需本地GPU资源的场景
- 追求简单部署流程
