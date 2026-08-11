# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""
Virtual PCIe link: host↔card data path over localhost TCP (JSON framing).

Models:
  - virtio-net / SSH-like "push workload" control plane
  - BAR4 bulk buffer transfer (tensors as nested lists or base64 raw int8)

Not a TLP simulator — framing only for CI.
"""

from __future__ import annotations

import json
import socket
import struct
import threading
from typing import Any, Callable, Dict, Optional, Sequence, Tuple

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 18765

# Message types
MSG_HELLO = "hello"
MSG_GEMM_S8 = "gemm_s8"
MSG_BAR4_PUT = "bar4_put"
MSG_BAR4_GET = "bar4_get"
MSG_RESULT = "result"
MSG_ERROR = "error"
MSG_PING = "ping"
MSG_PONG = "pong"
MSG_SHUTDOWN = "shutdown"


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed")
        buf.extend(chunk)
    return bytes(buf)


def send_msg(sock: socket.socket, obj: Dict[str, Any]) -> None:
    """Length-prefixed UTF-8 JSON (u32 BE length + payload)."""
    raw = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sock.sendall(struct.pack(">I", len(raw)) + raw)


def recv_msg(sock: socket.socket) -> Dict[str, Any]:
    hdr = _recv_exact(sock, 4)
    (n,) = struct.unpack(">I", hdr)
    if n > 64 * 1024 * 1024:
        raise ValueError(f"message too large: {n}")
    raw = _recv_exact(sock, n)
    return json.loads(raw.decode("utf-8"))


class VirtualPcieLink:
    """
    Thin TCP transport used by both host_client and card_agent.

    In-process alternative: pass shared handlers without sockets via
    ``serve_inprocess`` / local callback (smoke may use threads + real TCP
    on an ephemeral port for realism).
    """

    def __init__(
        self,
        host: str = DEFAULT_HOST,
        port: int = DEFAULT_PORT,
    ) -> None:
        self.host = host
        self.port = port
        self._server: Optional[socket.socket] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._handler: Optional[Callable[[Dict[str, Any], socket.socket], None]] = None
        self._client: Optional[socket.socket] = None

    # -- server (card side) -------------------------------------------------

    def start_server(
        self,
        handler: Callable[[Dict[str, Any], socket.socket], None],
        *,
        backlog: int = 4,
    ) -> Tuple[str, int]:
        """Bind and accept in a background thread. Returns (host, port)."""
        if self._server is not None:
            raise RuntimeError("server already started")
        self._handler = handler
        self._stop.clear()
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((self.host, self.port if self.port else 0))
        srv.listen(backlog)
        srv.settimeout(0.5)
        self._server = srv
        self.host, self.port = srv.getsockname()[:2]

        def _loop() -> None:
            assert self._server is not None
            while not self._stop.is_set():
                try:
                    conn, _addr = self._server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    self._serve_conn(conn)
                finally:
                    try:
                        conn.close()
                    except OSError:
                        pass

        self._thread = threading.Thread(target=_loop, name="virt-pcie-srv", daemon=True)
        self._thread.start()
        return self.host, self.port

    def _serve_conn(self, conn: socket.socket) -> None:
        conn.settimeout(5.0)
        handler = self._handler
        if handler is None:
            return
        while not self._stop.is_set():
            try:
                msg = recv_msg(conn)
            except (ConnectionError, TimeoutError, OSError, json.JSONDecodeError):
                break
            if msg.get("type") == MSG_SHUTDOWN:
                send_msg(conn, {"type": MSG_RESULT, "ok": True})
                break
            try:
                handler(msg, conn)
            except Exception as exc:  # noqa: BLE001 — surface to host
                try:
                    send_msg(
                        conn,
                        {"type": MSG_ERROR, "error": str(exc)},
                    )
                except OSError:
                    break

    def stop_server(self) -> None:
        self._stop.set()
        if self._server is not None:
            try:
                self._server.close()
            except OSError:
                pass
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    # -- client (host side) -------------------------------------------------

    def connect(self, timeout: float = 5.0) -> socket.socket:
        sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self._client = sock
        return sock

    def close_client(self) -> None:
        if self._client is not None:
            try:
                self._client.close()
            except OSError:
                pass
            self._client = None

    def request(
        self,
        msg: Dict[str, Any],
        *,
        sock: Optional[socket.socket] = None,
        timeout: float = 10.0,
    ) -> Dict[str, Any]:
        s = sock or self._client
        if s is None:
            s = self.connect()
        s.settimeout(timeout)
        send_msg(s, msg)
        return recv_msg(s)


def bar4_encode_int8_matrix(mat: Sequence) -> Dict[str, Any]:
    """Encode nested int lists for BAR4-style bulk JSON transfer."""
    return {"format": "int8_lists", "data": mat}


def bar4_decode_matrix(blob: Dict[str, Any]) -> Any:
    if blob.get("format") == "int8_lists":
        return blob["data"]
    raise ValueError(f"unsupported bar4 format: {blob.get('format')}")
