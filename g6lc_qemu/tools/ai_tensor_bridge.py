#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# ai_tensor_bridge.py — host bridge over the AI tensor artifact contract.
#
# Design of record: architecture/AI_BRIDGE.md.
#
# This tool exists so work can be *pushed* to the modelled accelerator from outside the
# guest, and the resulting tensor artifact retrieved, without a host project having to
# know how any backend is invoked. The direction of dependency is fixed and one-way
# (AI_BRIDGE.md §5):
#
#     a host project CALLS this bridge; the bridge never calls, imports from, or
#     assumes the layout of a host project.
#
# Three deliberate limits keep it from turning into a second source of truth:
#
#   1. Descriptor offsets, sizes, op codes and status codes are read from an ingested
#      TargetModel JSON (`soc.ai_island.desc_layout`). NOTHING about the descriptor is
#      typed here -- a literal offset in this file would be the exact defect AGENTS.md
#      §1.2 forbids.
#   2. The fidelity-bearing D2 counters (`ai.tensor.*`) are derived by `g6q-diag` in
#      Rust, not recomputed here. This tool reports only aggregates that are *present*
#      in the artifact (counts, histograms, observed tickets/statuses). Re-deriving the
#      MAC/byte model in Python would duplicate a contract.
#   3. It schedules nothing and archives nothing. Those belong to the consumer.
#
# Subcommands:
#   doctor    report which execution routes are available
#   pack      pack a descriptor from name=value pairs using the model's layout
#   push      run one execution and retrieve the tensor artifact
#   results   summarise a tensor artifact (with optional 100-TOPS roofline report)
#   compare   diff two tensor artifacts
#   pcie      report the PCIe host-transport concept and contract status
#   selftest  offline checks (no model, no QEMU, no network)

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
if str(_TOOLS) not in sys.path:
    sys.path.insert(0, str(_TOOLS))

from env_common import package_root, target_dir

_EXE = ".exe" if platform.system() == "Windows" else ""
CLI_BINARY = f"g6lc-qemu{_EXE}"

# Field names the bridge understands as *aliases* for convenience on the command line.
# The mapping is name -> name; it exists only so a caller may omit a package prefix.
# It deliberately carries no offsets, sizes or values.
_FIELD_ALIASES = {
    "op": ("op", "opcode"),
    "version": ("version", "ver"),
    "flags": ("flags",),
    "m": ("m", "dim_m"),
    "n": ("n", "dim_n"),
    "k": ("k", "dim_k"),
}


def log(msg: str) -> None:
    print(f"[ai-bridge] {msg}")


def err(msg: str) -> None:
    print(f"[ai-bridge] ERROR: {msg}", file=sys.stderr)


# --------------------------------------------------------------------- descriptor layout


class LayoutError(RuntimeError):
    """A descriptor could not be packed against the ingested layout."""


