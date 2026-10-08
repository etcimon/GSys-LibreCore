# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Host-side client: connect to card agent, push GEMM / BAR4 bulk, wait result.

Stand-in for host virtio-net + SSH job submit + BAR4 mmap upload.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

_PKG = Path(__file__).resolve().parent
if str(_PKG.parent) not in sys.path:
    sys.path.insert(0, str(_PKG.parent))

from virt_ai_card.transport import (  # noqa: E402
    MSG_BAR4_GET,
    MSG_BAR4_PUT,
    MSG_ERROR,
    MSG_GEMM_S8,
    MSG_HELLO,
    MSG_IRQ_CLEAR,
    MSG_IRQ_WAIT,
    MSG_MMIO_RD,
    MSG_MMIO_WR,
    MSG_PING,
    MSG_PONG,
    MSG_RESULT,
    MSG_SHUTDOWN,
    VirtualPcieLink,
    bar4_decode,
    bar4_encode_bytes,
    bar4_encode_int8_matrix,
)


class HostClient:
    def __init__(self, host: str = "127.0.0.1", port: int = 18765) -> None:
        self.link = VirtualPcieLink(host=host, port=port)
        self._sock = None
        self.last_read_a = True
        self.last_read_b = True
        self.reuse_enabled = False

    def connect(self, timeout: float = 5.0) -> Dict[str, Any]:
        self._sock = self.link.connect(timeout=timeout)
        resp = self.link.request({"type": MSG_HELLO}, sock=self._sock)
        if resp.get("type") != MSG_RESULT or not resp.get("ok"):
            raise RuntimeError(f"hello failed: {resp}")
        return resp

    def close(self) -> None:
        if self._sock is not None:
            try:
                self.link.request(
                    {"type": MSG_SHUTDOWN}, sock=self._sock, timeout=2.0
                )
            except Exception:
                pass
        self.link.close_client()
        self._sock = None

    def ping(self) -> bool:
        r = self.link.request({"type": MSG_PING}, sock=self._sock)
        return r.get("type") == MSG_PONG

    def bar4_put(self, name: str, matrix: Sequence[Sequence[int]]) -> None:
        r = self.link.request(
            {
                "type": MSG_BAR4_PUT,
                "name": name,
                "blob": bar4_encode_int8_matrix(matrix),
            },
            sock=self._sock,
        )
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"bar4_put: {r}")

    def bar4_put_bytes(self, name: str, data: bytes) -> None:
        """Push an opaque blob (packed descriptor) over the BAR4 stand-in."""
        r = self.link.request(
            {
                "type": MSG_BAR4_PUT,
                "name": name,
                "blob": bar4_encode_bytes(data),
            },
            sock=self._sock,
        )
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"bar4_put_bytes: {r}")

    def bar4_get(self, name: str) -> Any:
        r = self.link.request({"type": MSG_BAR4_GET, "name": name}, sock=self._sock)
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"bar4_get: {r}")
        blob = r.get("blob") or {}
        if "format" in blob:
            return bar4_decode(blob)
        return blob.get("data")

    def mmio_read32(self, off: int) -> int:
        """Read a word from the existing 4 KiB UIO window (not a pinned PCIe BAR)."""
        r = self.link.request(
            {"type": MSG_MMIO_RD, "off": int(off)}, sock=self._sock
        )
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"mmio_read32: {r}")
        return int(r.get("val", 0)) & 0xFFFFFFFF

    def mmio_write32(self, off: int, val: int) -> None:
        r = self.link.request(
            {"type": MSG_MMIO_WR, "off": int(off), "val": int(val) & 0xFFFFFFFF},
            sock=self._sock,
        )
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"mmio_write32: {r}")

    def mmio_write_bytes(self, off: int, data: bytes) -> None:
        raw = bytes(data)
        pad = (-len(raw)) % 4
        if pad:
            raw = raw + b"\x00" * pad
        for i in range(0, len(raw), 4):
            self.mmio_write32(off + i, int.from_bytes(raw[i : i + 4], "little"))

    def mmio_read_bytes(self, off: int, n: int) -> bytes:
        n4 = n + ((-n) % 4)
        buf = bytearray()
        for i in range(0, n4, 4):
            buf.extend(self.mmio_read32(off + i).to_bytes(4, "little"))
        return bytes(buf[:n])

    def irq_wait(self, timeout: float = 2.0) -> int:
        """Wait for the card eventfd (MSI stand-in). Claim DONE after this returns."""
        r = self.link.request(
            {"type": MSG_IRQ_WAIT, "timeout": float(timeout)},
            sock=self._sock,
            timeout=max(float(timeout) + 1.0, 2.0),
        )
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"irq_wait: {r}")
        return int(r.get("n", 1))

    def irq_clear(self) -> None:
        r = self.link.request({"type": MSG_IRQ_CLEAR}, sock=self._sock)
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"irq_clear: {r}")

    def gemm_s8(
        self,
        a: Optional[Sequence[Sequence[int]]] = None,
        b: Optional[Sequence[Sequence[int]]] = None,
        *,
        a_name: Optional[str] = None,
        b_name: Optional[str] = None,
        ticket: int = 1,
        irq: bool = True,
        timeout: float = 10.0,
        flags: int = 0,
        reuse_en: Optional[bool] = None,
    ) -> List[List[int]]:
        msg: Dict[str, Any] = {
            "type": MSG_GEMM_S8,
            "ticket": ticket,
            "irq": irq,
            "flags": int(flags),
        }
        if reuse_en is not None:
            msg["reuse_en"] = bool(reuse_en)
        if a is not None:
            msg["a"] = a
        if b is not None:
            msg["b"] = b
        if a_name:
            msg["a_name"] = a_name
        if b_name:
            msg["b_name"] = b_name
        r = self.link.request(msg, sock=self._sock, timeout=timeout)
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"gemm_s8: {r}")
        c = r.get("c")
        if c is None:
            raise RuntimeError("gemm_s8: no c in result")
        self.last_read_a = bool(r.get("read_a", True))
        self.last_read_b = bool(r.get("read_b", True))
        self.reuse_enabled = bool(r.get("reuse_enabled", False))
        return c


def main(argv: Optional[list] = None) -> int:
    p = argparse.ArgumentParser(description="Virtual PCIe SI card host client")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18765)
    args = p.parse_args(argv)
    cli = HostClient(host=args.host, port=args.port)
    hello = cli.connect()
    print("hello:", hello)
    a = [[1, 2], [3, 4]]
    b = [[5, 6], [7, 8]]
    c = cli.gemm_s8(a, b, ticket=1)
    print("c:", c)
    assert c == [[19, 22], [43, 50]]
    cli.close()
    print("host_client: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
