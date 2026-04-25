# FastAPI + Nginx 负载均衡

FastAPI提供高效的HTTP服务接口，Nginx实现多实例负载均衡。

## 架构图

```
[Client] → [Nginx] → [FastAPI Instance 1]
                   → [FastAPI Instance 2]
                   → [FastAPI Instance N]
```

## 配置更新流程

1. **修改服务器配置**：更新服务参数
2. **同步Nginx配置**：更新upstream配置
3. **重载Nginx**：`sudo service nginx reload`

## Nginx配置示例

```nginx
upstream llm_backend {
    server 127.0.0.1:8001;
    server 127.0.0.1:8002;
    server 127.0.0.1:8003;
}

server {
    listen 80;
    server_name api.example.com;
    
    location / {
        proxy_pass http://llm_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## 常用命令

| 命令 | 说明 |
|------|------|
| `sudo service nginx reload` | 重载配置（不断连） |
| `sudo service nginx restart` | 重启服务 |
| `nginx -t` | 测试配置语法 |

## 优势

- ✅ **高可用**：多实例冗余
- ✅ **负载均衡**：分担请求压力
- ✅ **热更新**：重载配置不断连
