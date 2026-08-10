# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Minimal profile TOML subset (mirrors Rust Profile parser)."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional


@dataclass
class Profile:
    id: str = ""
    backend: str = "sim"
    noc_width: int = 64
    acc_tile_m: int = 256
    acc_tile_n: int = 256
    acc_tile_k: int = 256
    macs_per_cycle: int = 256
    mmio_base: Optional[int] = None
    plic_source: Optional[int] = None
    features: List[str] = field(default_factory=list)
    raw: Dict[str, str] = field(default_factory=dict)

    @classmethod
    def load_file(cls, path: str | Path) -> "Profile":
        text = Path(path).read_text(encoding="utf-8")
        return cls.parse(text)

    @classmethod
    def parse(cls, text: str) -> "Profile":
        p = cls()
        in_features = False
        for raw in text.splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("features"):
                in_features = True
                if "[" in line:
                    body = line.split("[", 1)[1].split("]", 1)[0]
                    for item in body.split(","):
                        s = item.strip().strip("\"'")
                        if s:
                            p.features.append(s)
                if "]" in line:
                    in_features = False
                continue
            if in_features:
                if "]" in line:
                    in_features = False
                    s = line.replace("]", "").strip().strip(",").strip().strip("\"'")
                    if s:
                        p.features.append(s)
                    continue
                s = line.strip().strip(",").strip().strip("\"'")
                if s:
                    p.features.append(s)
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip("\"'")
            p.raw[k] = v
            if k == "id":
                p.id = v
            elif k == "backend":
                p.backend = v
            elif k == "noc_width":
                p.noc_width = int(v, 0)
            elif k == "acc_tile_m":
                p.acc_tile_m = int(v, 0)
            elif k == "acc_tile_n":
                p.acc_tile_n = int(v, 0)
            elif k == "acc_tile_k":
                p.acc_tile_k = int(v, 0)
            elif k == "macs_per_cycle":
                p.macs_per_cycle = int(v, 0)
            elif k == "mmio_base":
                p.mmio_base = int(v, 0)
            elif k == "plic_source":
                p.plic_source = int(v, 0)
        return p