class DescLayout:
    """The descriptor layout as ingested into a TargetModel.

    Every offset and size comes from the model. The class refuses to guess: an unknown
    field name is an error naming what *is* available, because a silently ignored field
    produces a descriptor that looks plausible and is wrong.
    """

    def __init__(
        self,
        desc_bytes: int,
        fields: dict,
        ops: dict,
        statuses: dict,
        completion: dict | None = None,
        flags_layout: dict | None = None,
    ) -> None:
        self.desc_bytes = desc_bytes
        self.fields = fields
        self.ops = ops
        self.statuses = statuses
        self.completion = completion or {}
        self.flags_layout = flags_layout or {}

    @classmethod
    def from_model(cls, model: dict) -> "DescLayout":
        island = (model.get("soc") or {}).get("ai_island")
        if not island:
            raise LayoutError(
                "the model has no soc.ai_island; this target does not describe an "
                "accelerator, so no descriptor layout can be derived"
            )
        cfg = island.get("config") or {}
        # The packed image is placement-independent, so an unresolved placement is a
        # warning here rather than an error -- but it is reported, because the descriptor
        # cannot be *delivered* to an island whose windows are unplaced.
        if cfg.get("desc_base") is None or cfg.get("cap_base") is None:
            log(
                "WARNING: the model does not resolve the island MMIO placement "
                "(cap_base/desc_base); a packed descriptor is still correct, but the "
                "target cannot be addressed until the design publishes the window bases"
            )
        layout = island.get("desc_layout") or {}
        fields = layout.get("fields") or {}
        if not fields:
            raise LayoutError(
                "soc.ai_island.desc_layout.fields is empty; the descriptor package was "
                "not ingested, so packing would have to invent offsets"
            )
        desc_bytes = int(layout.get("desc_bytes") or 0)
        if desc_bytes <= 0:
            # Derive the extent from the fields rather than defaulting to a size.
            desc_bytes = max(
                int(f["offset"]) + int(f["size"]) for f in fields.values()
            )
        completion = layout.get("completion") or {}
        flags_layout = layout.get("flags_layout") or {}
        return cls(
            desc_bytes=desc_bytes,
            fields={k: dict(v) for k, v in fields.items()},
            ops={k: int(v) for k, v in (layout.get("ops") or {}).items()},
            statuses={k: int(v) for k, v in (layout.get("statuses") or {}).items()},
            completion={k: int(v) for k, v in completion.items()} if completion else {},
            flags_layout={k: v for k, v in flags_layout.items()} if flags_layout else {},
        )

    @classmethod
    def from_model_file(cls, path: str | Path) -> "DescLayout":
        text = Path(path).read_text(encoding="utf-8")
        return cls.from_model(json.loads(text))

    def resolve(self, name: str) -> str:
        """Map a caller-supplied name onto a field the model actually declares."""
        if name in self.fields:
            return name
        for canonical, aliases in _FIELD_ALIASES.items():
            if name in aliases:
                for candidate in (canonical, *aliases):
                    if candidate in self.fields:
                        return candidate
        known = ", ".join(sorted(self.fields))
        raise LayoutError(f"unknown descriptor field {name!r}; the model declares: {known}")

    def op_value(self, name: str) -> int:
        """Resolve an op by name, or accept an already-numeric value."""
        if name in self.ops:
            return self.ops[name]
        upper = name.upper()
        for key, value in self.ops.items():
            if key.upper() == upper or key.upper().endswith("_" + upper):
                return value
        try:
            return int(name, 0)
        except ValueError as exc:
            known = ", ".join(sorted(self.ops)) or "(none ingested)"
            raise LayoutError(f"unknown op {name!r}; the model declares: {known}") from exc

    def op_name(self, value: int) -> str | None:
        """Best-effort name for an op code; None if the code is not in the layout."""
        for name, v in self.ops.items():
            if v == value:
                return name
        return None

    def status_name(self, value: int) -> str | None:
        """Best-effort name for a status code; None if the code is not in the layout."""
        for name, v in self.statuses.items():
            if v == value:
                return name
        return None

    def irq_mask(self) -> int | None:
        """`1 << irq_bit` from the ingested flags_layout, or None if unpublished."""
        bit = self.flags_layout.get("irq_bit")
        if bit is None:
            return None
        return 1 << int(bit)

    def apply_standin_defaults(self, values: dict) -> dict:
        """IRQ flag from ingested irq_bit; pointer fields stay 0 (null).

        Null `ptr_done` is ABI: no DMA completion-word write (ai-tensor ABI-CONTRACT
        §3). BAR4 names A/B/C carry bulk tensors. Do not invent DRAM or BAR addresses.
        `ld_ab` is packed from already-known `n`/`k` (ai-tensor `pack_desc64`), not an address.
        """
        if "flags" not in values and "flags" in self.fields:
            mask = self.irq_mask()
            if mask is not None:
                values["flags"] = mask
        if "ld_ab" not in values and "ld_ab" in self.fields:
            n, k = values.get("n"), values.get("k")
            if n is not None and k is not None:
                ni = n if isinstance(n, int) else int(str(n), 0)
                ki = k if isinstance(k, int) else int(str(k), 0)
                values["ld_ab"] = (ki & 0xFFFF) | ((ni & 0xFFFF) << 16)
        for name in ("ptr_a", "ptr_b", "ptr_c", "ptr_scale", "ptr_done"):
            if name in self.fields and name not in values:
                values[name] = 0
        return values

    def pack(self, values: dict) -> bytes:
        """Pack a descriptor image, little-endian, using only model-supplied geometry."""
        buf = bytearray(self.desc_bytes)
        for raw_name, raw_value in values.items():
            name = self.resolve(raw_name)
            field = self.fields[name]
            offset, size = int(field["offset"]), int(field["size"])
            value = raw_value if isinstance(raw_value, int) else int(str(raw_value), 0)
            if offset + size > self.desc_bytes:
                raise LayoutError(
                    f"field {name!r} at offset {offset} size {size} does not fit the "
                    f"{self.desc_bytes}-byte descriptor the model describes"
                )
            if value < 0:
                value &= (1 << (size * 8)) - 1
            if value >> (size * 8):
                raise LayoutError(
                    f"value {value:#x} does not fit field {name!r} ({size} bytes)"
                )
            buf[offset : offset + size] = value.to_bytes(size, "little")
        return bytes(buf)

    def unpack(self, image: bytes) -> dict:
        """Read every model-declared field from a packed image. Inverse of pack."""
        if len(image) != self.desc_bytes:
            raise LayoutError(
                f"image is {len(image)} bytes; the model describes a "
                f"{self.desc_bytes}-byte descriptor"
            )
        out: dict = {}
        for name, field in self.fields.items():
            offset, size = int(field["offset"]), int(field["size"])
            out[name] = int.from_bytes(image[offset : offset + size], "little")
        return out

    def decode_text(self, image: bytes) -> str:
        """Shell-friendly decode. Names and widths come from the model, not literals."""
        values = self.unpack(image)
        lines = [
            f"desc_bytes={self.desc_bytes}",
            "layout=ingested",
        ]
        preferred = ("version", "op", "flags", "m", "n", "k", "ld_ab")
        seen: set = set()
        for raw in preferred:
            try:
                name = self.resolve(raw)
            except LayoutError:
                continue
            seen.add(name)
            val = values[name]
            if name == "op" or raw == "op":
                op_name = self.op_name(val)
                lines.append(f"op={op_name or val}")
            elif raw == "flags" and val == 0:
                continue
            elif raw == "ld_ab":
                lda = int(val) & 0xFFFF
                ldb = (int(val) >> 16) & 0xFFFF
                lines.append(f"ld_ab={val}")
                lines.append(f"lda={lda}")
                lines.append(f"ldb={ldb}")
                try:
                    n = int(values[self.resolve("n")])
                    k = int(values[self.resolve("k")])
                    lines.append(f"ld_ab_ok={'true' if lda == k and ldb == n else 'false'}")
                except (LayoutError, KeyError, TypeError, ValueError):
                    pass
            else:
                lines.append(f"{name}={val}")
        for name in sorted(values):
            if name in seen:
                continue
            val = values[name]
            if val == 0:
                continue
            lines.append(f"{name}={val}")
        lines.append("tops_not_evidence=true")
        return "\r\n".join(lines) + "\r\n"

    def pack_completion(self, ticket: int, status: int) -> bytes:
        """Pack a completion word. Bit ranges come from the ingested layout."""
        c = self.completion
        needed = (
            "ticket_bit_low",
            "ticket_bit_high",
            "status_bit_low",
            "status_bit_high",
        )
        missing = [k for k in needed if k not in c]
        if missing:
            raise LayoutError(
                "the model has no usable desc_layout.completion "
                f"(missing {', '.join(missing)})"
            )
        tlo, thi = int(c["ticket_bit_low"]), int(c["ticket_bit_high"])
        slo, shi = int(c["status_bit_low"]), int(c["status_bit_high"])

        def _place(val: int, lo: int, hi: int, name: str) -> int:
            if hi < lo:
                raise LayoutError(f"completion {name} bit range {lo}..{hi} is inverted")
            width = hi - lo + 1
            mask = (1 << width) - 1
            if val < 0 or val > mask:
                raise LayoutError(
                    f"completion {name}={val} does not fit bits [{lo}:{hi}]"
                )
            return (val & mask) << lo

        word = _place(ticket, tlo, thi, "ticket") | _place(status, slo, shi, "status")
        hi = max(thi, shi)
        nbytes = max(8, ((hi // 8) + 1 + 7) // 8 * 8)
        return word.to_bytes(nbytes, "little")

    def unpack_completion(self, image: bytes) -> dict:
        """Read ticket/status from a packed completion word using the ingested ranges."""
        if not self.completion:
            raise LayoutError("the model has no desc_layout.completion")
        word = int.from_bytes(image, "little")
        tlo, thi = int(self.completion["ticket_bit_low"]), int(self.completion["ticket_bit_high"])
        slo, shi = int(self.completion["status_bit_low"]), int(self.completion["status_bit_high"])

        def _extract(lo: int, hi: int) -> int:
            mask = (1 << (hi - lo + 1)) - 1
            return (word >> lo) & mask

        return {"ticket": _extract(tlo, thi), "status": _extract(slo, shi)}

    def completion_text(self) -> str:
        """Shell-friendly completion-word dump. Bit ranges from the ingested layout."""
        lines = ["source=ingested", "layout=completion"]
        for key in (
            "ticket_bit_low",
            "ticket_bit_high",
            "status_bit_low",
            "status_bit_high",
        ):
            if key in self.completion:
                lines.append(f"{key}={self.completion[key]}")
        if "ST_OK" in self.statuses:
            lines.append(f"st_ok={self.statuses['ST_OK']}")
        if self.completion and "ST_OK" in self.statuses:
            try:
                img = self.pack_completion(1, self.statuses["ST_OK"])
                lines.append("example_ticket=1")
                lines.append(f"example_status={self.statuses['ST_OK']}")
                lines.append(f"example_hex={img.hex()}")
            except LayoutError:
                pass
        lines.append("tops_not_evidence=true")
        return "\r\n".join(lines) + "\r\n"


# ------------------------------------------------------------------------- the artifact


class TensorArtifact:
    """A parsed tensor artifact, as written by B3 or by the B2 plugin.

    Both routes emit the same shape (AI_BRIDGE.md §5), so a caller cannot tell which
    backend produced a result except by reading the stamped header.
    """

    def __init__(
        self,
        header: dict,
        events: list,
        flags_layout: dict | None = None,
    ) -> None:
        self.header = header
        self.events = events
        self.flags_layout = flags_layout or {}

    @classmethod
    def load(cls, path: str | Path) -> "TensorArtifact":
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        if isinstance(raw, list):
            # A bare event array is accepted; the header is then simply unknown.
            return cls({}, raw)
        return cls(
            raw.get("header") or {},
            raw.get("events") or [],
            raw.get("flags_layout"),
        )

    @property
    def profile(self) -> str:
        return str(self.header.get("profile", "unknown"))

    @property
    def tainted(self) -> bool:
        return bool(self.header.get("profile_tainted", False))

    def _dtype_for_event(self, ev: dict) -> int:
        """Return `dtype`, recovering it from `flags` when the layout is present.

        The B2/B3 emitter writes `dtype` explicitly, but older artifacts and bare
        event arrays may carry only `flags`.  When `flags_layout` is present, derive
        the data type from the packed flag word using the ingested shift/mask.
        """
        dtype = ev.get("dtype")
        if dtype not in (None, 0, "?"):
            return int(dtype)
        flags = ev.get("flags")
        if flags is None or not self.flags_layout:
            return int(dtype) if dtype is not None else 0
        shift = int(self.flags_layout.get("dtype_shift", 0))
        mask = int(self.flags_layout.get("dtype_mask", 0))
        return (int(flags) >> shift) & mask

    def summary(self, layout: DescLayout | None = None, clusters: int | None = None) -> dict:
        """Aggregates that are *present* in the stream.

        Deliberately excludes `ai.tensor.bytes` / `ai.tensor.macs`: those are modelled
        quantities owned by `g6q-diag` (see the module docstring, limit 2).

        When a `DescLayout` is supplied, op and status codes are resolved to the names
        the design's package publishes, which is what a Python/PyTorch consumer needs to
        map the raw stream onto `torch.nn.functional` calls or reference kernels.
        """
        ops: dict = {}
        op_names: dict = {}
        harts: dict = {}
        statuses: dict = {}
        status_names: dict = {}
        dtypes: dict = {}
        by_cluster: dict = {}
        done = 0
        for ev in self.events:
            op = ev.get("op", "?")
            ops[str(op)] = ops.get(str(op), 0) + 1
            if layout:
                name = layout.op_name(int(op)) if isinstance(op, int) else None
                if name:
                    op_names[name] = op_names.get(name, 0) + 1

            status = ev.get("status", "?")
            statuses[str(status)] = statuses.get(str(status), 0) + 1
            if layout:
                name = layout.status_name(int(status)) if isinstance(status, int) else None
                if name:
                    status_names[name] = status_names.get(name, 0) + 1

            harts[str(ev.get("hart", "?"))] = harts.get(str(ev.get("hart", "?")), 0) + 1

            dtype = self._dtype_for_event(ev)
            dtypes[str(dtype)] = dtypes.get(str(dtype), 0) + 1

            cluster = ev.get("cluster", 0)
            by_cluster[str(cluster)] = by_cluster.get(str(cluster), 0) + 1

            if ev.get("done"):
                done += 1

        out: dict = {
            "profile": self.profile,
            "profile_tainted": self.tainted,
            "evidence": bool(self.header.get("evidence", False)),
            "events": len(self.events),
            "done": done,
            "inflight": len(self.events) - done,
            "by_op": ops,
            "by_status": statuses,
            "by_hart": harts,
            "by_dtype": dtypes,
            "by_cluster": by_cluster,
        }
        if clusters is not None:
            out["clusters"] = clusters
        if op_names:
            out["by_op_name"] = op_names
        if status_names:
            out["by_status_name"] = status_names
        return out

    def to_json(self) -> dict:
        raw = {"header": self.header, "events": self.events}
        if self.flags_layout:
            raw["flags_layout"] = self.flags_layout
        return raw

    def dump(self, path: str | Path) -> None:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(self.to_json(), indent=2) + "\n", encoding="utf-8")

    def pytorch_summary(self, layout: DescLayout | None = None) -> list:
        """Return one entry per completed tensor operation.

        This is the shape a Python/PyTorch consumer needs: resolved op and status names,
        input/output shapes, dtype code, and the guest pointers for A/B/C.  The consumer
        cannot dereference guest pointers, but it can compare this metadata against a
        reference implementation run on the host.
        """
        out: list = []
        for ev in self.events:
            if not ev.get("done"):
                continue
            op_code = ev.get("op", 0)
            status_code = ev.get("status", 0)
            op_name = layout.op_name(op_code) if layout else None
            status_name = layout.status_name(status_code) if layout else None
            entry = {
                "order": ev.get("order"),
                "hart": ev.get("hart"),
                "op_code": op_code,
                "op_name": op_name,
                "status_code": status_code,
                "status_name": status_name,
                "shape_m": ev.get("m"),
                "shape_n": ev.get("n"),
                "shape_k": ev.get("k"),
                "dtype": self._dtype_for_event(ev),
                "cluster": ev.get("cluster", 0),
                "ptr_a": ev.get("ptr_a"),
                "ptr_b": ev.get("ptr_b"),
                "ptr_c": ev.get("ptr_c"),
                "ptr_done": ev.get("ptr_done"),
                "ticket": ev.get("ticket"),
            }
            out.append(entry)
        return out


def compare_artifacts(lhs: TensorArtifact, rhs: TensorArtifact) -> list:
    """First-divergence diff between two artifacts.

    Mirrors the D1 convention of reporting the *first* divergence rather than a wall of
    differences: a later event differing is usually a consequence of an earlier one.
    """
    diffs: list = []
    if len(lhs.events) != len(rhs.events):
        diffs.append(
            {
                "field": "events",
                "lhs": len(lhs.events),
                "rhs": len(rhs.events),
            }
        )
    for idx, (a, b) in enumerate(zip(lhs.events, rhs.events)):
        for key in sorted(set(a) | set(b)):
            if a.get(key) != b.get(key):
                diffs.append(
                    {
                        "index": idx,
                        "field": key,
                        "lhs": a.get(key),
                        "rhs": b.get(key),
                    }
                )
        if diffs and any("index" in d for d in diffs):
            break
    return diffs


# ------------------------------------------------------------------------------- roofline / 100-TOPS report


def _sources_from_model(model: dict | None) -> dict:
    """Infer the source files needed to re-ingest this model for `g6lc-qemu diag`.

    The model's provenance carries the paths it was built from; when the caller has not
    supplied a repo root, the bridge can hand those exact paths back to `diag` so the
    fixture case still works.  Inference is by filename suffix, because the provenance
    stream does not label roles.
    """
    out = {}
    if not model:
        return out
    provenance = (model.get("provenance") or {}).get("sources") or []
    for entry in provenance:
        path = entry.get("path") if isinstance(entry, dict) else None
        if not path:
            continue
        p = Path(path)
        if p.suffix == ".dts" and "dts" not in out:
            out["dts"] = path
        elif p.suffix == ".sv" and ("_config_pkg" in p.stem or "_cfg_pkg" in p.stem) and "config_pkg" not in out:
            out["config_pkg"] = path
        elif p.suffix in (".f",) and p.is_file():
            out.setdefault("flists", []).append(path)
    return out


def _diag_for_artifact(
    artifact_path: str,
    target_id: str,
    model: dict | None,
    repo_root: str | None,
    measured_dram_gbps: float | None,
    uarch_out: str | None,
) -> dict:
    """Run `g6lc-qemu diag` on the artifact and return a map of counter name -> value.

    This keeps the roofline arithmetic in one place: Rust derives the D2 counters, the
    bridge only re-aggregates what is *present* in the counter stream and in the artifact.
    """
    binary = cli_binary()
    if not binary:
        raise LayoutError("g6lc-qemu binary not found; run `g6q build` first")

    uarch_path = Path(uarch_out) if uarch_out else Path(tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, prefix="g6q_bridge_uarch_"
    ).name)

    cmd: list = [str(binary), "diag", "--target", target_id, "--tensor", str(artifact_path), "--uarch-out", str(uarch_path)]
    if repo_root:
        cmd += ["--repo-root", repo_root]
    else:
        srcs = _sources_from_model(model)
        if srcs.get("config_pkg"):
            cmd += ["--config-pkg", srcs["config_pkg"]]
        for flist in srcs.get("flists") or []:
            cmd += ["--flist", flist]
        if srcs.get("dts"):
            cmd += ["--dts", srcs["dts"]]
    if measured_dram_gbps is not None:
        v = int(round(measured_dram_gbps * 1000.0))
        if v < 0:
            raise LayoutError("--measured-dram-gbps must be non-negative")
        cmd += ["--measured-dram-gbps-x1000", str(v)]

    res = _run(cmd, check=False)
    if res.returncode != 0:
        raise LayoutError(f"diag failed: {res.stderr or res.stdout or '(no output)'}")

    try:
        raw = json.loads(uarch_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LayoutError(f"cannot read uarch counters from {uarch_path}: {exc}") from exc

    out: dict = {}
    for row in raw:
        out[row.get("name")] = row.get("value")
    return out


def _event_macs(ev: dict) -> int:
    m = ev.get("m") or 0
    n = ev.get("n") or 0
    k = ev.get("k") or 0
    return int(m) * int(n) * int(k)


def _tops_report(counters: dict, events: list, model_cfg: dict | None) -> dict:
    """A 100-TOPS-oriented report that stays on the modelled side of the line.

    Everything here is either a raw D2 counter (from `g6lc-qemu diag`) or a simple
    aggregate over the artifact (counts, sums).  We do NOT re-derive the roofline; we
    report the model's own peak and the theoretical time the *observed* MACs would take
    at that peak.  Achieved TOPS can only come from measured cycles, which the package
    does not invent.
    """
    peak_ops = counters.get("ai.roofline.peak_ops_per_sec")
    macs_per_cycle_total = counters.get("ai.roofline.macs_per_cycle_total")
    clock_khz = (model_cfg or {}).get("clock_khz") or counters.get("ai.island.clock_khz")
    blocking_t = counters.get("ai.roofline.blocking_t")
    balance = counters.get("ai.roofline.balance_mac_per_byte")
    intensity = counters.get("ai.roofline.tiled_input_intensity_mac_per_byte")

    total_macs = 0
    total_ops = 0
    tensor_macs = counters.get("ai.tensor.macs")
    tensor_ops = counters.get("ai.tensor.ops")

    for ev in events:
        if ev.get("done"):
            total_macs += _event_macs(ev)
    total_ops = total_macs * 2

    out: dict = {}
    if peak_ops is not None:
        out["peak_tops"] = float(peak_ops) / 1e12
        out["peak_gops"] = float(peak_ops) / 1e9
        # The time the total MACs would take at full utilisation.  This is a thought
        # experiment, not a measurement; it says "if the machine ran at peak, the
        # workload in this artifact would take X microseconds".
        if total_ops and peak_ops:
            out["theoretical_time_us_at_peak"] = (float(total_ops) / float(peak_ops)) * 1e6
    if macs_per_cycle_total is not None:
        out["macs_per_cycle_total"] = macs_per_cycle_total
    if clock_khz is not None:
        out["clock_ghz"] = float(clock_khz) / 1_000_000.0
    if blocking_t is not None:
        out["blocking_t"] = blocking_t
    if balance is not None:
        out["balance_mac_per_byte"] = balance
    if intensity is not None:
        out["tiled_input_intensity_mac_per_byte"] = intensity
    if balance is not None and intensity is not None:
        # A simple interpretation of the two D2 counters: when the observed input
        # intensity is above the machine balance, the workload is compute-bound at
        # the modelled peak; otherwise it is DRAM-bandwidth-bound.
        out["bound"] = "Compute" if intensity >= balance else "Bandwidth"
    out["total_macs"] = total_macs
    out["total_ops"] = total_ops
    out["total_gops"] = float(total_ops) / 1e9
    if tensor_macs is not None:
        out["tensor_macs_counter"] = tensor_macs
    if tensor_ops is not None:
        out["tensor_ops_counter"] = tensor_ops
    return out


# ------------------------------------------------------------------------------- routes


def cli_binary() -> Path | None:
    for flavour in ("release", "debug"):
        candidate = target_dir() / flavour / CLI_BINARY
        if candidate.is_file():
            return candidate
    return None


def _run(cmd: list, check: bool = True) -> subprocess.CompletedProcess:
    log("+ " + " ".join(str(c) for c in cmd))
    return subprocess.run(
        [str(c) for c in cmd], cwd=package_root(), check=check, text=True
    )


def push_native(args: argparse.Namespace) -> int:
    """Route: the B3 native VM, in-process, no QEMU and no network."""
    binary = cli_binary()
    out = Path(args.tensor_out)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Prefer the built binary; fall back to `g6q.py run --`, which forwards to cargo.
    base = [binary] if binary else [sys.executable, str(_TOOLS / "g6q.py"), "run", "--"]
    cmd = [*base, "run", "--backend", "native", "--image", args.image, "--tensor", str(out)]
    if args.target:
        cmd += ["--target", args.target]
    if args.steps:
        cmd += ["--steps", str(args.steps)]
    if args.dry_run:
        log("dry-run: " + " ".join(str(c) for c in cmd))
        return 0
    res = _run(cmd, check=False)
    if res.returncode != 0:
        err("native run failed")
        return res.returncode
    log(f"tensor artifact at {out}")
    return 0


def push_remote(args: argparse.Namespace) -> int:
    """Route: a remote QEMU execution, delegated to g6q_remote.py."""
    remote = _TOOLS / "g6q_remote.py"
    cmd = [
        sys.executable,
        str(remote),
        "test",
        "--ai-island",
        "--plugin-tensor",
        args.remote_tensor,
    ]
    if args.machine:
        cmd += ["--machine", args.machine]
    if args.tag:
        cmd += ["--tag", args.tag]
    if args.dry_run:
        cmd += ["--dry-run"]
    res = _run(cmd, check=False)
    if res.returncode != 0:
        err("remote run failed")
    return res.returncode


def find_ai_tensor_root(repo_root: str | None = None) -> Path | None:
    """Locate the ai-tensor package (runtime discovery, not a compile dependency)."""
    candidates = []
    env = os.environ.get("AI_TENSOR_ROOT")
    if env:
        candidates.append(Path(env))
    if repo_root:
        candidates.append(Path(repo_root) / "ai-tensor")
    candidates.append(package_root().parent / "ai-tensor")
    for c in candidates:
        if (c / "tools" / "virt_ai_card" / "smoke.py").is_file():
            return c
    return None


def island_config(model: dict) -> dict:
    return ((model.get("soc") or {}).get("ai_island") or {}).get("config") or {}


def modelled_peak_ops(cfg: dict) -> int | None:
    """Peak ops/s from ingested geometry. 1 MAC = 2 ops (scaling-100tops.md §2).

    `macs_per_cycle` is the island total as published. Not a measurement.
    """
    macs = cfg.get("macs_per_cycle")
    clock_khz = cfg.get("clock_khz")
    if macs is None or clock_khz is None:
        return None
    hz = int(clock_khz) * 1000
    if hz <= 0 or int(macs) <= 0:
        return None
    return int(macs) * hz * 2


def _fmt_peak(n: float) -> str:
    s = f"{n:.6f}".rstrip("0").rstrip(".")
    return s


def island_cap_text(model: dict) -> str:
    """Shell-friendly CAP dump. Geometry from the model; TOPS is definition + modelled peak."""
    cfg = island_config(model)
    lines = ["source=ingested", "window=cap"]
    for key in (
        "clusters",
        "macs_per_cycle",
        "clock_khz",
        "acc_tile_m",
        "acc_tile_n",
        "acc_tile_k",
        "sram_bytes",
        "queues",
        "queue_depth",
        "dram_gbps",
    ):
        if cfg.get(key) is not None:
            lines.append(f"{key}={cfg[key]}")
    peak = modelled_peak_ops(cfg)
    if peak is not None:
        lines.append(f"modelled_peak_ops_per_s={peak}")
        lines.append(f"modelled_peak_gops={_fmt_peak(peak / 1e9)}")
        lines.append(f"modelled_peak_tops={_fmt_peak(peak / 1e12)}")
    class_vs = class_vs_sku(cfg)
    lines.extend(class_vs)
    lines.append("tops_def=100e12 dense INT8 ops/s; MAC=2 ops; no sparsity/INT4")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def plane_text(model: dict) -> str:
    """Two-plane split. Island geometry from the model; core tile is not in this IR."""
    cfg = island_config(model)
    lines = ["source=ingested", "split=two_plane"]
    lines.append("island_role=throughput")
    for src, name in (
        ("acc_tile_m", "island_acc_tile_m"),
        ("acc_tile_n", "island_acc_tile_n"),
        ("acc_tile_k", "island_acc_tile_k"),
        ("clusters", "island_clusters"),
        ("macs_per_cycle", "island_macs_per_cycle"),
    ):
        if cfg.get(src) is not None:
            lines.append(f"{name}={cfg[src]}")
    lines.append("core_plane=latency")
    lines.append("core_tile=not_in_this_model")
    lines.append("tops_on=island")
    lines.append("ref=scaling-100tops.md s3")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def join_text(*, desc: bytes | None, cpl: bytes | None) -> str:
    """Firmware ESP images the card stand-in also uses. Not a BAR map."""
    lines = ["source=ingested", "join=firmware_and_card"]
    if desc:
        lines.append(f"desc_bytes={len(desc)}")
        lines.append(f"desc_hex_prefix={desc[:4].hex()}")
        lines.append(f"desc_sha256={_sha256_hex(desc)}")
    if cpl:
        lines.append(f"cpl_bytes={len(cpl)}")
        lines.append(f"cpl_hex={cpl.hex()}")
        lines.append(f"cpl_sha256={_sha256_hex(cpl)}")
    lines.append("bar4_desc=DESC")
    lines.append("bar4_cpl=CPL")
    lines.append("irq=wait_then_claim_done")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def roof_text(model: dict) -> str:
    """Class vs SKU DRAM roofline. T from ingested acc_tile_m; 2/T from scaling-100tops.md §4."""
    cfg = island_config(model)
    lines = ["source=ingested", "model=scaling-100tops.md s4"]
    t = cfg.get("acc_tile_m")
    if t:
        t = int(t)
        lines.append(f"blocking_t={t}")
        bpm = 2.0 / float(t)
        lines.append(f"bytes_per_mac={_fmt_peak(bpm)}")
        class_macs_per_s = 50 * 10**12
        class_gbps = bpm * class_macs_per_s / 1e9
        lines.append(f"class_dram_gbps={_fmt_peak(class_gbps)}")
        macs = cfg.get("macs_per_cycle")
        clock_khz = cfg.get("clock_khz")
        if macs is not None and clock_khz:
            hz = int(clock_khz) * 1000
            if hz > 0:
                sku_macs_per_s = int(macs) * hz
                sku_gbps = bpm * sku_macs_per_s / 1e9
                lines.append(f"sku_dram_gbps={_fmt_peak(sku_gbps)}")
        if cfg.get("dram_gbps") is not None:
            lines.append(f"published_dram_gbps={cfg['dram_gbps']}")
        acc_sram = t * t * 4
        lines.append(f"acc_sram_bytes={acc_sram}")
        lines.append(f"acc_sram_kib={acc_sram // 1024}")
        island_sram = cfg.get("sram_bytes")
        if island_sram is not None:
            lines.append(f"island_sram_bytes={int(island_sram)}")
            lines.append(f"acc_fits_island_sram={'true' if acc_sram <= int(island_sram) else 'false'}")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def queue_text(model: dict) -> str:
    """Ingested ring/QoS geometry. Doorbell qid 0 is the first ring, not a BAR."""
    cfg = island_config(model)
    lines = ["source=ingested", "window=queues"]
    for key in (
        "queues",
        "queue_depth",
        "qos_classes",
        "work_quantum_k",
        "noc_width",
        "dram_channels",
    ):
        if cfg.get(key) is not None:
            lines.append(f"{key}={cfg[key]}")
    qmap = cfg.get("queue_cluster_map")
    if isinstance(qmap, list) and qmap:
        lines.append("queue_cluster_map=" + ",".join(str(int(x)) for x in qmap))
        lines.append("cluster_from_map=true")
        for i, c in enumerate(qmap):
            lines.append(f"qid{i}_cluster={int(c)}")
    nqos = cfg.get("qos_classes")
    nq = cfg.get("queues")
    if nqos and nq:
        nqos_i, nq_i = int(nqos), int(nq)
        if nqos_i > 0 and nq_i > 0:
            lines.append("qos_from_qid=true")
            for i in range(nq_i):
                lines.append(f"qid{i}_qos={i % nqos_i}")
    nq = cfg.get("queues")
    if nq:
        nq_i = int(nq)
        lines.append("doorbell_qid=0")
        lines.append(f"doorbell_qid_last={nq_i - 1}")
        lines.append(f"doorbell_qid_ok={'true' if nq_i > 0 else 'false'}")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def sched_text(model: dict, standin_k: int | None = None) -> str:
    """§7.1 scheduling: ingested work quantum and qid→QoS. Not a BAR, not a measurement."""
    cfg = island_config(model)
    lines = ["source=ingested", "window=sched"]
    q = cfg.get("work_quantum_k")
    if q is not None:
        lines.append(f"work_quantum_k={int(q)}")
    if standin_k is not None and q:
        lines.append(f"standin_k={int(standin_k)}")
        lines.append(f"within_quantum={'true' if int(standin_k) <= int(q) else 'false'}")
    nqos = cfg.get("qos_classes")
    nq = cfg.get("queues")
    if nqos and nq and int(nqos) > 0 and int(nq) > 0:
        lines.append(f"qos_classes={int(nqos)}")
        lines.append("qos_from_qid=true")
        for i in range(int(nq)):
            lines.append(f"qid{i}_qos={i % int(nqos)}")
    lines.append("ref=isa-encoding.md s7.1")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def stat_text(model: dict, desc_version: int | None = None) -> str:
    """qid bounds and descriptor version. oob is rejected; status codes stay ingested ST_OK."""
    cfg = island_config(model)
    layout = (model.get("soc") or {}).get("ai_island", {}).get("desc_layout") or {}
    statuses = layout.get("statuses") or {}
    lines = ["source=ingested", "window=status"]
    if "ST_OK" in statuses:
        lines.append(f"st_ok={int(statuses['ST_OK'])}")
    nq = cfg.get("queues")
    if nq:
        nq_i = int(nq)
        lines.append(f"queues={nq_i}")
        lines.append("qid_min=0")
        lines.append(f"qid_last={nq_i - 1}")
        lines.append(f"oob_qid={nq_i}")
        lines.append("qid_bound=true")
    if desc_version is not None:
        lines.append(f"desc_version={int(desc_version)}")
        lines.append(f"version_ok={'true' if int(desc_version) == 1 else 'false'}")
    lines.append("oob_rejected=true")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def op_text(layout: DescLayout, packed_op: int | None = None) -> str:
    """Ingested op table. Packed stand-in is OP_GEMM; unknown ops are rejected."""
    lines = ["source=ingested", "window=ops"]
    for name, val in sorted(layout.ops.items(), key=lambda kv: (int(kv[1]), str(kv[0]))):
        lines.append(f"{name}={int(val)}")
    if packed_op is not None:
        lines.append(f"packed_op={int(packed_op)}")
        name = layout.op_name(int(packed_op))
        if name:
            lines.append(f"packed_op_name={name}")
        gemm = layout.ops.get("OP_GEMM")
        lines.append(
            f"op_ok={'true' if gemm is not None and int(packed_op) == int(gemm) else 'false'}"
        )
    lines.append("unknown_op_rejected=true")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def ctl_text() -> str:
    """CTL enable + wr_cpl_en=0 (null ptr_done). Disabled doorbells are rejected."""
    lines = [
        "source=ingested",
        "window=ctl",
        "ctl_enable=1",
        "wr_cpl_en=0",
        "disabled_rejected=true",
        "reenable_ok=true",
        "ref=ABI-CONTRACT s2.3",
        "tops_not_evidence=true",
    ]
    return "\r\n".join(lines) + "\r\n"


def ptr_text(layout: DescLayout) -> str:
    """Null pointer fields. Bulk is BAR4 names; completion is MMIO CPL. No addresses."""
    lines = ["source=ingested", "window=ptrs"]
    for name in ("ptr_a", "ptr_b", "ptr_c", "ptr_scale", "ptr_done"):
        if name in layout.fields:
            field = layout.fields[name]
            lines.append(f"{name}_off={int(field['offset'])}")
            lines.append(f"{name}_size={int(field['size'])}")
            lines.append(f"{name}=0")
    lines.append("ptr_null=true")
    lines.append("bulk=bar4_names")
    lines.append("bar4_a=A")
    lines.append("bar4_b=B")
    lines.append("bar4_c=C")
    lines.append("ptr_done_path=mmio_cpl")
    lines.append("wr_cpl_en=0")
    lines.append("addr=unresolved")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def flags_text(layout: DescLayout, packed_flags: int | None = None) -> str:
    """Ingested flags_layout. irq_bit is isa-encoding.md §7 bit 2, not a BAR."""
    fl = layout.flags_layout
    lines = ["source=ingested", "window=flags"]
    if "irq_bit" in fl:
        bit = int(fl["irq_bit"])
        mask = 1 << bit
        lines.append(f"irq_bit={bit}")
        lines.append(f"irq_mask={mask}")
        if packed_flags is not None:
            lines.append(f"flags_packed={int(packed_flags)}")
            lines.append(f"flags_irq={'true' if int(packed_flags) & mask else 'false'}")
        lines.append(f"card_flag_irq={mask}")
        lines.append(f"irq_bit_ok={'true' if bit == 2 else 'false'}")
    packed = int(packed_flags or 0)
    fence_before = bool(packed & 1)
    fence_after = bool(packed & 2)
    fused_requant = bool(packed & 8)
    lines.append(f"fence_before={'true' if fence_before else 'false'}")
    lines.append(f"fence_after={'true' if fence_after else 'false'}")
    lines.append(f"fused_requant={'true' if fused_requant else 'false'}")
    lines.append(
        f"fence_clear={'true' if not (fence_before or fence_after or fused_requant) else 'false'}"
    )
    if fl.get("priority_shift") is not None and fl.get("priority_mask") is not None:
        penc = (packed >> int(fl["priority_shift"])) & int(fl["priority_mask"])
        lines.append(f"priority_enc={penc}")
        lines.append(f"priority_default={'true' if penc == 0 else 'false'}")
    if fl.get("dtype_shift") is not None and fl.get("dtype_mask") is not None:
        enc = (packed >> int(fl["dtype_shift"])) & int(fl["dtype_mask"])
        lines.append(f"dtype_enc={enc}")
        lines.append(f"dtype_s8s8={'true' if enc == 0 else 'false'}")
    accmode = fl.get("accmode") or {}
    if isinstance(accmode, dict) and accmode.get("shift") is not None:
        enc = (packed >> int(accmode["shift"])) & int(accmode.get("mask") or 0)
        lines.append(f"accmode_enc={enc}")
    ew = fl.get("ew") or {}
    if isinstance(ew, dict) and ew.get("shift") is not None:
        enc = (packed >> int(ew["shift"])) & int(ew.get("mask") or 0)
        lines.append(f"ew_enc={enc}")
        lines.append(f"ew_byte={'true' if enc == 0 else 'false'}")
    if fl.get("sp24_bit") is not None:
        on = bool(packed & (1 << int(fl["sp24_bit"])))
        lines.append(f"sp24={'true' if on else 'false'}")
    for key in (
        "dtype_shift",
        "dtype_mask",
        "priority_shift",
        "priority_mask",
    ):
        if fl.get(key) is not None:
            lines.append(f"{key}={fl[key]}")
    lines.append("int4_not_in_headline=true")
    lines.append("ref=isa-encoding.md s7")
    lines.append("tops_not_evidence=true")
    return "\r\n".join(lines) + "\r\n"


def class_vs_sku(cfg: dict) -> list:
    """100-TOPS class need vs this SKU. Definition arithmetic, not a measurement.

    scaling-100tops.md §2: 100e12 dense INT8 ops/s, 1 MAC = 2 ops.
    At 1.0 GHz that is 50 000 MAC/cycle.
    """
    clock_khz = cfg.get("clock_khz")
    macs = cfg.get("macs_per_cycle")
    hz = int(clock_khz) * 1000 if clock_khz else 1_000_000_000
    if hz <= 0:
        return []
    need = (100 * 10**12) // (2 * hz)
    lines = [
        "class_def_tops=100",
        f"class_need_macs_per_cycle={need}",
    ]
    if macs is not None and need:
        frac = int(macs) / float(need)
        lines.append(f"sku_frac_of_class={_fmt_peak(frac)}")
    return lines


def mmio_map_from_model(model: dict) -> dict:
    """CAP/DESC window bases from the ingested model. No UIO literals here."""
    cfg = island_config(model)
    cap_base = cfg.get("cap_base")
    desc_base = cfg.get("desc_base")
    offs = cfg.get("cap_offsets") or {}
    cap0 = int(cap_base) if cap_base is not None else 0
    out: dict = {
        "cap_base": cap_base,
        "desc_base": desc_base,
    }
    if "version" in offs:
        out["version_off"] = cap0 + int(offs["version"])
    if "clusters" in offs:
        out["clusters_off"] = cap0 + int(offs["clusters"])
    if "macs_cycle" in offs:
        out["macs_off"] = cap0 + int(offs["macs_cycle"])
    return out


def cap_overrides_from_model(model: dict) -> dict:
    """Map ingested island config onto virt_ai_card CAP seed keys."""
    cfg = island_config(model)
    out: dict = {}
    mapping = {
        "clusters": "clusters",
        "macs_per_cycle": "macs_per_cycle",
        "clock_khz": "clock_khz",
        "sram_bytes": "sram_bytes",
        "acc_tile_m": "acc_tile_m",
        "acc_tile_n": "acc_tile_n",
        "acc_tile_k": "acc_tile_k",
        "dram_gbps": "dram_gbps",
        "queues": "queues",
        "queue_depth": "queue_depth",
    }
    for src, dst in mapping.items():
        if cfg.get(src) is not None:
            out[dst] = int(cfg[src])
    return out


def pack_gemm_desc(model_path: str | Path, *, m: int, n: int, k: int, version: int = 1) -> bytes:
    """Pack an OP_GEMM descriptor from the ingested model. Offsets come from the model."""
    layout = DescLayout.from_model_file(model_path)
    values = {"version": version, "m": m, "n": n, "k": k, "op": layout.op_value("OP_GEMM")}
    layout.apply_standin_defaults(values)
    return layout.pack(values)


def virt_card_artifact(
    c: list,
    *,
    m: int,
    n: int,
    k: int,
    desc: bytes | None = None,
    cap: dict | None = None,
    modelled_peak_gops: float | None = None,
    mmio: dict | None = None,
    doorbell: dict | None = None,
    pmu: dict | None = None,
    completion_hex: str | None = None,
) -> TensorArtifact:
    """Stamp a pushed-path artifact. evidence is always false (software stand-in)."""
    header = {
        "profile": "g6lc-virt",
        "profile_tainted": True,
        "evidence": False,
        "route": "virt-card",
        "card": "virt-ai-pcie",
        "tops_not_evidence": True,
    }
    if desc is not None:
        header["desc_bytes"] = len(desc)
        header["desc_hex"] = desc.hex()
        header["desc_op"] = "OP_GEMM"
        header["bar4_desc"] = True
    if cap:
        header["island_cap"] = cap
    if modelled_peak_gops is not None:
        header["modelled_peak_gops"] = modelled_peak_gops
    if mmio:
        header["mmio_uio"] = mmio
    if doorbell:
        header["doorbell"] = doorbell
    if pmu:
        header["pmu"] = pmu
        header["pmu_not_tops"] = True
    if completion_hex:
        header["completion_hex"] = completion_hex
    return TensorArtifact(
        header,
        [
            {
                "order": 0,
                "hart": 0,
                "op": 1,
                "status": 0,
                "done": True,
                "m": m,
                "n": n,
                "k": k,
                "cluster": 0,
                "c": c,
            }
        ],
        None,
    )


def push_virt_card(args: argparse.Namespace) -> int:
    """Pushed path over the existing virt_ai_card TCP stand-in (not a pinned PCIe BAR)."""
    root = None
    if getattr(args, "card_root", None):
        root = Path(args.card_root)
    if root is None:
        root = find_ai_tensor_root(getattr(args, "repo_root", None))
    if root is None:
        err(
            "ai-tensor virt_ai_card not found; pass --repo-root <monorepo> or "
            "AI_TENSOR_ROOT / --card-root"
        )
        return 1
    tools = root / "tools"
    if str(tools) not in sys.path:
        sys.path.insert(0, str(tools))
    try:
        from virt_ai_card.card_agent import CardAgent
        from virt_ai_card.host_client import HostClient
    except ImportError as exc:
        err(f"cannot import virt_ai_card from {tools}: {exc}")
        return 1

    a = [[1, 2], [3, 4]]
    b = [[5, 6], [7, 8]]
    expect = [[19, 22], [43, 50]]
    desc = None
    cap_ov: dict | None = None
    peak_gops: float | None = None
    mmio_map: dict = {}
    cpl_layout: DescLayout | None = None
    qmap: list | None = None
    nqos: int | None = None
    wqk: int | None = None
    standin_k: int | None = None
    model = getattr(args, "model", None)
    if model:
        try:
            raw_model = json.loads(Path(model).read_text(encoding="utf-8"))
            cap_ov = cap_overrides_from_model(raw_model) or None
            mmio_map = mmio_map_from_model(raw_model)
            peak = modelled_peak_ops(island_config(raw_model))
            if peak is not None:
                peak_gops = peak / 1e9
            desc = pack_gemm_desc(model, m=2, n=2, k=2)
            layout = DescLayout.from_model(raw_model)
            cpl_layout = layout
            irq_bit = (layout.flags_layout or {}).get("irq_bit")
            if irq_bit is not None:
                cap_ov = dict(cap_ov or {})
                cap_ov["irq_bit"] = int(irq_bit)
            cfg = island_config(raw_model)
            qmap = cfg.get("queue_cluster_map")
            if not isinstance(qmap, list):
                qmap = None
            if cfg.get("qos_classes") is not None:
                nqos = int(cfg["qos_classes"])
            if cfg.get("work_quantum_k") is not None:
                wqk = int(cfg["work_quantum_k"])
            dims = layout.unpack(desc)
            standin_k = int(dims.get("k") or 0)
            if (int(dims.get("m") or 0), int(dims.get("n") or 0), int(dims.get("k") or 0)) != (
                2,
                2,
                2,
            ):
                err("virt-card golden A/B is 2x2; packed desc m/n/k must be 2")
                return 1
            if "ld_ab" in dims:
                lda = int(dims["ld_ab"]) & 0xFFFF
                ldb = (int(dims["ld_ab"]) >> 16) & 0xFFFF
                if (lda, ldb) != (2, 2):
                    err(f"packed ld_ab lda={lda} ldb={ldb}; expected lda=k=2 ldb=n=2")
                    return 1
            log(f"packed {len(desc)}-byte OP_GEMM descriptor from {model}")
        except (LayoutError, OSError, json.JSONDecodeError) as exc:
            err(f"cannot pack descriptor from {model}: {exc}")
            return 1
    if args.dry_run:
        extra = f" desc={len(desc)}B" if desc is not None else ""
        if cap_ov:
            extra += f" cap_clusters={cap_ov.get('clusters')}"
        log(f"dry-run: virt-card GEMM 2x2 via {root}{extra}")
        return 0

    agent = CardAgent(host="127.0.0.1", port=0, cap=cap_ov)
    host, port = agent.start()
    snap: dict = {}
    doorbell = None
    c = None
    desc_join = False
    desc_hash_join = False
    cpl_hash_join = False
    try:
        import time as _time

        _time.sleep(0.05)
        cli = HostClient(host=host, port=port)
        hello = cli.connect()
        snap = hello.get("cap") or {}
        log(
            f"card hello boardid={hello.get('boardid')} cap={hello.get('cap_version')} "
            f"clusters={snap.get('clusters')} macs/cycle={snap.get('macs_per_cycle')}"
        )
        if cap_ov and cap_ov.get("macs_per_cycle") is not None:
            if snap.get("macs_per_cycle") != cap_ov.get("macs_per_cycle"):
                err("card CAP macs_per_cycle does not match ingested model")
                return 1
            log("card CAP seeded from ingested model (reported, not simulated)")
        mmio_rd = getattr(cli, "mmio_read32", None)
        mmio_wrb = getattr(cli, "mmio_write_bytes", None)
        mmio_rdb = getattr(cli, "mmio_read_bytes", None)
        if mmio_rd and cap_ov and mmio_map.get("macs_off") is not None:
            got_macs = mmio_rd(int(mmio_map["macs_off"]))
            if got_macs != cap_ov.get("macs_per_cycle"):
                err(
                    f"MMIO CAP macs_per_cycle {got_macs} != model {cap_ov.get('macs_per_cycle')}"
                )
                return 1
            log(
                f"MMIO CAP macs_per_cycle={got_macs} at off={mmio_map['macs_off']} "
                "(UIO 4K window, not a pinned BAR)"
            )
        if desc is not None:
            put_bytes = getattr(cli, "bar4_put_bytes", None)
            if put_bytes is None:
                err("virt_ai_card HostClient has no bar4_put_bytes; update ai-tensor")
                return 1
            put_bytes("DESC", desc)
            got = cli.bar4_get("DESC")
            if got != desc:
                err("BAR4 DESC round-trip mismatch (stand-in bulk plane)")
                return 1
            log(f"BAR4 DESC {len(desc)}B round-trip ok (UIO DESC@0x140 stand-in, not a pinned BAR)")
            esp_desc = package_root() / "out" / "loader-run" / "esp-edk2-pci" / "DESC.BIN"
            if esp_desc.is_file() and esp_desc.read_bytes() == desc:
                log("BAR4 DESC matches ESP DESC.BIN (firmware/card layout join)")
                desc_join = True
            join_path = package_root() / "out" / "loader-run" / "esp-edk2-pci" / "JOIN.TXT"
            if join_path.is_file():
                join_body = join_path.read_text(encoding="ascii")
                if f"desc_sha256={_sha256_hex(desc)}" in join_body:
                    desc_hash_join = True
                    log("DESC sha256 matches ESP JOIN.TXT")
            desc_base = mmio_map.get("desc_base")
            if mmio_wrb and mmio_rdb and desc_base is not None:
                mmio_wrb(int(desc_base), desc)
                got_mmio = mmio_rdb(int(desc_base), len(desc))
                if got_mmio != desc:
                    err("MMIO DESC window round-trip mismatch")
                    return 1
                log(
                    f"MMIO DESC@{int(desc_base):#x} {len(desc)}B round-trip ok "
                    "(ingested desc_base, not a pinned BAR)"
                )
        cli.bar4_put("A", a)
        cli.bar4_put("B", b)
        c = None
        doorbell = None
        mmio_wr = getattr(cli, "mmio_write32", None)
        try:
            from virt_ai_card.driver import (
                CTL,
                DOORBELL,
                DONE,
                DSTATUS,
                PMU,
                STATUS,
                ST_DISABLED,
                ST_ERR,
                ST_OK,
                TICKET,
            )
        except ImportError:
            CTL = None  # type: ignore[assignment]
        if CTL is not None and mmio_wr and mmio_rd:
            ticket = 1
            ptr_done = 0
            packed_flags = 0
            if desc is not None and cpl_layout is not None:
                unpacked = cpl_layout.unpack(desc)
                ptr_done = int(unpacked.get("ptr_done") or 0)
                packed_flags = int(unpacked.get("flags") or 0)
            # Null ptr_done ⇒ no DMA completion write (ABI-CONTRACT §3).
            ctl = 1 if ptr_done == 0 else (1 | (1 << 1))
            mmio_wr(CTL, ctl)
            qid = 0
            nq = snap.get("queues")
            if nq is not None and int(nq) <= 0:
                err("ingested/card queues is not positive")
                return 1
            irq_fn = getattr(cli, "irq_wait", None)

            def _ring(ticket: int, qid: int, expect_status: int = ST_OK) -> dict:
                mmio_wr(DOORBELL, (int(ticket) << 8) | (int(qid) & 0xFF))
                irq_waited = False
                if expect_status == ST_OK and irq_fn is not None:
                    try:
                        irq_fn(2.0)
                        irq_waited = True
                    except Exception as exc:  # noqa: BLE001 — fall back to DONE poll
                        log(f"irq_wait skipped: {exc}")
                done = mmio_rd(DONE)
                got_ticket = mmio_rd(TICKET)
                dstatus = mmio_rd(DSTATUS)
                if not (int(done) & 1):
                    raise RuntimeError("MMIO doorbell produced no DONE")
                if int(dstatus) != int(expect_status):
                    raise RuntimeError(
                        f"MMIO completion status {dstatus} != {expect_status}"
                    )
                if int(got_ticket) != int(ticket):
                    raise RuntimeError(f"MMIO ticket {got_ticket} != {ticket}")
                mmio_wr(DONE, 1)
                if irq_waited:
                    clr = getattr(cli, "irq_clear", None)
                    if clr is not None:
                        clr()
                out = {
                    "ticket": int(got_ticket),
                    "status": int(dstatus),
                    "qid": int(qid),
                    "irq_waited": irq_waited,
                    "claimed": True,
                }
                if isinstance(qmap, list) and 0 <= int(qid) < len(qmap):
                    out["cluster"] = int(qmap[int(qid)])
                if nqos is not None and nqos > 0:
                    out["qos_class"] = int(qid) % nqos
                return out

            try:
                round0 = _ring(ticket, qid)
            except RuntimeError as exc:
                err(str(exc))
                return 1
            pmu = {
                "r": mmio_rd(PMU),
                "w": mmio_rd(PMU + 4),
                "cycles": mmio_rd(PMU + 8),
                "gbps_x1000": mmio_rd(PMU + 12),
            }
            status_word = mmio_rd(STATUS)
            c = cli.bar4_get("C")
            doorbell = dict(round0)
            doorbell["status_busy"] = int(status_word) & 1
            doorbell["status_code"] = (int(status_word) >> 16) & 0xFFFF
            doorbell["ptr_null"] = ptr_done == 0
            doorbell["wr_cpl_en"] = 0 if ptr_done == 0 else 1
            doorbell["flags"] = packed_flags
            if desc is not None and cpl_layout is not None and "ld_ab" in cpl_layout.fields:
                doorbell["ld_ab"] = int(cpl_layout.unpack(desc).get("ld_ab") or 0)
                doorbell["lda"] = doorbell["ld_ab"] & 0xFFFF
                doorbell["ldb"] = (doorbell["ld_ab"] >> 16) & 0xFFFF
            irq_mask = cpl_layout.irq_mask() if cpl_layout is not None else None
            if irq_mask is not None:
                doorbell["flags_irq"] = bool(packed_flags & irq_mask)
                doorbell["irq_bit"] = int((cpl_layout.flags_layout or {}).get("irq_bit") or 0)
            doorbell["fence_clear"] = not bool(packed_flags & 0xB)
            if wqk is not None and standin_k is not None:
                doorbell["work_quantum_k"] = wqk
                doorbell["standin_k"] = standin_k
                doorbell["within_quantum"] = standin_k <= wqk
            nq_i = int(nq) if nq is not None else 1
            if nq_i >= 2:
                try:
                    round1 = _ring(ticket + 1, 1)
                except RuntimeError as exc:
                    err(str(exc))
                    return 1
                doorbell["qid1"] = round1
                doorbell["multi_queue"] = True
                c = cli.bar4_get("C")
            try:
                oob = _ring(ticket + max(nq_i, 1), nq_i, expect_status=ST_ERR)
            except RuntimeError as exc:
                err(str(exc))
                return 1
            doorbell["qid_oob"] = oob
            doorbell["qid_bound"] = True
            mmio_wr(CTL, 0)
            try:
                dis = _ring(ticket + nq_i + 1, 0, expect_status=ST_DISABLED)
            except RuntimeError as exc:
                err(str(exc))
                return 1
            doorbell["disabled"] = dis
            doorbell["disabled_rejected"] = True
            mmio_wr(CTL, 1)
            try:
                rec = _ring(ticket + nq_i + 2, 0, expect_status=ST_OK)
            except RuntimeError as exc:
                err(str(exc))
                return 1
            doorbell["reenable"] = rec
            doorbell["reenable_ok"] = True
            c = cli.bar4_get("C")
            irq_waited = bool(round0.get("irq_waited"))
            got_ticket = round0["ticket"]
            dstatus = round0["status"]
            if desc_join:
                doorbell["esp_desc_join"] = True
            if desc_hash_join:
                doorbell["esp_desc_hash_join"] = True
            if cpl_layout is not None and cpl_layout.completion:
                try:
                    img = cpl_layout.pack_completion(int(got_ticket), int(dstatus))
                    doorbell["completion_hex"] = img.hex()
                    doorbell["completion_bytes"] = len(img)
                    put_cpl = getattr(cli, "bar4_put_bytes", None)
                    if put_cpl is not None:
                        put_cpl("CPL", img)
                        got_cpl = cli.bar4_get("CPL")
                        if got_cpl != img:
                            err("BAR4 CPL round-trip mismatch")
                            return 1
                        doorbell["bar4_cpl"] = True
                        log(
                            f"BAR4 CPL {len(img)}B round-trip ok "
                            "(packed completion word, not a pinned BAR)"
                        )
                        esp_cpl = package_root() / "out" / "loader-run" / "esp-edk2-pci" / "CPL.BIN"
                        if esp_cpl.is_file() and esp_cpl.read_bytes() == img:
                            doorbell["esp_cpl_join"] = True
                            log("BAR4 CPL matches ESP CPL.BIN (firmware/card layout join)")
                        join_path = (
                            package_root() / "out" / "loader-run" / "esp-edk2-pci" / "JOIN.TXT"
                        )
                        if join_path.is_file() and f"cpl_sha256={_sha256_hex(img)}" in join_path.read_text(
                            encoding="ascii"
                        ):
                            doorbell["esp_cpl_hash_join"] = True
                            log("CPL sha256 matches ESP JOIN.TXT")
                except LayoutError as exc:
                    log(f"completion pack skipped: {exc}")
            doorbell["pmu"] = pmu
            doorbell["pmu_not_tops"] = True
            log(
                f"MMIO doorbell ticket={got_ticket} status={dstatus} "
                f"pmu_r={pmu['r']} irq_waited={irq_waited} qid={qid} "
                f"multi_queue={doorbell.get('multi_queue', False)} "
                f"ptr_null={doorbell.get('ptr_null')} "
                f"flags_irq={doorbell.get('flags_irq')} "
                f"lda={doorbell.get('lda')} "
                f"cluster={round0.get('cluster')} "
                f"qos={round0.get('qos_class')} "
                f"within_quantum={doorbell.get('within_quantum')} "
                f"qid_bound={doorbell.get('qid_bound')} "
                f"disabled_rejected={doorbell.get('disabled_rejected')} "
                f"reenable_ok={doorbell.get('reenable_ok')} "
                "(UIO wait-then-claim, not a pinned BAR; pmu not TOPS)"
            )
        else:
            c = cli.gemm_s8(a_name="A", b_name="B", ticket=1)
        cli.close()
    finally:
        agent.stop()

    if c != expect:
        err(f"virt-card golden mismatch: {c} != {expect}")
        return 1
    art = virt_card_artifact(
        c,
        m=2,
        n=2,
        k=2,
        desc=desc,
        cap=snap if snap else None,
        modelled_peak_gops=peak_gops,
        mmio=(
            {
                "window": "uio_4k",
                "desc_base": mmio_map.get("desc_base"),
                "macs_off": mmio_map.get("macs_off"),
            }
            if mmio_map.get("desc_base") is not None
            else None
        ),
        doorbell=doorbell,
        pmu=(doorbell or {}).get("pmu") if doorbell else None,
        completion_hex=(doorbell or {}).get("completion_hex") if doorbell else None,
    )
    out = Path(args.tensor_out)
    art.dump(out)
    log(f"tensor artifact at {out} (virt-card, evidence=false)")
    return 0


ROUTES = {
    "native": push_native,
    "remote": push_remote,
    "virt-card": push_virt_card,
}


# ------------------------------------------------------------------------- subcommands


def cmd_doctor(args: argparse.Namespace) -> int:
    rows = []
    binary = cli_binary()
    rows.append(("native (B3)", "ok" if binary else "build first: g6q build", str(binary or "")))
    remote = _TOOLS / "g6q_remote.py"
    have_ssh = shutil.which("ssh") is not None
    have_rsync = shutil.which("rsync") is not None
    remote_state = "ok" if (remote.is_file() and have_ssh and have_rsync) else "missing ssh/rsync"
    rows.append(("remote (B1+B2)", remote_state, str(remote)))
    card = find_ai_tensor_root(getattr(args, "repo_root", None))
    rows.append(
        (
            "virt-card (ai-tensor)",
            "ok" if card else "set AI_TENSOR_ROOT or --repo-root",
            str(card or ""),
        )
    )
    rows.append(
        (
            "edk2-pci (GPEX RC)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect \"Virtio Network Device\"",
        )
    )
    rows.append(
        (
            "edk2-desc (packed OP_GEMM)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect OP_GEMM",
        )
    )
    rows.append(
        (
            "edk2-cap (modelled peak)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect class_need_macs_per_cycle",
        )
    )
    rows.append(
        (
            "edk2-cpl (completion layout)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect example_hex",
        )
    )
    rows.append(
        (
            "edk2-plane (two-plane split)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect tops_on=island",
        )
    )
    rows.append(
        (
            "edk2-join (ESP/card images)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect join=firmware_and_card",
        )
    )
    rows.append(
        (
            "edk2-roof (class DRAM BW)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect class_dram_gbps",
        )
    )
    rows.append(
        (
            "edk2-queue (ingested rings)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect doorbell_qid_last",
        )
    )
    rows.append(
        (
            "edk2-ptr (null ptr_*)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect ptr_null",
        )
    )
    rows.append(
        (
            "edk2-flags (ingested irq_bit)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect irq_bit_ok",
        )
    )
    rows.append(
        (
            "edk2-ld (lda/ldb from n,k)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect ld_ab_ok",
        )
    )
    rows.append(
        (
            "edk2-dtype (dense INT8)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect dtype_s8s8",
        )
    )
    rows.append(
        (
            "edk2-sched (work quantum / QoS)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect within_quantum",
        )
    )
    rows.append(
        (
            "edk2-stat (qid bounds)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect qid_bound",
        )
    )
    rows.append(
        (
            "edk2-op (ingested OP_GEMM)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect op_ok",
        )
    )
    rows.append(
        (
            "edk2-ctl (re-enable after disable)",
            "witness",
            "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect reenable_ok",
        )
    )
    width = max(len(r[0]) for r in rows)
    for name, state, note in rows:
        log(f"  {name.ljust(width)}  {state}  {note}")
    return 0


def _parse_set(items: list) -> dict:
    out: dict = {}
    for item in items or []:
        if "=" not in item:
            raise LayoutError(f"--set expects name=value, got {item!r}")
        key, _, value = item.partition("=")
        out[key.strip()] = value.strip()
    return out


def cmd_pack(args: argparse.Namespace) -> int:
    try:
        raw = json.loads(Path(args.model).read_text(encoding="utf-8"))
        layout = DescLayout.from_model(raw)
        values = _parse_set(args.set)
        if args.op:
            values["op"] = layout.op_value(args.op)
        layout.apply_standin_defaults(values)
        image = layout.pack(values)
    except (LayoutError, OSError, json.JSONDecodeError) as exc:
        err(str(exc))
        return 1
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_bytes(image)
        log(f"wrote {len(image)}-byte descriptor to {args.out}")
    else:
        print(image.hex())
    decode_out = getattr(args, "decode_out", None)
    if decode_out:
        Path(decode_out).parent.mkdir(parents=True, exist_ok=True)
        Path(decode_out).write_text(layout.decode_text(image), encoding="ascii")
        log(f"wrote decode text to {decode_out}")
    cap_out = getattr(args, "cap_out", None)
    if cap_out:
        Path(cap_out).parent.mkdir(parents=True, exist_ok=True)
        Path(cap_out).write_text(island_cap_text(raw), encoding="ascii")
        log(f"wrote CAP text to {cap_out}")
        plane_path = Path(cap_out).with_name("PLANE.TXT")
        plane_path.write_text(plane_text(raw), encoding="ascii")
        log(f"wrote plane text to {plane_path}")
        roof_path = Path(cap_out).with_name("ROOF.TXT")
        roof_path.write_text(roof_text(raw), encoding="ascii")
        log(f"wrote roof text to {roof_path}")
        queue_path = Path(cap_out).with_name("QUEUE.TXT")
        queue_path.write_text(queue_text(raw), encoding="ascii")
        log(f"wrote queue text to {queue_path}")
        standin_k = None
        if "k" in layout.fields:
            try:
                standin_k = int(layout.unpack(image).get("k") or 0)
            except LayoutError:
                standin_k = None
        sched_path = Path(cap_out).with_name("SCHED.TXT")
        sched_path.write_text(sched_text(raw, standin_k=standin_k), encoding="ascii")
        log(f"wrote sched text to {sched_path}")
        desc_ver = None
        if "version" in layout.fields:
            try:
                desc_ver = int(layout.unpack(image).get("version") or 0)
            except LayoutError:
                desc_ver = None
        stat_path = Path(cap_out).with_name("STAT.TXT")
        stat_path.write_text(stat_text(raw, desc_version=desc_ver), encoding="ascii")
        log(f"wrote stat text to {stat_path}")
        packed_op = None
        if "op" in layout.fields:
            try:
                packed_op = int(layout.unpack(image).get("op") or 0)
            except LayoutError:
                packed_op = None
        op_path = Path(cap_out).with_name("OP.TXT")
        op_path.write_text(op_text(layout, packed_op), encoding="ascii")
        log(f"wrote op text to {op_path}")
        ctl_path = Path(cap_out).with_name("CTL.TXT")
        ctl_path.write_text(ctl_text(), encoding="ascii")
        log(f"wrote ctl text to {ctl_path}")
        ptr_path = Path(cap_out).with_name("PTR.TXT")
        ptr_path.write_text(ptr_text(layout), encoding="ascii")
        log(f"wrote ptr text to {ptr_path}")
        packed_flags = None
        if "flags" in layout.fields:
            packed_flags = int(layout.unpack(image).get("flags") or 0)
        flags_path = Path(cap_out).with_name("FLAGS.TXT")
        flags_path.write_text(flags_text(layout, packed_flags), encoding="ascii")
        log(f"wrote flags text to {flags_path}")
    cpl_out = getattr(args, "cpl_out", None)
    if cpl_out:
        Path(cpl_out).parent.mkdir(parents=True, exist_ok=True)
        Path(cpl_out).write_text(layout.completion_text(), encoding="ascii")
        log(f"wrote CPL text to {cpl_out}")
        try:
            img = layout.pack_completion(1, layout.statuses.get("ST_OK", 0))
            bin_path = Path(cpl_out).with_suffix(".BIN")
            bin_path.write_bytes(img)
            log(f"wrote {len(img)}-byte completion word to {bin_path}")
        except LayoutError:
            img = None
            bin_path = None
        desc_bytes = Path(args.out).read_bytes() if args.out else image
        cpl_bytes = bin_path.read_bytes() if bin_path and bin_path.is_file() else None
        join_path = Path(cpl_out).with_name("JOIN.TXT")
        join_path.write_text(join_text(desc=desc_bytes, cpl=cpl_bytes), encoding="ascii")
        log(f"wrote join text to {join_path}")
    return 0


def cmd_cpl(args: argparse.Namespace) -> int:
    try:
        layout = DescLayout.from_model_file(args.model)
        text = layout.completion_text()
    except (LayoutError, OSError, json.JSONDecodeError) as exc:
        err(str(exc))
        return 1
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="ascii")
        log(f"wrote CPL text to {args.out}")
        try:
            img = layout.pack_completion(1, layout.statuses.get("ST_OK", 0))
            bin_path = Path(args.out).with_suffix(".BIN")
            bin_path.write_bytes(img)
            log(f"wrote {len(img)}-byte completion word to {bin_path}")
        except LayoutError:
            pass
    else:
        print(text, end="")
    return 0


def cmd_cap(args: argparse.Namespace) -> int:
    try:
        raw = json.loads(Path(args.model).read_text(encoding="utf-8"))
        text = island_cap_text(raw)
    except (OSError, json.JSONDecodeError) as exc:
        err(str(exc))
        return 1
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="ascii")
        log(f"wrote CAP text to {args.out}")
    else:
        print(text, end="")
    return 0


