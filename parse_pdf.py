import os
import subprocess
import argparse


def parse_pdf(pdf_path, output_dir, backend="vlm-sglang-client", url="http://10.1.208.46:30009"):
    """
    使用 mineru 解析 PDF 文件

    Args:
        pdf_path: PDF 文件路径
        output_dir: 输出目录
        backend: mineru 后端类型，默认 vlm-sglang-client
        url: VLM 服务地址
    """
    # 检查 PDF 文件是否存在
    if not os.path.exists(pdf_path):
        print(f"错误：PDF 文件不存在 - {pdf_path}")
        return

    # 创建输出目录
    os.makedirs(output_dir, exist_ok=True)

    # 构造 mineru 命令
    mineru_cmd = [
        "mineru",
        "-p", pdf_path,
        "-o", output_dir,
        "-b", backend,
        "-u", url
    ]

    print(f"正在解析 PDF: {pdf_path}")
    print(f"输出目录: {output_dir}")
    print(f"命令: {' '.join(mineru_cmd)}")
    print("-" * 50)

    # 执行命令
    result = subprocess.run(
        mineru_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )

    print("mineru stdout:\n", result.stdout)
    print("mineru stderr:\n", result.stderr)
    print("-" * 50)

    if result.returncode == 0:
        print(f"解析完成！结果保存在: {output_dir}")
    else:
        print(f"解析失败，返回码: {result.returncode}")

    return result.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="使用 mineru 解析 PDF 文件")
    parser.add_argument(
        "-p", "--pdf",
        default="DeepSeek_V4.pdf",
        help="PDF 文件路径 (默认: DeepSeek_V4.pdf)"
    )
    parser.add_argument(
        "-o", "--output",
        default="output/mineru_output",
        help="输出目录 (默认: output/mineru_output)"
    )
    parser.add_argument(
        "-b", "--backend",
        default="vlm-sglang-client",
        help="mineru 后端类型 (默认: vlm-sglang-client)"
    )
    parser.add_argument(
        "-u", "--url",
        default="http://10.1.208.46:30009",
        help="VLM 服务地址 (默认: http://10.1.208.46:30009)"
    )

    args = parser.parse_args()

    parse_pdf(
        pdf_path=args.pdf,
        output_dir=args.output,
        backend=args.backend,
        url=args.url
    )