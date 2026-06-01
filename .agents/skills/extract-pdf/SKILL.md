---
name: extract-pdf
description: 使用 PyMuPDF (fitz) 从 PDF 文件中提取文本内容并保存为可读的纯文本文件，适用于论文、文档等 PDF 的内容分析
---

# extract-pdf

用于从 PDF 文件中提取纯文本内容。当用户需要你阅读或分析 PDF 文件内容时，使用此 skill 提取文本后再进行后续处理。

## 适用场景

- 用户提供 PDF 文件路径，要求你阅读或总结其中的内容
- 需要分析论文、技术文档、报告等 PDF 格式的资料
- PDF 文件包含大量文本，需要提取后进行分析

## 前提条件

- Python 环境可用（推荐使用 conda 环境中的 Python）
- 已安装 `PyMuPDF` 库（`pip install PyMuPDF`）
- 提取的内容可能不包含公式、图表等非文本元素

## 步骤

1. **确认 Python 环境**：找到可用的 Python 解释器路径（如 `D:\anaconda\python.exe`）

2. **调用脚本提取文本**：使用本目录下的 `extract_pdf_text.py` 脚本
   ```bash
   <python_path> <script_path>/extract_pdf_text.py <pdf_file_path> [output_path]
   ```
   - `pdf_file_path`: PDF 文件路径（必填）
   - `output_path`: 输出文本文件路径（可选，默认 `output/extracted_text.txt`）

   示例：
   ```bash
   D:\anaconda\python.exe .agents/skills/extract-pdf/extract_pdf_text.py SkillOS.pdf output/skillos.txt
   ```

3. **检查输出**：确认提取成功，查看总页数信息

4. **读取分析**：使用 `read_file` 读取提取的文本文件进行后续分析

5. **清理**：分析完成后清理临时提取文件

## 注意事项

- PDF 中的图片、图表、公式等不会被提取为文本
- 对于扫描版 PDF（图片形式的 PDF），PyMuPDF 无法直接提取文本，需要使用 OCR 工具（如 mineru）
- 输出文件采用 UTF-8 编码，确保支持中文字符和特殊 Unicode 字符
- 脚本会自动创建输出目录（如果不存在）
- 提取完成后记得清理临时文件