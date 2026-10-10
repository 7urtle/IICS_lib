import json
from pathlib import Path


root = Path(__file__).resolve().parent
papers = []

for pdf in sorted(root.rglob("*")):
    if not pdf.is_file() or pdf.suffix.lower() != ".pdf":
        continue

    # 目录结构：分类/会议或期刊/年份/PDF文件
    folders = pdf.relative_to(root).parts[:-1]
    papers.append({
        "category": folders[0] if folders else None,
        "venue": folders[1] if len(folders) > 1 else None,
        "year": folders[2] if len(folders) > 2 else None,
        "pdf_name": pdf.name,
    })

(root / "manifest.json").write_text(
    json.dumps(papers, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(f"已生成 manifest.json，共 {len(papers)} 个 PDF。")
