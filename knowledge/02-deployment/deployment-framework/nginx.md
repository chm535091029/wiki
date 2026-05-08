# 模型服务负载均衡

本章节介绍大模型多实例部署后的负载均衡配置、使用方法和常用技巧。

## 目录

1. [架构概述](#架构概述)
2. [Nginx 配置详解](#nginx-配置详解)
3. [启停命令](#启停命令)
4. [运维技巧](#运维技巧)
5. [常见问题](#常见问题)

---

## 架构概述

```
┌─────────────────────────────────────────────────────────────┐
│                         Client                              │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                     Nginx / HAProxy                         │
│                   (负载均衡器:5678)                          │
└─────────────────────────┬───────────────────────────────────┘
                          │
         ┌────────────────┼────────────────┐
         ▼                ▼                ▼
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  vLLM 实例1  │   │  vLLM 实例2  │   │  vLLM 实例3  │
│  (Port:5679) │   │  (Port:5680) │   │  (Port:5681) │
└─────────────┘   └─────────────┘   └─────────────┘
```

### 适用场景

- ✅ 多 GPU 分布式推理
- ✅ 高并发 API 服务
- ✅ 流式输出 (Streaming) 服务
- ✅ 需要会话粘性的应用

---

## Nginx 配置详解

### 基础配置 (vLLM 示例)

```nginx
upstream vllm_backend {
    # 默认使用轮询（Round Robin），请求会平均分配给各个节点
    server 127.0.0.1:5679;
    server 127.0.0.1:5680;
    server 127.0.0.1:5681;

    # 如果希望连接更稳定，可以使用 ip_hash 让同一个用户的请求落到同一个节点上
    # ip_hash;

    # 也可以设置连接限制，确保单个后端不至于过载
    # server 127.0.0.1:5679 max_fails=3 fail_timeout=30s;
}

server {
    listen 5678; # 负载均衡后的统一对外端口
    server_name localhost;

    # 针对大模型推理，建议调高超时时间
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;

    location / {
        proxy_pass http://vllm_backend;

        # 必须配置，否则流式输出（Streaming）会因为缓存而卡住
        proxy_buffering off;
        proxy_cache off;

        # 传递标准请求头
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 支持 SSE (Server-Sent Events) 流式返回
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
```

### 负载均衡策略

#### 1. 轮询 (Round Robin) - 默认

```nginx
upstream backend {
    server 127.0.0.1:5679;
    server 127.0.0.1:5680;
    server 127.0.0.1:5681;
}
```

#### 2. 加权轮询 (Weighted Round Robin)

```nginx
upstream backend {
    server 127.0.0.1:5679 weight=3;  # 3倍权重
    server 127.0.0.1:5680 weight=2;  # 2倍权重
    server 127.0.0.1:5681 weight=1;  # 默认1倍
}
```

#### 3. IP Hash (会话粘性)

```nginx
upstream backend {
    ip_hash;
    server 127.0.0.1:5679;
    server 127.0.0.1:5680;
    server 127.0.0.1:5681;
}
```

#### 4. 最小连接数 (Least Connections)

```nginx
upstream backend {
    least_conn;
    server 127.0.0.1:5679;
    server 127.0.0.1:5680;
    server 127.0.0.1:5681;
}
```

### 健康检查配置

```nginx
upstream backend {
    server 127.0.0.1:5679 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:5680 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:5681 backup;  # 备份服务器
}
```

| 参数 | 说明 |
|------|------|
| `max_fails` | 最大失败次数，超过后认为节点不可用 |
| `fail_timeout` | 失败后重新尝试的时间窗口 |
| `backup` | 标记为备份服务器，仅在其他服务器都不可用时启用 |

---

## 启停命令

### Nginx 命令

| 命令 | 说明 | 场景 |
|------|------|------|
| `sudo nginx -t` | 测试配置文件语法 | 修改配置前必做 |
| `sudo service nginx reload` | 重载配置（不断连） | 常规更新配置 |
| `sudo service nginx restart` | 重启服务 | 配置严重错误后 |
| `sudo service nginx stop` | 停止服务 | 维护期间 |
| `sudo service nginx start` | 启动服务 | 维护完成后 |
| `sudo nginx -s reload` | 信号重载 | 替代 service 方式 |
| `sudo nginx -s stop` | 信号停止 | 替代 service 方式 |

### 服务启停示例

```bash
# 1. 测试配置语法
sudo nginx -t

# 2. 备份当前配置（重要！）
sudo cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
sudo cp /etc/nginx/conf.d/vllm.conf /etc/nginx/conf.d/vllm.conf.bak

# 3. 修改配置后重载
sudo nginx -s reload

# 4. 如有问题，回滚
sudo cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
sudo nginx -s reload
```

### vLLM 服务启停

```bash
# 启动多个 vLLM 实例
nohup python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-7B-Instruct \
    --port 5679 \
    --gpu-memory-utilization 0.9 \
    > vllm_5679.log 2>&1 &

nohup python -m vllm.entrypoints.openai.api_server \
    --model Qwen/Qwen2.5-7B-Instruct \
    --port 5680 \
    --gpu-memory-utilization 0.9 \
    > vllm_5680.log 2>&1 &

# 查看运行中的 vLLM 进程
ps aux | grep vllm | grep -v grep

# 优雅停止（推荐）
kill -SIGTERM $(ps aux | grep vllm.entrypoints | grep 5679 | awk '{print $2}')

# 强制停止（慎用）
kill -9 $(ps aux | grep vllm.entrypoints | grep 5679 | awk '{print $2}')
```

---

## 运维技巧

### 1. 配置文件备份技巧

```bash
# 方式1: 加 .bak 后缀
mv nginx.conf nginx.conf.bak

# 方式2: 加日期
mv nginx.conf nginx.conf.20240101.bak

# 方式3: 版本控制
cp nginx.conf nginx.conf.v1.0
```

### 2. 灰度发布

```nginx
upstream backend_v1 {
    server 127.0.0.1:5679;  # 旧版本
}

upstream backend_v2 {
    server 127.0.0.1:5680;  # 新版本
}

server {
    listen 5678;
    
    # 根据 Header 区分版本
    location / {
        if ($http_x_version = "v2") {
            proxy_pass http://backend_v2;
            break;
        }
        proxy_pass http://backend_v1;
    }
}
```

### 3. 动态调整权重

```nginx
upstream backend {
    server 127.0.0.1:5679 weight=5;
    server 127.0.0.1:5680 weight=3;
    # 动态增减节点不需要重载 nginx
}
```

### 4. 流式输出优化

```nginx
# 确保流式输出正常的关键配置
proxy_buffering off;       # 关闭代理缓冲
proxy_cache off;           # 关闭代理缓存
proxy_http_version 1.1;    # 使用 HTTP/1.1
chunked_transfer_encoding on;  # 允许分块传输
```

### 5. 日志查看

```bash
# 查看 Nginx 访问日志
tail -f /var/log/nginx/access.log

# 查看 Nginx 错误日志
tail -f /var/log/nginx/error.log

# 查看 vLLM 实例日志
tail -f vllm_5679.log
```

---

## 常见问题

### Q1: 流式输出卡住怎么办？

**检查项：**
1. 确认 `proxy_buffering off;` 已配置
2. 确认 `proxy_cache off;` 已配置
3. 检查超时时间是否足够长

### Q2: 会话不一致怎么办？

**解决方案：** 使用 `ip_hash` 策略
```nginx
upstream backend {
    ip_hash;
    server 127.0.0.1:5679;
    server 127.0.0.1:5680;
}
```

### Q3: 单个节点过载怎么办？

**解决方案：** 配置最大连接数和失败限制
```nginx
server 127.0.0.1:5679 max_fails=3 fail_timeout=30s;
```

### Q4: 如何回滚配置？

```bash
# 1. 停止 nginx
sudo nginx -s stop

# 2. 恢复备份
sudo cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf

# 3. 重新启动
sudo nginx
```

### Q5: 配置文件修改后不生效？

```bash
# 1. 先测试语法
sudo nginx -t

# 2. 查看详细错误
sudo nginx -T

# 3. 确保重载成功
sudo nginx -s reload
```

---

## 最佳实践

1. **修改配置前必做备份**
   ```bash
   cp nginx.conf nginx.conf.bak
   ```

2. **修改后必做语法测试**
   ```bash
   sudo nginx -t
   ```

3. **优先使用 reload 而非 restart**
   - reload 不断连，用户无感知
   - restart 会断开所有连接

4. **设置合理的超时时间**
   - 大模型推理耗时长，建议 600s 以上

5. **开启流式输出必要配置**
   - `proxy_buffering off`
   - `proxy_cache off`
