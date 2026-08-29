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
import json
import math
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

    def __init__(self, desc_bytes: int, fields: dict, ops: dict, statuses: dict) -> None:
        self.desc_bytes = desc_bytes
        self.fields = fields
        self.ops = ops
        self.statuses = statuses

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
        return cls(
            desc_bytes=desc_bytes,
            fields={k: dict(v) for k, v in fields.items()},
            ops={k: int(v) for k, v in (layout.get("ops") or {}).items()},
            statuses={k: int(v) for k, v in (layout.get("statuses") or {}).items()},
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


ROUTES = {"native": push_native, "remote": push_remote}


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
        layout = DescLayout.from_model_file(args.model)
        values = _parse_set(args.set)
        if args.op:
            values["op"] = layout.op_value(args.op)
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
        "note": "all BAR sizes, device IDs, and MSI details are conceptual until pinned",
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
            "config": {"cap_base": 0, "desc_base": 0x140, "clusters": 2},
            "desc_layout": {
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
    p.set_defaults(fn=cmd_doctor)

    p = sub.add_parser("pack", help="pack a descriptor using the model's own layout")
    p.add_argument("--model", required=True, help="TargetModel JSON (g6q gen --emit model)")
    p.add_argument("--set", action="append", default=[], help="field=value, repeatable")
    p.add_argument("--op", default=None, help="op name from the model's table, or a number")
    p.add_argument("--out", default=None, help="write the image here instead of printing hex")
    p.set_defaults(fn=cmd_pack)

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