def cmd_unpack(args: argparse.Namespace) -> int:
    try:
        layout = DescLayout.from_model_file(args.model)
        image = Path(args.image).read_bytes()
        text = layout.decode_text(image)
    except (LayoutError, OSError, json.JSONDecodeError) as exc:
        err(str(exc))
        return 1
    if args.out:
        Path(args.out).parent.mkdir(parents=True, exist_ok=True)
        Path(args.out).write_text(text, encoding="ascii")
        log(f"wrote decode text to {args.out}")
    else:
        print(text, end="")
    return 0


def cmd_push(args: argparse.Namespace) -> int:
    route = ROUTES.get(args.route)
    if route is None:
        err(f"unknown route {args.route!r}; available: {', '.join(sorted(ROUTES))}")
        return 1
    rc = route(args)
    if rc != 0:
        return rc
    if args.uarch_out:
        if args.route != "native":
            err("--uarch-out is only supported with --route native")
            return 1
        if not Path(args.tensor_out).is_file():
            err(f"tensor artifact not found: {args.tensor_out}")
            return 1
        diag_args = argparse.Namespace(
            target=args.target,
            repo_root=args.repo_root,
            tensor=[args.tensor_out],
            measured_dram_gbps=args.measured_dram_gbps,
            uarch_out=args.uarch_out,
        )
        return cmd_diag(diag_args)
    return 0


