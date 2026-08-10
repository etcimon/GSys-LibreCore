# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
ai-tensor — high-level host API for Xg6lcai / ai_island (sim first).

PyTorch helpers live in ``ai_tensor.torch_ops`` (optional import if torch installed).
"""

from __future__ import annotations

__version__ = "0.1.0"

from .device import Device, gemm_s8, pack_gemm_desc

__all__ = ["Device", "gemm_s8", "pack_gemm_desc", "__version__"]
