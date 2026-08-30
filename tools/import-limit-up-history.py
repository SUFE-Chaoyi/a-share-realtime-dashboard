#!/usr/bin/env python3
"""已停用：历史涨停数据只能由东方财富自动回补流程获取。"""
import sys

if __name__ == "__main__":
    print("已停用：不支持 CSV/Excel/外部文件导入；请运行 tools/auto-backfill-limit-up.py。", file=sys.stderr)
    raise SystemExit(2)