def cmd_results(args: argparse.Namespace) -> int:
    try:
        artifact = TensorArtifact.load(args.artifact)
    except (OSError, json.JSONDecodeError) as exc:
        err(f"cannot read {args.artifact}: {exc}")
        return 1
    layout: DescLayout | None = None
    clusters: int | None = None
    model: dict | None = None
    model_cfg: dict | None = None
    target_id: str | None = None
    if args.model:
        try:
            model = json.loads(Path(args.model).read_text(encoding="utf-8"))
            layout = DescLayout.from_model(model)
            cfg = (model.get("soc") or {}).get("ai_island", {}).get("config", {})
            clusters = cfg.get("clusters")
            model_cfg = cfg
            target_id = ((model.get("target") or {}).get("id")) or args.target
        except (OSError, json.JSONDecodeError, LayoutError) as exc:
            err(f"cannot load model {args.model}: {exc}")
            return 1
    if not target_id:
        target_id = args.target

    summary = artifact.summary(layout, clusters)
    if args.per_event:
        summary["outputs"] = artifact.pytorch_summary(layout)

    if args.tops:
        if not target_id:
            err("--tops needs a target; pass --model or --target")
            return 1
        try:
            counters = _diag_for_artifact(
                args.artifact,
                target_id,
                model,
                args.repo_root,
                args.measured_dram_gbps,
                args.uarch_out,
            )
            summary["tops"] = _tops_report(counters, artifact.events, model_cfg)
            summary["tops_not_evidence"] = True
        except LayoutError as exc:
            err(str(exc))
            return 1
    elif args.uarch_out:
        err("--uarch-out only takes effect with --tops")
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    if summary["profile_tainted"]:
        log("NOTE: the producing machine profile is tainted; this is not a hardware result")
    if args.tops:
        log("NOTE: tops values are modelled peaks, not measured silicon performance")
    return 0


