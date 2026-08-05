# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# pcbparts_mcp.py — Dependency-free Python client for the pcbparts.dev MCP server.
#
# This mirrors build-platform/src/tooling/pcbparts.ts on the SKiDL side so a
# design.py can query the same 14 tools during the ERC -> alternatives loop.
# Rules match the TS client:
#   * NO IMPLICIT NETWORK: a call only hits the wire when allow_network is true
#     (env PCBPARTS_ALLOW_NETWORK=1). Otherwise it is cache-first and returns a
#     typed stub.
#   * Everything is cached on disk (env PCBPARTS_CACHE_DIR) so re-queries are
#     fast and reproducible offline.
# Only the Python standard library is used (urllib, json, hashlib).

from __future__ import annotations

import hashlib
import json
import os
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

TOOLS = (
    "jlc_search",
    "jlc_stock_check",
    "jlc_get_part",
    "jlc_get_pinout",
    "jlc_find_alternatives",
    "jlc_search_help",
    "sensor_recommend",
    "board_search",
    "board_get",
    "mouser_get_part",
    "digikey_get_part",
    "cse_search",
    "cse_get_kicad",
    "get_design_rules",
)


@dataclass
class PcbPartsResult:
    tool: str
    args: dict[str, Any]
    data: Any
    source: str  # "cache" | "network" | "stub"
    ok: bool
    note: str | None = None


@dataclass
class PcbPartsClient:
    url: str = field(default_factory=lambda: os.environ.get("PCBPARTS_MCP_URL", "https://pcbparts.dev/mcp"))
    cache_dir: Path = field(
        default_factory=lambda: Path(os.environ.get("PCBPARTS_CACHE_DIR", ".cache/pcbparts"))
    )
    timeout: float = 30.0
    allow_network: bool = field(
        default_factory=lambda: os.environ.get("PCBPARTS_ALLOW_NETWORK", "0") == "1"
    )
    _session: str | None = field(default=None, init=False, repr=False)
    _id: int = field(default=0, init=False, repr=False)
    _initialised: bool = field(default=False, init=False, repr=False)

    # -- cache -------------------------------------------------------------
    def _cache_path(self, tool: str, args: dict[str, Any]) -> Path:
        key = hashlib.sha1((tool + "\0" + json.dumps(args, sort_keys=True)).encode()).hexdigest()[:16]
        return self.cache_dir / f"{tool}-{key}.json"

    def _read_cache(self, path: Path) -> Any | None:
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text())
        except Exception:
            return None

    def _write_cache(self, path: Path, value: Any) -> None:
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2))

    # -- transport ---------------------------------------------------------
    def _rpc(self, method: str, params: Any) -> dict[str, Any]:
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self._id, "method": method, "params": params}).encode()
        headers = {
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        }
        if self._session:
            headers["mcp-session-id"] = self._session
        req = urllib.request.Request(self.url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:  # noqa: S310 (explicit, gated)
            sid = resp.headers.get("mcp-session-id")
            if sid:
                self._session = sid
            text = resp.read().decode()
        return _parse_payload(text)

    def _ensure_init(self) -> None:
        if self._initialised:
            return
        self._rpc(
            "initialize",
            {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "cva6-corev-mb", "version": "0.1.0"},
            },
        )
        try:
            self._rpc("notifications/initialized", {})
        except Exception:
            pass
        self._initialised = True

    # -- public API --------------------------------------------------------
    def call(self, tool: str, args: dict[str, Any] | None = None, refresh: bool = False) -> PcbPartsResult:
        args = args or {}
        path = self._cache_path(tool, args)
        if not refresh:
            cached = self._read_cache(path)
            if cached is not None:
                return PcbPartsResult(tool, args, cached, "cache", True)
        if not self.allow_network:
            return PcbPartsResult(tool, args, None, "stub", True, "network disabled (PCBPARTS_ALLOW_NETWORK=0)")
        try:
            self._ensure_init()
            resp = self._rpc("tools/call", {"name": tool, "arguments": args})
            if "error" in resp and resp["error"]:
                return PcbPartsResult(tool, args, None, "network", False, str(resp["error"].get("message")))
            data = _extract_payload(resp.get("result"))
            self._write_cache(path, data)
            return PcbPartsResult(tool, args, data, "network", True)
        except Exception as exc:  # noqa: BLE001 (report, do not crash the design loop)
            return PcbPartsResult(tool, args, None, "network", False, str(exc))

    # convenience wrappers ------------------------------------------------
    def jlc_search(self, query: str, **kw: Any) -> PcbPartsResult:
        return self.call("jlc_search", {"query": query, **kw})

    def jlc_find_alternatives(self, **kw: Any) -> PcbPartsResult:
        return self.call("jlc_find_alternatives", kw)

    def jlc_get_pinout(self, **kw: Any) -> PcbPartsResult:
        return self.call("jlc_get_pinout", kw)

    def cse_get_kicad(self, **kw: Any) -> PcbPartsResult:
        return self.call("cse_get_kicad", kw)

    def board_get(self, **kw: Any) -> PcbPartsResult:
        return self.call("board_get", kw)

    def get_design_rules(self, **kw: Any) -> PcbPartsResult:
        return self.call("get_design_rules", kw)


def _parse_payload(text: str) -> dict[str, Any]:
    stripped = text.strip()
    if stripped.startswith("{") or stripped.startswith("["):
        return json.loads(stripped)
    frames = [ln[5:].strip() for ln in stripped.splitlines() if ln.startswith("data:")]
    for frame in reversed(frames):
        try:
            return json.loads(frame)
        except Exception:
            continue
    raise ValueError("unparseable MCP response payload")


def _extract_payload(result: Any) -> Any:
    if not isinstance(result, dict):
        return result
    if "structuredContent" in result:
        return result["structuredContent"]
    for item in result.get("content", []) or []:
        if isinstance(item, dict) and item.get("type") == "text":
            text = item.get("text", "")
            try:
                return json.loads(text)
            except Exception:
                return text
    return result
