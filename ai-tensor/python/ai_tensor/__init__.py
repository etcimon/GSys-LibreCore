# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
ai-tensor — high-level host API for Xg6lcai / ai_island (sim first).

PyTorch helpers live in ``ai_tensor.torch_ops`` (optional import if torch installed).
"""

from __future__ import annotations

__version__ = "0.1.0"

from .c_abi import PLIC_SOURCE_ISLAND_P3, completion_make, pack_desc64, verify_header_present
from .device import Caps, Device, Pmu, gemm_s8, pack_gemm_desc, tile_gemm
from .golden import GoldenGemm, builtin_goldens, run_golden_suite
from .host import HostJobResult, HostRuntime
from .policy import WaitPolicy, recommend_policy
from .probe import probe_dict
from .profile import Profile

__all__ = [
    "Caps",
    "Device",
    "GoldenGemm",
    "HostJobResult",
    "HostRuntime",
    "PLIC_SOURCE_ISLAND_P3",
    "Pmu",
    "Profile",
    "WaitPolicy",
    "builtin_goldens",
    "completion_make",
    "gemm_s8",
    "pack_desc64",
    "pack_gemm_desc",
    "probe_dict",
    "recommend_policy",
    "run_golden_suite",
    "tile_gemm",
    "verify_header_present",
    "__version__",
]