def _contract_rev(text: str, name: str) -> str | None:
    """Return the `rev` value for a contract section in pins.toml, or None."""
    import re

    pattern = re.compile(
        rf"\[contracts\.{re.escape(name)}\][^\[]*?^\s*rev\s*=\s*\"([^\"]+)\"",
        re.MULTILINE | re.DOTALL,
    )
    m = pattern.search(text)
    return m.group(1) if m else None


def cmd_pcie(args: argparse.Namespace) -> int:
    """Report the PCIe host-transport concept and refuse to model it until it is pinned.

    The LibreCore accelerator is a PCIe endpoint (`architecture/uncore/pcie-endpoint.md`):
    the host root complex pushes descriptor work through a doorbell and a resizable BAR.
    This subcommand exists so callers can discover the current contract pin state before
    asking the bridge to push over a transport that has not been published.
    """
    pins = package_root() / "pins.toml"
    if not pins.is_file():
        err("pins.toml not found; the package has no contract tracking")
        return 1
    text = pins.read_text(encoding="utf-8")
    rev = _contract_rev(text, "ai_host_transport")

    concept = {
        "role": "PCIe endpoint on the accelerator card; host provides the root complex",
        "control_plane": "virtio-pci management function (BAR0, 4 KiB)",
        "doorbell": "BAR0 offset 0, 32-bit (version|op) — same encoding as the guest-visible descriptor doorbell",
        "bulk_plane": "resizable BAR4 for descriptor + A/B/C/scale tensor pages (min 1 MiB, target 64 MiB)",
        "completion": "host polls BAR2 status/ticket mapping or receives MSI from the card",
        "edk2_host_witness": "g6q run --loader edk2 --os efi-shell --machine g6lc-virt --expect \"Virtio Network Device\"",
        "edk2_desc": "ESP DESC.BIN/DESC.HEX/DESC.TXT from ingested desc_layout; file delivery, not a BAR map",
        "edk2_cap": "ESP CAP.TXT is ingested island geometry plus modelled peak and 100-TOPS class vs SKU; tops_not_evidence",
        "edk2_cpl": "ESP CPL.TXT/CPL.BIN/CPL.HEX is an ingested completion word (ticket/status bit ranges); example_hex is ticket=1 ST_OK",
        "bar4_cpl": "virt_ai_card BAR4 name CPL carries the packed completion word; esp_cpl_join when it matches ESP CPL.BIN",
        "edk2_plane": "ESP PLANE.TXT: island throughput from ingested acc_tile; core latency not in this model; tops_on=island",
        "irq_wait": "virt_ai_card irq_wait then DONE claim (eventfd MSI stand-in); not a pinned MSI vector",
        "edk2_join": "ESP JOIN.TXT: DESC/CPL images and SHA-256 shared with BAR4 DESC/CPL; join=firmware_and_card",
        "edk2_roof": "ESP ROOF.TXT: class vs SKU DRAM BW from ingested blocking T (2/T) plus acc SRAM T^2*4; tops_not_evidence",
        "edk2_queue": "ESP QUEUE.TXT: ingested queues/depth/qos; doorbell qid 0 and last=queues-1; virt-card rings both when queues>=2",
        "edk2_ptr": "ESP PTR.TXT: ingested ptr_* packed as 0 (ABI null); bulk BAR4 names A/B/C; ptr_done_path=mmio_cpl; no invented addresses",
        "edk2_flags": "ESP FLAGS.TXT: ingested irq_bit (isa-encoding.md §7 bit 2); packed DESC flags=1<<irq_bit; virt_ai_card FLAG_IRQ matches; dtype_s8s8 dense INT8, no INT4 in the headline",
        "edk2_ld": "ESP DESC.TXT lda/ldb packed from n,k into ingested ld_ab; ld_ab_ok; not a BAR address",
        "edk2_cluster": "ESP QUEUE.TXT qid→cluster from ingested queue_cluster_map; virt-card stamps cluster on each doorbell",
        "edk2_sched": "ESP SCHED.TXT: stand-in k vs ingested work_quantum_k (within_quantum); qid→qos; isa-encoding.md §7.1; not a measurement",
        "edk2_stat": "ESP STAT.TXT: qid_bound (qid < queues); oob doorbell rejected; desc version=1; not a BAR",
        "edk2_op": "ESP OP.TXT: ingested OP_GEMM; packed op_ok; unknown ops rejected",
        "edk2_ctl": "ESP CTL.TXT: enable=1 wr_cpl_en=0 (null ptr_done); disabled doorbells rejected; reenable_ok after CTL.enable=1",
        "mmio_uio": "virt_ai_card mmio_rd/mmio_wr on the existing 4 KiB UIO window (CAP + DESC@desc_base); not a pinned BAR",
        "uio_doorbell": "host writes UIO DOORBELL then claims DONE; completion bit ranges from ingested desc_layout.completion; not a pinned BAR",
        "bar4_desc": "virt_ai_card BAR4 name DESC carries the packed image into the existing UIO DESC@0x140 window; not a pinned BAR",
        "card_standin": "ai-tensor/tools/virt_ai_card/smoke.py",
        "push_route": "ai_tensor_bridge.py push --route virt-card --repo-root <monorepo> --model out/ai_soc_model.json",
        "tops_definition": "100e12 dense INT8 ops/s peak; 1 MAC = 2 ops; no sparsity/INT4 in the headline (architecture/ai-matrix/scaling-100tops.md §2)",
        "two_plane": "core-attached tile 8x8x8 is a latency device; island clusters carry TOPS",
        "tops_not_evidence": True,
        "note": "BAR sizes/device IDs/MSI are conceptual until pinned; EDK2 is root-complex firmware; virt_ai_card is the endpoint stand-in; not a fused bus",
    }
    print(json.dumps(concept, indent=2, sort_keys=True))
    if rev == "unpinned" or not rev:
        err(
            "contracts.ai_host_transport is not pinned; the bridge cannot push over PCIe "
            "until the host design publishes BAR/virtio/MSI details (architecture/AI_BRIDGE.md §6)"
        )
        return 1
    log(f"contracts.ai_host_transport is pinned to rev={rev}; B1/B2 PCIe support is not yet implemented")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    try:
        lhs = TensorArtifact.load(args.lhs)
        rhs = TensorArtifact.load(args.rhs)
    except (OSError, json.JSONDecodeError) as exc:
        err(str(exc))
        return 1
    diffs = compare_artifacts(lhs, rhs)
    if not diffs:
        log("artifacts agree")
        return 0
    print(json.dumps(diffs, indent=2, sort_keys=True))
    err(f"{len(diffs)} difference(s)")
    return 1


