# Obsidian 风格文档约定（参考范本）

本次在 DeepSeek 系列文档（`knowledge/03-research/Foundation/`）中观察到的约定，作为本技能处理双链式知识库时的参考：

## Frontmatter

- 必含 `aliases`（别名数组）、`tags`（标签数组）、`related`（双链数组）；完整格式与字段说明见 `document-template.md` 的「Frontmatter 标准格式」一节。
- `related` 的两种写法都正确，按仓库习惯二选一：
  - **路径式**（harness-engineering 等知识库采用）：`- "./harness-definition.md"`
  - **Wiki 式**：`- "[[harness-definition]]"`
- `tags` 统一小写、用连字符代替空格（如 `Minimal-Core` 而非 `Minimal Core`）。

## 章节

- 用 `##` 作为一级章节，`###` 作为子节。
- 章节之间可用 `---` 分隔（视仓库习惯）。

## 互链

- 文档正文与 frontmatter 均可使用 `[[doc-id]]` 双链。
- 新增文档后，应在其 `related` 列出关联文档，并同步在关联文档的 `related` 补回向链接，保持图谱一致。

## 图表

- **默认用 Mermaid**（`mermaid` 代码块）：架构图、流程图、数据流图都走 Mermaid，Obsidian 原生渲染、比内联 SVG 更稳，改图成本也低。示例与避坑见 `document-template.md`。
- **ASCII 只作例外**：图极简（2–3 节点单链路）或必须逐字符对齐（字节布局、命令输出、目录树）时再用。

## 来源标注

- 文档开头以引用块（`>`）记录论文/仓库/解读链接，保证可溯源。

> **重要**：以上为参考范本，非强制规范。实际使用本技能时，务必先探测当前仓库的真实约定并复用之，不要机械套用本文件。不同的知识库可能使用不同的 frontmatter 字段、分隔符或互链语法。
