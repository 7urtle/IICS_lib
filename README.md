# IICS 论文库

GitHub 仓库：<https://github.com/7urtle/IICS_lib>

在本目录运行：

```powershell
python generate_manifest.py
```

脚本递归扫描自身所在目录下的所有 PDF，根据 `分类/会议或期刊/年份/PDF文件名` 的目录结构生成 `manifest.json`。添加、删除或移动 PDF 后，再运行即可更新清单。

清单是 JSON 数组，每项包含分类、会议/期刊名、年份和 PDF 文件名。年份保留文件夹中的字符串：

```json
[
  {
    "category": "存内计算",
    "venue": "ISSCC",
    "year": "2026",
    "pdf_name": "paper.pdf"
  }
]
```