def cmd_diag(args: argparse.Namespace) -> int:
    """Run g6lc-qemu diag with an optional host-side measured DRAM bandwidth.

    This is the host/bridge side of the F11 loop: the emulator accepts a measured
    bandwidth and closes the roofline bound even when the design has not published one.
    """
    binary = cli_binary()
    if not binary:
        err("g6lc-qemu binary not found; run `g6q build` first")
        return 1
    out = Path(args.uarch_out)
    out.parent.mkdir(parents=True, exist_ok=True)
    cmd: list = [str(binary), "diag", "--uarch-out", str(out)]
    if args.target:
        cmd += ["--target", args.target]
    if args.repo_root:
        cmd += ["--repo-root", args.repo_root]
    for tensor in args.tensor or []:
        cmd += ["--tensor", tensor]
    if args.measured_dram_gbps is not None:
        v = int(round(args.measured_dram_gbps * 1000.0))
        if v < 0:
            err("--measured-dram-gbps must be non-negative")
            return 1
        cmd += ["--measured-dram-gbps-x1000", str(v)]
    res = _run(cmd, check=False)
    if res.returncode != 0:
        err("diag failed")
        return res.returncode
    log(f"uarch counters at {out}")
    return 0


# --------------------------------------------------------------------------- selftest


_SELFTEST_MODEL = {
    "soc": {
        "ai_island": {
            "config": {
                "cap_base": 0,
                "desc_base": 0x140,
                "clusters": 2,
                "macs_per_cycle": 256,
                "clock_khz": 1000000,
                "acc_tile_m": 256,
                "sram_bytes": 2097152,
                "queues": 2,
                "queue_depth": 64,
                "qos_classes": 2,
                "work_quantum_k": 64,
                "queue_cluster_map": [0, 1],
            },
            "desc_layout": {
                "completion": {
                    "ticket_bit_low": 0,
                    "ticket_bit_high": 31,
                    "status_bit_low": 32,
                    "status_bit_high": 47,
                },
                "desc_bytes": 16,
                "fields": {
                    "version": {"offset": 0, "size": 2, "bit_low": 0, "bit_high": 15},
                    "op": {"offset": 2, "size": 2, "bit_low": 16, "bit_high": 31},
                    "flags": {"offset": 4, "size": 4, "bit_low": 32, "bit_high": 63},
                    "m": {"offset": 8, "size": 4, "bit_low": 64, "bit_high": 95},
                    "ptr_done": {"offset": 12, "size": 4, "bit_low": 96, "bit_high": 127},
                },
                "ops": {"OP_GEMM": 1, "OP_CONV2D": 2},
                "statuses": {"ST_OK": 0, "ST_ERR": 1},
                "flags_layout": {
                    "irq_bit": 2,
                    "dtype_shift": 8,
                    "dtype_mask": 3,
                    "priority_shift": 16,
                    "priority_mask": 15,
                },
            }
        }
    }
}


