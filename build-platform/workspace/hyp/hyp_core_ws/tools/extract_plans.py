# SPDX-License-Identifier: MIT
# Copyright 2026 Etienne Cimon
"""Extract `// svt-plan: begin <module>` … `// svt-plan: end` blocks from the
upstream core sources into <prov>/plans/<module>.md (verbatim block + file
path/line range). Output goes to the provenance workspace, which may carry
upstream names — not into this tree.
"""
import os
import re
import sys
from pathlib import Path

SRC_ROOT = Path(os.environ.get("HYP8_SRC_ROOT")
                or Path(__file__).resolve().parents[5])
CORE = SRC_ROOT / "core"
PROV = SRC_ROOT / "build-platform" / "workspace" / "build" / "sv-timing" \
    / "hyp8-src"
OUT = PROV / "plans"

BEGIN = re.compile(r"//\s*svt-plan:\s*begin\s+(\S+)")
END = re.compile(r"//\s*svt-plan:\s*end\b")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    found = []
    for sv in sorted(CORE.rglob("*.sv")):
        try:
            lines = sv.read_text(
                encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        i = 0
        while i < len(lines):
            m = BEGIN.search(lines[i])
            if not m:
                i += 1
                continue
            module = m.group(1)
            start = i
            j = i + 1
            while j < len(lines) and not END.search(lines[j]):
                j += 1
            end = j
            block = "\n".join(lines[start:end + 1])
            rel = str(sv).replace("\\", "/")
            md = (
                f"# svt-plan: {module}\n\n"
                f"- source: `{rel}` lines {start + 1}-{end + 1}\n\n"
                f"```systemverilog\n{block}\n```\n"
            )
            (OUT / f"{module}.md").write_text(md, encoding="utf-8")
            found.append((module, rel, start + 1, end + 1))
            i = end + 1
    print(f"extracted {len(found)} svt-plan blocks -> {OUT}")
    for mod, rel, a, b in found:
        print(f"  {mod:40s} {rel}:{a}-{b}")
    return 0


if __name__ == "__main__":
    sys.exit(main())


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
