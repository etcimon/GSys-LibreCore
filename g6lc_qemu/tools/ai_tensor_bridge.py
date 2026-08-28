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
#   results   summarise a tensor artifact
#   compare   diff two tensor artifacts
#   selftest  offline checks (no model, no QEMU, no network)

from __future__ import annotations

import argparse
import json
import platform
import shutil
import subprocess
import sys
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

    def __init__(self, header: dict, events: list) -> None:
        self.header = header
        self.events = events

    @classmethod
    def load(cls, path: str | Path) -> "TensorArtifact":
        raw = json.loads(Path(path).read_text(encoding="utf-8"))
        if isinstance(raw, list):
            # A bare event array is accepted; the header is then simply unknown.
            return cls({}, raw)
        return cls(raw.get("header") or {}, raw.get("events") or [])

    @property
    def profile(self) -> str:
        return str(self.header.get("profile", "unknown"))

    @property
    def tainted(self) -> bool:
        return bool(self.header.get("profile_tainted", False))

    def summary(self) -> dict:
        """Aggregates that are *present* in the stream.

        Deliberately excludes `ai.tensor.bytes` / `ai.tensor.macs`: those are modelled
        quantities owned by `g6q-diag` (see the module docstring, limit 2).
        """
        ops: dict = {}
        harts: dict = {}
        statuses: dict = {}
        done = 0
        for ev in self.events:
            ops[str(ev.get("op", "?"))] = ops.get(str(ev.get("op", "?")), 0) + 1
            harts[str(ev.get("hart", "?"))] = harts.get(str(ev.get("hart", "?")), 0) + 1
            statuses[str(ev.get("status", "?"))] = statuses.get(str(ev.get("status", "?")), 0) + 1
            if ev.get("done"):
                done += 1
        return {
            "profile": self.profile,
            "profile_tainted": self.tainted,
            "evidence": bool(self.header.get("evidence", False)),
            "events": len(self.events),
            "done": done,
            "by_op": ops,
            "by_hart": harts,
            "by_status": statuses,
        }


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
    return route(args)


def cmd_results(args: argparse.Namespace) -> int:
    try:
        artifact = TensorArtifact.load(args.artifact)
    except (OSError, json.JSONDecodeError) as exc:
        err(f"cannot read {args.artifact}: {exc}")
        return 1
    summary = artifact.summary()
    print(json.dumps(summary, indent=2, sort_keys=True))
    if summary["profile_tainted"]:
        log("NOTE: the producing machine profile is tainted; this is not a hardware result")
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


# --------------------------------------------------------------------------- selftest


_SELFTEST_MODEL = {
    "soc": {
        "ai_island": {
            "config": {"cap_base": 0, "desc_base": 0x140},
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
    stamped = TensorArtifact(
        {"profile": "g6lc-soc", "profile_tainted": False, "evidence": False},
        [
            {"order": 0, "hart": 0, "op": 1, "status": 0, "done": True},
            {"order": 1, "hart": 1, "op": 1, "status": 0, "done": False},
        ],
    )
    summary = stamped.summary()
    check("event count", summary["events"] == 2)
    check("done count", summary["done"] == 1)
    check("op histogram", summary["by_op"] == {"1": 2})
    check("hart histogram", summary["by_hart"] == {"0": 1, "1": 1})
    check("evidence is never asserted", summary["evidence"] is False)
    check(
        "modelled counters are not re-derived here",
        "ai.tensor.macs" not in summary and "ai.tensor.bytes" not in summary,
    )

    # Comparison reports a first divergence, and agreement is silent.
    check("identical artifacts agree", compare_artifacts(stamped, stamped) == [])
    other = TensorArtifact(stamped.header, [dict(stamped.events[0], status=1)])
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
    p.add_argument("--steps", type=int, default=None)
    p.add_argument("--tensor-out", default="out/bridge/tensor.json")
    p.add_argument("--remote-tensor", default="tensor.json")
    p.add_argument("--machine", default=None)
    p.add_argument("--tag", default=None)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_push)

    p = sub.add_parser("results", help="summarise a tensor artifact")
    p.add_argument("artifact")
    p.set_defaults(fn=cmd_results)

    p = sub.add_parser("compare", help="diff two tensor artifacts")
    p.add_argument("lhs")
    p.add_argument("rhs")
    p.set_defaults(fn=cmd_compare)

    p = sub.add_parser("selftest", help="offline checks; no model, QEMU or network")
    p.set_defaults(fn=cmd_selftest)

    args = ap.parse_args(argv)
    if args.verb == "push" and args.route == "native" and not args.image:
        ap.error("push --route native needs --image FILE")
    return int(args.fn(args))


if __name__ == "__main__":
    sys.exit(main())