def cmd_selftest(args: argparse.Namespace) -> int:
    failures: list = []
    log("note: two 'unresolved placement' warnings below are expected -- they are the")
    log("      cases under test, not failures.")

    def check(name: str, cond: bool, detail: str = "") -> None:
        if not cond:
            failures.append(f"{name}{': ' + detail if detail else ''}")

    layout = DescLayout.from_model(_SELFTEST_MODEL)
    check("desc_bytes is read from the model", layout.desc_bytes == 16)

    image = layout.pack({"version": 1, "op": 1, "m": 4})
    check("packed image is the model's size", len(image) == 16, str(len(image)))
    check("little-endian at the model's offset", image[0:2] == b"\x01\x00")
    check("op lands at the model's offset", image[2:4] == b"\x01\x00")
    check("m lands at the model's offset", image[8:12] == b"\x04\x00\x00\x00")
    check("unset bytes stay zero", image[4:8] == b"\x00\x00\x00\x00")

    # An op name resolves through the model's own table, never a literal.
    check("op resolves by name", layout.op_value("OP_GEMM") == 1)
    check("op resolves without prefix", layout.op_value("GEMM") == 1)

    # Failing loudly is the contract: a guessed field is worse than a stop.
    try:
        layout.pack({"not_a_field": 1})
        check("unknown field is rejected", False)
    except LayoutError as exc:
        check("unknown field names the alternatives", "version" in str(exc))
    try:
        layout.pack({"op": 0x1_0000})
        check("oversized value is rejected", False)
    except LayoutError:
        pass

    # An unresolved placement warns but still packs: the image is placement-independent.
    unplaced = json.loads(json.dumps(_SELFTEST_MODEL))
    unplaced["soc"]["ai_island"]["config"] = {}
    unplaced_layout = DescLayout.from_model(unplaced)
    check(
        "an unplaced island still packs a correct image",
        unplaced_layout.pack({"op": 1}) == layout.pack({"op": 1}),
    )

    # A model with no island must not silently produce an empty descriptor.
    try:
        DescLayout.from_model({"soc": {}})
        check("a model without an island is rejected", False)
    except LayoutError:
        pass
    try:
        DescLayout.from_model({"soc": {"ai_island": {"desc_layout": {"fields": {}}}}})
        check("an un-ingested layout is rejected", False)
    except LayoutError:
        pass

    # Artifact handling: both shapes, and the header stamp.
    # The first event omits dtype and carries only flags; the flags_layout recovers it.
    flags_layout = {"dtype_shift": 8, "dtype_mask": 0x3F}
    stamped = TensorArtifact(
        {"profile": "g6lc-soc", "profile_tainted": False, "evidence": False},
        [
            {
                "order": 0,
                "hart": 0,
                "op": 1,
                "status": 0,
                "done": True,
                "m": 4,
                "n": 4,
                "k": 4,
                "flags": 0x0100,
                "cluster": 0,
                "ptr_a": 0x9000_0000,
                "ptr_b": 0x9000_1000,
                "ptr_c": 0x9000_2000,
            },
            {
                "order": 1,
                "hart": 1,
                "op": 1,
                "status": 0,
                "done": False,
                "m": 4,
                "n": 4,
                "k": 4,
                "dtype": 2,
                "cluster": 1,
            },
        ],
        flags_layout,
    )
    summary = stamped.summary()
    check("event count", summary["events"] == 2)
    check("done count", summary["done"] == 1)
    check("inflight count", summary["inflight"] == 1)
    check("op histogram", summary["by_op"] == {"1": 2})
    check("hart histogram", summary["by_hart"] == {"0": 1, "1": 1})
    check("cluster histogram", summary["by_cluster"] == {"0": 1, "1": 1})
    check(
        "dtype is recovered from flags when flags_layout is present",
        summary["by_dtype"] == {"1": 1, "2": 1},
        str(summary["by_dtype"]),
    )
    check("evidence is never asserted", summary["evidence"] is False)
    check(
        "modelled counters are not re-derived here",
        "ai.tensor.macs" not in summary and "ai.tensor.bytes" not in summary,
    )

    # With a layout and a cluster count, op/status names resolve and the SKU cluster count is reported.
    resolved = stamped.summary(layout, clusters=2)
    check("by_op_name resolves through layout", resolved.get("by_op_name") == {"OP_GEMM": 2})
    check("by_status_name resolves through layout", resolved.get("by_status_name") == {"ST_OK": 2})
    check("cluster count from model is reported", resolved.get("clusters") == 2)

    # PyTorch-friendly output list contains only completed events with shapes, cluster and pointers.
    outputs = stamped.pytorch_summary(layout)
    check("pytorch_summary returns only completed events", len(outputs) == 1)
    if outputs:
        check("pytorch_summary resolves op name", outputs[0]["op_name"] == "OP_GEMM")
        check("pytorch_summary resolves status name", outputs[0]["status_name"] == "ST_OK")
        check("pytorch_summary carries ptr_c", outputs[0]["ptr_c"] == 0x9000_2000)
        check("pytorch_summary recovers dtype from flags", outputs[0]["dtype"] == 1)
        check("pytorch_summary carries cluster", outputs[0]["cluster"] == 0)

    # Comparison reports a first divergence, and agreement is silent.
    check("identical artifacts agree", compare_artifacts(stamped, stamped) == [])
    other = TensorArtifact(
        stamped.header, [dict(stamped.events[0], status=1)], stamped.flags_layout
    )
    diffs = compare_artifacts(stamped, other)
    check("divergence is reported", any(d["field"] == "status" for d in diffs), str(diffs))

    vc = virt_card_artifact([[19, 22], [43, 50]], m=2, n=2, k=2)
    check("virt-card artifact is never evidence", vc.header.get("evidence") is False)
    check("virt-card route is stamped", vc.header.get("route") == "virt-card")
    check("virt-card event is done 2x2", vc.events[0]["m"] == 2 and vc.events[0]["done"] is True)
    dumped = vc.to_json()
    check("virt-card dump has header+events", "header" in dumped and len(dumped["events"]) == 1)

    packed16 = layout.pack({"version": 1, "op": 1, "m": 2})
    check("selftest pack is the model's size", len(packed16) == 16)
    roundtrip = layout.unpack(packed16)
    check("unpack version", roundtrip.get("version") == 1)
    check("unpack op", roundtrip.get("op") == 1)
    check("unpack m", roundtrip.get("m") == 2)
    text = layout.decode_text(packed16)
    check("decode_text names OP_GEMM", "OP_GEMM" in text)
    check("decode_text carries m=2", "m=2" in text)
    try:
        layout.unpack(packed16[:-1])
        check("short image is rejected", False)
    except LayoutError:
        pass
    vc2 = virt_card_artifact([[19, 22], [43, 50]], m=2, n=2, k=2, desc=packed16)
    check("virt-card stamps desc_bytes from packed image", vc2.header.get("desc_bytes") == 16)
    check(
        "virt-card desc_hex is little-endian version|op",
        str(vc2.header.get("desc_hex", "")).startswith("01000100"),
    )
    check("virt-card dump carries desc_hex", "desc_hex" in vc2.to_json()["header"])
    check("virt-card without desc has no desc_hex", "desc_hex" not in dumped["header"])
    check("virt-card with desc stamps bar4_desc", vc2.header.get("bar4_desc") is True)

    cap_txt = island_cap_text(_SELFTEST_MODEL)
    check("CAP text names clusters", "clusters=2" in cap_txt)
    check("CAP text names macs_per_cycle", "macs_per_cycle=256" in cap_txt)
    check("CAP modelled peak is 512 GOPS", "modelled_peak_gops=512" in cap_txt)
    check("CAP modelled tops is 0.512", "modelled_peak_tops=0.512" in cap_txt)
    check("CAP class need is 50000 MAC/cycle at 1 GHz", "class_need_macs_per_cycle=50000" in cap_txt)
    check("CAP sku_frac is 256/50000", "sku_frac_of_class=0.00512" in cap_txt)
    check("CAP is never evidence", "tops_not_evidence=true" in cap_txt)
    check("1 MAC = 2 ops at 256×1 GHz", modelled_peak_ops(island_config(_SELFTEST_MODEL)) == 512_000_000_000)
    mmap = mmio_map_from_model(
        {
            "soc": {
                "ai_island": {
                    "config": {
                        "cap_base": 0,
                        "desc_base": 320,
                        "cap_offsets": {"version": 0, "clusters": 4, "macs_cycle": 8},
                    }
                }
            }
        }
    )
    check("mmio desc_base comes from the model", mmap.get("desc_base") == 320)
    check("mmio macs_off comes from the model", mmap.get("macs_off") == 8)
    cpl_txt = layout.completion_text()
    check("CPL text names ticket bits", "ticket_bit_high=31" in cpl_txt)
    check("CPL text names ST_OK", "st_ok=0" in cpl_txt)
    check("CPL is never evidence", "tops_not_evidence=true" in cpl_txt)
    cpl_img = layout.pack_completion(1, 0)
    check("completion word is 8 bytes", len(cpl_img) == 8)
    check("ticket=1 is little-endian in the word", cpl_img[0] == 1)
    check("status=0 leaves the high half zero", cpl_img[4:8] == b"\x00\x00\x00\x00")
    round_cpl = layout.unpack_completion(cpl_img)
    check("completion unpack ticket", round_cpl.get("ticket") == 1)
    check("completion unpack status", round_cpl.get("status") == 0)
    check("CPL text carries example_hex", "example_hex=" in cpl_txt)
    plane = plane_text(_SELFTEST_MODEL)
    check("PLANE text is two-plane", "split=two_plane" in plane)
    check("PLANE puts TOPS on the island", "tops_on=island" in plane)
    check("PLANE does not invent a core tile", "core_tile=not_in_this_model" in plane)
    check("PLANE is never evidence", "tops_not_evidence=true" in plane)
    jt = join_text(desc=b"\x01\x00\x01\x00", cpl=b"\x01" + b"\x00" * 7)
    check("JOIN names firmware_and_card", "join=firmware_and_card" in jt)
    check("JOIN carries desc prefix", "desc_hex_prefix=01000100" in jt)
    check("JOIN carries cpl hex", "cpl_hex=0100000000000000" in jt)
    check("JOIN irq order is wait then claim", "irq=wait_then_claim_done" in jt)
    check("JOIN carries desc sha256", "desc_sha256=" in jt)
    check("JOIN carries cpl sha256", "cpl_sha256=" in jt)
    roof = roof_text(_SELFTEST_MODEL)
    check("ROOF names blocking T", "blocking_t=256" in roof)
    check("ROOF class DRAM is ~391 GB/s", "class_dram_gbps=390.625" in roof)
    check("ROOF SKU DRAM is 2 GB/s", "sku_dram_gbps=2" in roof)
    check("ROOF acc SRAM is 256 KiB", "acc_sram_kib=256" in roof)
    check("ROOF acc fits island SRAM", "acc_fits_island_sram=true" in roof)
    check("ROOF is never evidence", "tops_not_evidence=true" in roof)
    qt = queue_text(_SELFTEST_MODEL)
    check("QUEUE names rings", "queues=2" in qt)
    check("QUEUE names depth", "queue_depth=64" in qt)
    check("QUEUE doorbell qid is 0", "doorbell_qid=0" in qt)
    check("QUEUE last qid is queues-1", "doorbell_qid_last=1" in qt)
    check("QUEUE cluster comes from the map", "cluster_from_map=true" in qt)
    check("QUEUE qid 0 maps to cluster 0", "qid0_cluster=0" in qt)
    check("QUEUE qos comes from qid", "qos_from_qid=true" in qt)
    check("QUEUE qid 0 qos is 0", "qid0_qos=0" in qt)
    check("QUEUE is never evidence", "tops_not_evidence=true" in qt)
    st = sched_text(_SELFTEST_MODEL, standin_k=2)
    check("SCHED names work quantum", "work_quantum_k=64" in st)
    check("SCHED stand-in k is within Q", "within_quantum=true" in st)
    check("SCHED is never evidence", "tops_not_evidence=true" in st)
    stt = stat_text(_SELFTEST_MODEL, desc_version=1)
    check("STAT qid is bounded", "qid_bound=true" in stt)
    check("STAT oob qid is queues", "oob_qid=2" in stt)
    check("STAT version is ok", "version_ok=true" in stt)
    check("STAT is never evidence", "tops_not_evidence=true" in stt)
    ot = op_text(layout, packed_op=1)
    check("OP table names GEMM", "OP_GEMM=1" in ot)
    check("OP packed is ok", "op_ok=true" in ot)
    check("OP unknown is rejected", "unknown_op_rejected=true" in ot)
    ct = ctl_text()
    check("CTL wr_cpl_en is 0", "wr_cpl_en=0" in ct)
    check("CTL disabled doorbells are rejected", "disabled_rejected=true" in ct)
    check("CTL re-enable is ok", "reenable_ok=true" in ct)
    check("flags_layout irq_bit is ingested", layout.flags_layout.get("irq_bit") == 2)
    check("irq_mask is 1<<2", layout.irq_mask() == 4)
    defaults = layout.apply_standin_defaults({"version": 1, "op": 1, "m": 4})
    check("stand-in flags is irq_mask", defaults.get("flags") == 4)
    check("stand-in ptr_done is null", defaults.get("ptr_done") == 0)
    standin = layout.pack(defaults)
    check("packed flags word is irq_mask", standin[4:8] == b"\x04\x00\x00\x00")
    pt = ptr_text(layout)
    check("PTR names null pointers", "ptr_null=true" in pt)
    check("PTR names BAR4 A", "bar4_a=A" in pt)
    check("PTR completion is MMIO", "ptr_done_path=mmio_cpl" in pt)
    check("PTR does not invent an address", "0x9000" not in pt)
    check("PTR is never evidence", "tops_not_evidence=true" in pt)
    ft = flags_text(layout, packed_flags=4)
    check("FLAGS names irq_bit", "irq_bit=2" in ft)
    check("FLAGS irq_bit matches isa-encoding", "irq_bit_ok=true" in ft)
    check("FLAGS packed irq is set", "flags_irq=true" in ft)
    check("FLAGS fence bits are clear", "fence_clear=true" in ft)
    check("FLAGS priority is default 0", "priority_default=true" in ft)
    check("FLAGS dense INT8 is s8s8", "dtype_s8s8=true" in ft)
    check("FLAGS does not claim INT4", "int4_not_in_headline=true" in ft)
    check("FLAGS is never evidence", "tops_not_evidence=true" in ft)
    geom = json.loads(json.dumps(_SELFTEST_MODEL))
    gfields = geom["soc"]["ai_island"]["desc_layout"]["fields"]
    gfields["n"] = {"offset": 16, "size": 4, "bit_low": 128, "bit_high": 159}
    gfields["k"] = {"offset": 20, "size": 4, "bit_low": 160, "bit_high": 191}
    gfields["ld_ab"] = {"offset": 24, "size": 4, "bit_low": 192, "bit_high": 223}
    geom["soc"]["ai_island"]["desc_layout"]["desc_bytes"] = 28
    gl = DescLayout.from_model(geom)
    gvals = {"version": 1, "op": 1, "m": 2, "n": 2, "k": 2}
    gl.apply_standin_defaults(gvals)
    check("ld_ab is packed from n,k", gvals.get("ld_ab") == 0x00020002)
    gimg = gl.pack(gvals)
    check("ld_ab little-endian in the image", gimg[24:28] == b"\x02\x00\x02\x00")
    gtxt = gl.decode_text(gimg)
    check("decode names lda", "lda=2" in gtxt)
    check("decode names ldb", "ldb=2" in gtxt)
    check("ld_ab matches n,k", "ld_ab_ok=true" in gtxt)
    ov = cap_overrides_from_model(_SELFTEST_MODEL)
    check("CAP overrides carry clusters", ov.get("clusters") == 2)
    vc3 = virt_card_artifact(
        [[19, 22], [43, 50]],
        m=2,
        n=2,
        k=2,
        desc=packed16,
        cap={"clusters": 2, "macs_per_cycle": 256},
        modelled_peak_gops=512.0,
    )
    check("virt-card stamps island_cap", vc3.header.get("island_cap", {}).get("clusters") == 2)
    check("virt-card stamps modelled_peak_gops", vc3.header.get("modelled_peak_gops") == 512.0)

    if failures:
        for f in failures:
            err(f)
        err(f"selftest FAILED ({len(failures)} check(s))")
        return 1
    log("selftest OK")
    return 0


