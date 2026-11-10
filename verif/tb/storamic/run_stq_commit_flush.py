# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""stq-commit-flush: store_buffer coincident commit+flush leaf.

Promoted from the CPU49b leaf evidence (verif/tb/core/run-stq-commit-flush.sh):
the commit stage may retire a store in the same cycle a full flush arrives
(single-step debug entry on that store's commit). The retiring head must
still reach the commit queue and be the only store issued to the D$.

Builds tb_g6lc_stq_commit_flush against the real store_buffer with the owned
runtime/compiler identity and checks five variants:

- pos: live source, assertions on -> PASS marker, no failure text.
- oracle_negative: +oracle_negative must abort without a PASS marker.
- prefix: store_buffer.sv with the two new assertions textually reverted to
  the pre-CPU49b `commit_and_flush` (deterministic reconstruction, exactly
  one substitution, no .git needed) -> the old assertion must fire on the
  coincident case.
- mut: +define+G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH (commit-queue push gated
  on !flush_i) with assertions -> commit_and_flush_keeps_head or the bench
  oracle must reject it.
- mutna: same define without --assert -> the bench oracle
  STQ_HEAD_RETIRED_WITH_FLUSH must reject it.
"""
import hashlib
import json
import os
import subprocess


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


SOURCES = [
    "config_pkg.sv", "g6lc64_ooo_config_pkg.sv", "riscv_pkg.sv",
    "ariane_pkg.sv", "g6lc_ooo_pkg.sv",
]
BENCH = "tb_g6lc_stq_commit_flush.sv"
DUT = "store_buffer.sv"

# The committed store_buffer.sv carries the CPU49b assertion pair; the
# pre-fix file carried a single mutual-exclusion assertion. The prefix
# reconstruction swaps the whole new block (comment through the second
# assertion's else) back to the old text — exactly once, no VCS needed.
PREFIX_BEGIN = "  // The commit stage can retire a store"
PREFIX_END = ('else $error("[Speculative Queue] speculative stores survived '
              'a full flush");')
PREFIX_OLD = """\
  // assert that commit is never set when we are flushing this would be counter intuitive
  // as flush and commit is decided in the same stage
  commit_and_flush :
  assert property (@(posedge clk_i) rst_ni && flush_i |-> !commit_i)
  else $error("[Commit Queue] You are trying to commit and flush in the same cycle");"""

MUT_DEFINE = "+define+G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH"
PASS_TOKEN = "PASS tb_g6lc_stq_commit_flush"
HEAD_TAG = "STQ_HEAD_RETIRED_WITH_FLUSH"
ASSERT_MSG = "a store retired with a flush did not reach the commit queue"
OLD_MSG = "commit and flush in the same cycle"
# Failure markers that must never appear in a passing log.
FAIL_MARKERS = (ASSERT_MSG, OLD_MSG, HEAD_TAG, "ORACLE_NEGATIVE",
                "survived a full flush")
WNO = ["-Wno-TIMESCALEMOD", "-Wno-UNUSED", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND",
       "-Wno-PINCONNECTEMPTY", "-Wno-CASEINCOMPLETE", "-Wno-UNOPTFLAT",
       "-Wno-DECLFILENAME"]


def _prefix_source(src, dest):
    text = src.read_text(encoding="utf-8")
    if text.count(PREFIX_BEGIN) != 1 or text.count(PREFIX_END) != 1:
        raise RuntimeError("STQ_PREFIX_ASSERTION_INVENTORY")
    begin = text.index(PREFIX_BEGIN)
    end = text.index(PREFIX_END) + len(PREFIX_END)
    dest.write_text(text[:begin] + PREFIX_OLD + text[end:],
                    encoding="utf-8")
    return dest


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    if "stq-commit-flush" not in stages:
        return
    env = dict(os.environ)
    for key in ("MAKEFLAGS", "MFLAGS", "CXX", "CC", "CXXFLAGS", "CFLAGS",
                "CPPFLAGS", "LDFLAGS", "OBJCACHE", "VERILATOR_ROOT", "VPATH"):
        env.pop(key, None)
    if manifest["runtime"].get("kind") == "g6lc-fork-native":
        env["VERILATOR_ROOT"] = manifest["runtime"]["root"]
    base = [str(data / name) for name in SOURCES]
    bench = str(data / BENCH)
    live = data / DUT
    prefix = out / "store_buffer_prefix.sv"
    _prefix_source(live, prefix)
    manifest["stq_commit_flush"] = {
        "store_buffer_sha256": _sha(live),
        "prefix_store_buffer_sha256": _sha(prefix),
        "bench_sha256": _sha(data / BENCH),
        "mutant_define": MUT_DEFINE,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))

    def build(tag, dut_path, assert_on, extra=()):
        model = out / ("stq-" + tag)
        model.mkdir()
        command = [str(verilator), "--binary", "--timing", "--threads", "1",
                   "-Wno-fatal", *WNO,
                   "--top-module", "tb_g6lc_stq_commit_flush",
                   "--Mdir", str(model), "-o", "test"]
        if assert_on:
            command.append("--assert")
        command += [*extra, *base, str(dut_path), bench]
        command += manifest["runtime"].get("verilator_options", [])
        (out / ("stq-" + tag + "-command.json")).write_text(
            json.dumps(command))
        identity = build_model(command, model,
                               out / ("stq-" + tag + "-build.log"), manifest)
        builds.append(identity | {"stq_commit_flush": tag})
        return model / "test"

    def sim(tag, exe, args=()):
        try:
            result = subprocess.run([str(exe), *args], env=env,
                                    cwd=exe.parent, capture_output=True,
                                    text=True, timeout=120)
            text = result.stdout + result.stderr
            rc = result.returncode
        except subprocess.TimeoutExpired:
            text, rc = "TIMEOUT", None
        (out / ("stq-" + tag + ".log")).write_text(text)
        return rc, text

    results = {}

    exe = build("pos", live, True)
    rc, text = sim("pos", exe)
    results["pos"] = (rc == 0 and text.count(PASS_TOKEN) == 1 and
                      not any(m in text for m in FAIL_MARKERS))

    rc, text = sim("neg", exe, ["+oracle_negative"])
    results["oracle_negative"] = (
        rc != 0 and PASS_TOKEN not in text and
        ("ORACLE_NEGATIVE" in text or "STQ_" in text))

    exe = build("prefix", prefix, True)
    rc, text = sim("prefix", exe)
    results["prefix-assertion"] = (
        rc != 0 and PASS_TOKEN not in text and OLD_MSG in text)

    exe = build("mut", live, True, [MUT_DEFINE])
    rc, text = sim("mut", exe)
    results["mutant-assert"] = (
        rc != 0 and PASS_TOKEN not in text and
        (ASSERT_MSG in text or HEAD_TAG in text))

    exe = build("mutna", live, False, [MUT_DEFINE])
    rc, text = sim("mutna", exe)
    results["mutant-noassert"] = (
        rc != 0 and PASS_TOKEN not in text and HEAD_TAG in text)

    for tag, ok in results.items():
        outcomes.append({"stq_commit_flush": tag, "pass": bool(ok)})
    failed = [tag for tag, ok in results.items() if not ok]
    if failed:
        raise RuntimeError("stq-commit-flush verdicts failed: " +
                           ", ".join(failed))
