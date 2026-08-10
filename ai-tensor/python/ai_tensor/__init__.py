# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
ai-tensor — high-level host API for Xg6lcai / ai_island (sim first).

PyTorch helpers live in ``ai_tensor.torch_ops`` (optional import if torch installed).
"""

from __future__ import annotations

__version__ = "0.1.0"

from .device import Caps, Device, Pmu, gemm_s8, pack_gemm_desc, tile_gemm
from .golden import GoldenGemm, builtin_goldens, run_golden_suite
from .policy import WaitPolicy, recommend_policy
from .profile import Profile

__all__ = [
    "Caps",
    "Device",
    "GoldenGemm",
    "Pmu",
    "Profile",
    "WaitPolicy",
    "builtin_goldens",
    "gemm_s8",
    "pack_gemm_desc",
    "recommend_policy",
    "run_golden_suite",
    "tile_gemm",
    "__version__",
]
