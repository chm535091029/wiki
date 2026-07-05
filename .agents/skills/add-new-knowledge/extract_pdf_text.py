"""
从 PDF 文件中提取纯文本内容并保存为可读的文本文件

用法:
    python extract_pdf_text.py <pdf_path> [output_path]

参数:
    pdf_path:   PDF 文件路径（必填）
    output_path: 输出文本文件路径（可选，默认为 output/extracted_text.txt）
"""

import fitz
import sys
import os


def extract_pdf_text(pdf_path: str, output_path: str = "output/extracted_text.txt") -> int:
    """
    使用 PyMuPDF 提取 PDF 文本内容

    Args:
        pdf_path: PDF 文件路径
        output_path: 输出文本文件路径

    Returns:
        PDF 总页数
    """
    # 检查 PDF 文件是否存在
    if not os.path.exists(pdf_path):
        print(f"错误：PDF 文件不存在 - {pdf_path}")
        return 0

    # 确保输出目录存在
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    # 打开 PDF
    doc = fitz.open(pdf_path)
    total_pages = len(doc)
    print(f"PDF 总页数: {total_pages}")

    # 逐页提取文本
    with open(output_path, "w", encoding="utf-8") as f:
        for i, page in enumerate(doc):
            text = page.get_text()
            f.write(f"=== PAGE {i+1} ===\n")
            f.write(text)
            f.write("\n\n")

    doc.close()
    print(f"提取完成！文本已保存到: {output_path}")
    return total_pages


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("用法: python extract_pdf_text.py <pdf_path> [output_path]")
        print("示例: python extract_pdf_text.py paper.pdf output/paper.txt")
        sys.exit(1)

    pdf_path = sys.argv[1]
    output_path = sys.argv[2] if len(sys.argv) > 2 else "output/extracted_text.txt"

    extract_pdf_text(pdf_path, output_path)