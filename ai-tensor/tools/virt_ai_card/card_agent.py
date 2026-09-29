# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Card-side agent: bind TCP, receive gemm_s8 jobs, run VirtualUioDevice, return C.

Stand-in for card Linux + sshd + AI runtime accepting pushed workloads.
"""

from __future__ import annotations

import argparse
import sys
import threading
from pathlib import Path
from typing import Any, Dict, Optional

# Allow running as script: python card_agent.py
_PKG = Path(__file__).resolve().parent
if str(_PKG.parent) not in sys.path:
    sys.path.insert(0, str(_PKG.parent))

from virt_ai_card.driver import VirtualEventFd, VirtualUioDevice  # noqa: E402
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
    VirtualPcieLink,
    bar4_decode,
    bar4_encode,
    send_msg,
)


class CardAgent:
    def __init__(
        self, host: str = "127.0.0.1", port: int = 0, *, cap: Optional[dict] = None
    ) -> None:
        self.link = VirtualPcieLink(host=host, port=port)
        self.eventfd = VirtualEventFd()
        self.device = VirtualUioDevice(eventfd=self.eventfd, cap=cap)
        self.device.enable(True)
        self._bar4: Dict[str, Any] = {}
        self._lock = threading.Lock()
        self._bound: Optional[tuple] = None

    def start(self) -> tuple:
        self._bound = self.link.start_server(self._on_msg)
        return self._bound

    def stop(self) -> None:
        self.link.stop_server()

    def _on_msg(self, msg: Dict[str, Any], conn) -> None:
        mtype = msg.get("type")
        if mtype == MSG_HELLO:
            send_msg(
                conn,
                {
                    "type": MSG_RESULT,
                    "ok": True,
                    "boardid": "virt-ai-pcie",
                    "cap_version": self.device.cap_version(),
                    "cap": self.device.cap_snapshot(),
                    "uio": self.device.path,
                    "eventfd": self.eventfd.path,
                    "mmio_size": 0x1000,
                },
            )
            return
        if mtype == MSG_PING:
            send_msg(conn, {"type": MSG_PONG})
            return
        if mtype == MSG_MMIO_RD:
            off = int(msg.get("off", -1))
            val = self.device.read32(off)
            send_msg(
                conn,
                {"type": MSG_RESULT, "ok": True, "off": off, "val": val},
            )
            return
        if mtype == MSG_MMIO_WR:
            off = int(msg.get("off", -1))
            val = int(msg.get("val", 0))
            self.device.write32(off, val)
            send_msg(
                conn,
                {"type": MSG_RESULT, "ok": True, "off": off},
            )
            return
        if mtype == MSG_IRQ_WAIT:
            timeout = float(msg.get("timeout", 2.0))
            try:
                n = self.eventfd.wait(timeout=timeout)
            except TimeoutError as exc:
                send_msg(conn, {"type": MSG_ERROR, "error": str(exc)})
                return
            send_msg(
                conn,
                {"type": MSG_RESULT, "ok": True, "n": n, "path": self.eventfd.path},
            )
            return
        if mtype == MSG_IRQ_CLEAR:
            self.eventfd.clear()
            send_msg(conn, {"type": MSG_RESULT, "ok": True})
            return
        if mtype == MSG_BAR4_PUT:
            name = str(msg.get("name", "blob"))
            blob = msg.get("blob") or {}
            with self._lock:
                data = bar4_decode(blob) if "format" in blob else blob
                self._bar4[name] = data
                if name in ("A", "B") and isinstance(data, list):
                    self.device.stage_tensor(name, data)
            send_msg(conn, {"type": MSG_RESULT, "ok": True, "name": name})
            return
        if mtype == MSG_BAR4_GET:
            name = str(msg.get("name", "blob"))
            with self._lock:
                data = self._bar4.get(name)
                if data is None:
                    data = self.device.get_tensor(name)
            if data is None:
                send_msg(conn, {"type": MSG_ERROR, "error": f"bar4 miss: {name}"})
                return
            send_msg(
                conn,
                {
                    "type": MSG_RESULT,
                    "ok": True,
                    "name": name,
                    "blob": bar4_encode(data),
                },
            )
            return
        if mtype == MSG_GEMM_S8:
            a = msg.get("a")
            b = msg.get("b")
            ticket = int(msg.get("ticket", 1))
            irq = bool(msg.get("irq", True))
            flags = int(msg.get("flags", 0))
            desc = None
            if a is None or b is None:
                # optional BAR4 names
                an = msg.get("a_name")
                bn = msg.get("b_name")
                with self._lock:
                    a = self._bar4.get(an) if an else None
                    b = self._bar4.get(bn) if bn else None
            with self._lock:
                raw_desc = self._bar4.get("DESC")
                if isinstance(raw_desc, (bytes, bytearray)):
                    desc = bytes(raw_desc)
            if a is None or b is None:
                send_msg(conn, {"type": MSG_ERROR, "error": "gemm_s8 needs a/b matrices"})
                return
            try:
                with self._lock:
                    if "reuse_en" in msg:
                        self.device.set_reuse_en(bool(msg.get("reuse_en")))
                    c = self.device.gemm_s8(
                        a, b, ticket=ticket, irq=irq, wait=True, desc=desc, flags=flags
                    )
                    self._bar4["C"] = c
                    self.device.stage_tensor("C", c)
                    read_a = self.device.last_read_a()
                    read_b = self.device.last_read_b()
                    reuse_enabled = self.device.reuse_enabled()
                send_msg(
                    conn,
                    {
                        "type": MSG_RESULT,
                        "ok": True,
                        "ticket": ticket,
                        "c": c,
                        "status": 0,
                        "read_a": read_a,
                        "read_b": read_b,
                        "reuse_enabled": reuse_enabled,
                    },
                )
            except Exception as exc:  # noqa: BLE001
                send_msg(conn, {"type": MSG_ERROR, "error": str(exc)})
            return
        send_msg(conn, {"type": MSG_ERROR, "error": f"unknown type: {mtype}"})


def main(argv: Optional[list] = None) -> int:
    p = argparse.ArgumentParser(description="Virtual PCIe AI card agent")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18765)
    args = p.parse_args(argv)
    agent = CardAgent(host=args.host, port=args.port)
    host, port = agent.start()
    print(f"card_agent: listening on {host}:{port}", flush=True)
    try:
        # park until KeyboardInterrupt
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
    finally:
        agent.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
