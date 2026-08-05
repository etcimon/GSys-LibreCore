#!/usr/bin/env python3
"""Brand-forward renames in docs/website/pages/*.mdx (boundary only)."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "docs" / "website" / "pages"


def main() -> None:
    n = 0
    for p in ROOT.rglob("*.mdx"):
        t = p.read_text(encoding="utf-8")
        o = t
        t = t.replace("CVA6V-EC", "GSys LibreCore")
        t = t.replace("`cva6-build", "`g6lc-build")
        t = t.replace("cva6-build ", "g6lc-build ")
        t = t.replace("cva6-build`", "g6lc-build`")
        t = t.replace("cva6-build\n", "g6lc-build\n")
        if t != o:
            p.write_text(t, encoding="utf-8")
            n += 1
            print(f"updated {p.relative_to(ROOT)}")
    print(f"files {n}")


if __name__ == "__main__":
    main()
