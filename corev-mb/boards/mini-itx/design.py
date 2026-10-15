# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# design.py — SKiDL schematic for the custom board 'mini-itx'.
#
# Only 'custom' boards have this file. Third-party / reference boards set
# "skidl": "omitted" in board.json and have no schematic here.
#
# Run via: g6lc-build mb design mini-itx [--online] [--fix]

import os
import sys

# corev-mb has a hyphen (not importable as a package), so put the flat lib
# dir on sys.path and import its modules directly. `mb design` also exports
# PYTHONPATH to the same dir, so either invocation works.
sys.path.insert(0, os.path.join(os.environ.get("CVA6_REPO_DIR", os.getcwd()), "corev-mb", "lib"))

from soc import build_board  # noqa: E402


def main() -> int:
    """Assemble the board, run ERC, and emit a netlist + BOM."""
    return build_board("mini-itx")


if __name__ == "__main__":
    raise SystemExit(main())
