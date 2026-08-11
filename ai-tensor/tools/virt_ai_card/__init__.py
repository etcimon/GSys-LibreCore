# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
virt_ai_card — hostless virtual PCIe AI card for LibreCore CI.

Userspace soft UIO / eventfd stand-in (no kernel, no real PCIe). Models the
island MMIO map, DONE claim order, and a localhost TCP host↔card path that
stands in for virtio-net/SSH + BAR4 bulk push.

See:
  architecture/ai-matrix/board-uio-eventfd.md
  architecture/uncore/pcie-endpoint.md
  corev-mb/boards/virt-ai-pcie/board.json
"""

from .driver import VirtualEventFd, VirtualUioDevice
from .transport import VirtualPcieLink

__all__ = [
    "VirtualUioDevice",
    "VirtualEventFd",
    "VirtualPcieLink",
]

__version__ = "0.1.0"
