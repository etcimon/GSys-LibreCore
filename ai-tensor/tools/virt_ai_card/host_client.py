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
    MSG_PING,
    MSG_PONG,
    MSG_RESULT,
    MSG_SHUTDOWN,
    VirtualPcieLink,
    bar4_encode_int8_matrix,
)


class HostClient:
    def __init__(self, host: str = "127.0.0.1", port: int = 18765) -> None:
        self.link = VirtualPcieLink(host=host, port=port)
        self._sock = None

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

    def bar4_get(self, name: str) -> Any:
        r = self.link.request({"type": MSG_BAR4_GET, "name": name}, sock=self._sock)
        if r.get("type") == MSG_ERROR or not r.get("ok"):
            raise RuntimeError(f"bar4_get: {r}")
        blob = r.get("blob") or {}
        return blob.get("data")

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
    ) -> List[List[int]]:
        msg: Dict[str, Any] = {
            "type": MSG_GEMM_S8,
            "ticket": ticket,
            "irq": irq,
        }
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
        return c


def main(argv: Optional[list] = None) -> int:
    p = argparse.ArgumentParser(description="Virtual PCIe AI card host client")
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
