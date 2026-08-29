#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# platform_constants.py — loader for the platform-constants.toml guiding file.
# g6q.py imports this so external download URLs live in platform-constants.toml,
# not scattered through the CLI code.

from __future__ import annotations

import platform
import sys
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

import tomlmini
from env_common import package_root


_PATH = package_root() / "platform-constants.toml"


def _load() -> dict:
    if not _PATH.is_file():
        raise FileNotFoundError(f"platform-constants.toml not found at {_PATH}")
    return tomlmini.load(_PATH)


def _key(name: str) -> str:
    return name.replace("-", "_")


def _platform_key() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if system == "windows":
        return "win_x64"
    if system == "linux":
        return "linux_x64" if machine in ("x86_64", "amd64") else "linux_" + machine
    if system == "darwin":
        if machine in ("arm64", "aarch64"):
            return "darwin_arm64"
        return "darwin_x64"
    return f"{system}_{machine}"


_PLATFORM = _load()


def platform_constants() -> dict:
    return _PLATFORM


def rustup_url() -> str:
    return _PLATFORM["rustup"]["win_url" if platform.system() == "Windows" else "unix_url"]


def xpack_riscv() -> dict:
    return _PLATFORM["xpack_riscv"]


def host_tool(tool: str) -> dict:
    return _PLATFORM["host_tools"][_key(tool)]


def host_tool_cmd(tool: str) -> str:
    return host_tool(tool)["cmd"]


def host_tool_fallback(tool: str, *, kind: str | None = None) -> dict | None:
    """Return the standalone or build-from-source entry for this host, if it exists.

    `kind` can be "standalone" or "build_from_source" to narrow the search; by default
    standalone is preferred, then build_from_source.
    """
    spec = host_tool(tool)
    plat = _platform_key()
    if kind in (None, "standalone") and "standalone" in spec:
        entry = spec["standalone"].get(plat)
        if entry:
            return dict(entry)
    if kind in (None, "build_from_source") and "build_from_source" in spec:
        entry = spec["build_from_source"].get(plat)
        if entry:
            return dict(entry)
    if kind:
        return None
    return None


def host_tool_build_hint(tool: str) -> str | None:
    return host_tool(tool).get("build_hint")
