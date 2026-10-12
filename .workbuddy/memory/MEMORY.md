# 项目长期记忆

## 知识库组织约定

- 目录结构：`knowledge/` 下按 `01-training`、`02-deployment`、`03-research`、`04-engineering` 分类，文件名用 kebab-case 英文，不带 YAML frontmatter（旧文件有 frontmatter 的除外）。
- `03-research/` 按主题建子目录，一个主题一个文件。
- Obsidian 库，笔记间用相对 Markdown 链接互引。

## 后端知识（04-engineering）

- **正式版本为 `04-engineering/backend-basics/`**，共 7 个文件：`00-overview.md` 加六个板块（数据与存储、并发与请求模型、服务与接口、状态与缓存、可靠性可观测、交付与运行）。
- 定位：面向 vibe coding 的"能看懂、能审查、能提约束"，不追求独立手写生产服务。案例统一锚定 New API 网关。
- 每篇统一五段结构：概念要点 → New API 中的落点 → 典型误写与修正 → 审查红灯信号 → 判断阈值。
- **旧的 `04-engineering/backend-fundamentals/`（10 篇 + README）已弃用**，用户明确决定不恢复、不迁移。该系列仍存在于 Git HEAD 中，但已从工作区删除。若后续在 Git 操作中意外恢复出来，应删除而不是并入。
- 旧的 `04-engineering/ai-agent-engineering-knowledge-map.md`（大纲）同样处于已弃用状态。

## 引用 New API 的注意事项

- 本机没有 New API 源码。笔记中的案例引用基于上游 `Calcium-Ion/new-api` 的公开架构（Go + Gin + GORM，Router→Controller→Service→Model 四层）。
- 凡涉及具体文件路径与环境变量的引用，均需标注"本地 fork 可能已有改动，路径以实际源码为准"。不得凭印象编造 fork 内的实现细节。
