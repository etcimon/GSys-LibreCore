# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
"""Resolve the Yosys binary built from the tools/yosys submodule.

Order matches the Verilator fork: an explicit YOSYS, then the g6lc prefix
from install-yosys-g6lc.sh, then the formal toolchain, then PATH.
"""

from __future__ import annotations

import os
import shutil

G6LC = "/opt/testharness/toolchains/yosys-g6lc/bin/yosys"
FORMAL = "/opt/testharness/toolchains/formal/bin/yosys"


def yosys_bin() -> str:
    env = os.environ.get("YOSYS")
    if env:
        return env
    for candidate in (G6LC, FORMAL):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return shutil.which("yosys") or "yosys"


def remote_yosys(root: str) -> str:
    """Path of the g6lc Yosys on a testharness machine.

    Callers that invoke a shell script fall back to toolchains/formal when
    this file is absent. Callers that exec the path directly should use
    remote_yosys_shell() so the remote host chooses.
    """
    return f"{root}/toolchains/yosys-g6lc/bin/yosys"