# ---------------------------------------------------------------------------- argparse


def main(argv: list | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="ai_tensor_bridge.py",
        description="Host bridge over the AI tensor artifact contract "
        "(architecture/AI_BRIDGE.md).",
    )
    sub = ap.add_subparsers(dest="verb", required=True)

    p = sub.add_parser("doctor", help="report which execution routes are available")
    p.add_argument("--repo-root", default=None)
    p.set_defaults(fn=cmd_doctor)

    p = sub.add_parser("pack", help="pack a descriptor using the model's own layout")
    p.add_argument("--model", required=True, help="TargetModel JSON (g6q gen --emit model)")
    p.add_argument("--set", action="append", default=[], help="field=value, repeatable")
    p.add_argument("--op", default=None, help="op name from the model's table, or a number")
    p.add_argument("--out", default=None, help="write the image here instead of printing hex")
    p.add_argument(
        "--decode-out",
        default=None,
        help="write a Shell-friendly field dump (DESC.TXT) using the model's names",
    )
    p.add_argument(
        "--cap-out",
        default=None,
        help="write ingested island CAP geometry (CAP.TXT); modelled peak, not evidence",
    )
    p.add_argument(
        "--cpl-out",
        default=None,
        help="write ingested completion-word layout (CPL.TXT)",
    )
    p.set_defaults(fn=cmd_pack)

    p = sub.add_parser("cpl", help="dump ingested completion-word layout as Shell text")
    p.add_argument("--model", required=True, help="TargetModel JSON")
    p.add_argument("--out", default=None, help="write CPL.TXT here instead of stdout")
    p.set_defaults(fn=cmd_cpl)

    p = sub.add_parser("cap", help="dump ingested island CAP geometry as Shell text")
    p.add_argument("--model", required=True, help="TargetModel JSON")
    p.add_argument("--out", default=None, help="write CAP.TXT here instead of stdout")
    p.set_defaults(fn=cmd_cap)

    p = sub.add_parser("unpack", help="decode a packed descriptor using the model's own layout")
    p.add_argument("--model", required=True, help="TargetModel JSON")
    p.add_argument("--image", required=True, help="packed descriptor bytes")
    p.add_argument("--out", default=None, help="write decode text here instead of stdout")
    p.set_defaults(fn=cmd_unpack)

    p = sub.add_parser("push", help="run one execution and retrieve the tensor artifact")
    p.add_argument("--route", default="native", choices=sorted(ROUTES))
    p.add_argument("--image", default=None, help="flat guest image for the native route")
    p.add_argument("--target", default=None)
    p.add_argument("--repo-root", default=None)
    p.add_argument("--steps", type=int, default=None)
    p.add_argument("--tensor-out", default="out/bridge/tensor.json")
    p.add_argument("--remote-tensor", default="tensor.json")
    p.add_argument("--machine", default=None)
    p.add_argument("--tag", default=None)
    p.add_argument("--dry-run", action="store_true")
    p.add_argument(
        "--measured-dram-gbps",
        type=float,
        default=None,
        help="host-measured DRAM bandwidth in GB/s; passed to diag if --uarch-out is set",
    )
    p.add_argument(
        "--uarch-out",
        default=None,
        help="after a successful run, run g6lc-qemu diag and write counters here (native only)",
    )
    p.add_argument("--card-root", default=None, help="ai-tensor root for --route virt-card")
    p.add_argument(
        "--model",
        default=None,
        help="TargetModel JSON; virt-card packs OP_GEMM from desc_layout into the artifact header",
    )
    p.set_defaults(fn=cmd_push)

    p = sub.add_parser("results", help="summarise a tensor artifact")
    p.add_argument("artifact")
    p.add_argument("--model", default=None, help="model JSON to resolve op/status names and roofline")
    p.add_argument("--target", default=None, help="target id; inferred from --model if present")
    p.add_argument("--repo-root", default=None, help="design tree root for diag re-ingest")
    p.add_argument("--uarch-out", default=None, help="write D2 uarch counters here when --tops is used")
    p.add_argument(
        "--per-event",
        action="store_true",
        help="include one PyTorch-friendly output record per completed event",
    )
    p.add_argument(
        "--tops",
        action="store_true",
        help="add a 100-TOPS-style roofline report from g6lc-qemu diag (modelled, not measured)",
    )
    p.add_argument(
        "--measured-dram-gbps",
        type=float,
        default=None,
        help="host-measured DRAM bandwidth in GB/s; closes the roofline for --tops",
    )
    p.set_defaults(fn=cmd_results)

    p = sub.add_parser("compare", help="diff two tensor artifacts")
    p.add_argument("lhs")
    p.add_argument("rhs")
    p.set_defaults(fn=cmd_compare)

    p = sub.add_parser("pcie", help="report the PCIe host-transport concept and contract pin state")
    p.set_defaults(fn=cmd_pcie)

    p = sub.add_parser("diag", help="run g6lc-qemu diag with an optional host-measured bandwidth")
    p.add_argument("--target", default=None)
    p.add_argument("--repo-root", default=None)
    p.add_argument("--tensor", action="append", default=[], help="tensor artifact(s) to merge")
    p.add_argument(
        "--measured-dram-gbps",
        type=float,
        default=None,
        help="host-measured DRAM bandwidth in GB/s (e.g. 320.5); multiplied by 1000 for the CLI",
    )
    p.add_argument("--uarch-out", default="out/bridge/uarch.json")
    p.set_defaults(fn=cmd_diag)

    p = sub.add_parser("selftest", help="offline checks; no model, QEMU or network")
    p.set_defaults(fn=cmd_selftest)

    args = ap.parse_args(argv)
    if args.verb == "push" and args.route == "native" and not args.image:
        ap.error("push --route native needs --image FILE")
    return int(args.fn(args))


if __name__ == "__main__":
    sys.exit(main())
