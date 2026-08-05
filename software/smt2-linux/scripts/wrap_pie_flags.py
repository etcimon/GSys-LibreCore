#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
from pathlib import Path
import sys


def main(path: Path) -> None:
    t = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    pie = "$(OPENSBI_LD_PIE)"
    reps = [
        (
            "CFLAGS\t\t+=\t-fPIE -pie\n",
            f"ifeq ({pie},y)\nCFLAGS\t\t+=\t-fPIE -pie\nendif\n",
        ),
        (
            "ASFLAGS\t\t+=\t-fPIE\n",
            f"ifeq ({pie},y)\nASFLAGS\t\t+=\t-fPIE\nendif\n",
        ),
        (
            "ELFFLAGS\t+=\t-Wl,--no-dynamic-linker -Wl,-pie\n",
            f"ifeq ({pie},y)\nELFFLAGS\t+=\t-Wl,--no-dynamic-linker -Wl,-pie\nendif\n",
        ),
        (
            "CFLAGS+=-fPIE -pie\n",
            f"ifeq ({pie},y)\nCFLAGS+=-fPIE -pie\nendif\n",
        ),
        (
            "ASFLAGS+=-fPIE\n",
            f"ifeq ({pie},y)\nASFLAGS+=-fPIE\nendif\n",
        ),
        (
            "ELFFLAGS+=-Wl,--no-dynamic-linker -Wl,-pie\n",
            f"ifeq ({pie},y)\nELFFLAGS+=-Wl,--no-dynamic-linker -Wl,-pie\nendif\n",
        ),
    ]
    for a, b in reps:
        if b in t:
            print("already wrapped", a.strip())
            continue
        if a not in t:
            continue
        t = t.replace(a, b, 1)
        print("wrapped", a.strip())
    path.write_text(t, encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
