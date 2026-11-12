#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# native-c2: qualify the C2 native-topology binding of g6lc_storamic_checkpoint_
# route + g6lc_storamic_c2_monitor inside the real ariane_testharness.
#
# Runs as a run_leaf.py stage. run_remote.py freezes the working tree into
# data/cva6-src-c2.tar.gz (sha256 pinned in the run manifest); this module
# verifies that digest, extracts the tree into the run directory, builds the
# distinct define-set models with the tools36 Verilator, compiles the C2 and
# virtio-blk firmware with the pinned riscv gcc, runs the case matrix, builds
# the m1-m5 mutants from patched copies inside the run dir, and writes
# native-c2.json. Any deviation from an exact expected value fails the stage;
# a timeout, a missing report line, or a tool/source identity mismatch makes it
# incomplete. A mutant that passes also fails the stage.
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import time

RISCV = "/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3"
SPIKE = "/opt/testharness/toolchains/spike"
TARGET = "cv64a6_imafdc_sv39"
COMMON = "verif/tests/custom/common"
ENVDIR = "verif/tests/custom/env"
SRC_TAR_NAME = "cva6-src-c2.tar.gz"
TOOLS_JSON = "verif/tb/storamic/storamic_tools.json"

FW_C2 = "verif/tests/custom/storamic/storamic_c2.c"
FW_VIRTIO = "verif/tests/custom/storamic/storamic_virtio_blk.c"
ROUTE_RTL = "corev_apu/storamic/g6lc_storamic_checkpoint_route.sv"
HARNESS = "corev_apu/tb/ariane_testharness.sv"
MONITOR = "verif/tb/storamic/g6lc_storamic_c2_monitor.sv"

# Define sets (one model build per distinct set).
DEFS_PO = "G6LC_STORAMIC+G6LC_STORAMIC_MODEL+G6LC_STORAMIC_ORIGIN_PROBE"
DEFS_QF = "G6LC_STORAMIC+G6LC_STORAMIC_MODEL"
DEFS_IO = "G6LC_STORAMIC_IO"
DEFS_DEFAULT = ""

# Expected topology tuple (crossbar dims are role-independent).
TOPO_EXPECT = ("STORAMIC_C2_TOPOLOGY slv=3 mst=11 idx=10 idw=4 idws=6 "
               "latency=0 maxtrans=8")

# Exact native field expectations for the C2 firmware (verified 1139-cycle run).
C2_FIELDS = {"p0_aw": 10, "p0_ar": 18, "p1_aw": 0, "p1_ar": 0,
             "p2_aw": 0, "p2_ar": 0, "m0_aw": 10, "m0_ar": 18,
             "m1_aw": 0, "m1_ar": 0, "m2_aw": 0, "m2_ar": 0,
             "done_w": 10, "done_r": 18, "err_resp": 2,
             "pending": 0, "violations": 0}
C2_FIELDS_PO = dict(C2_FIELDS, src_ok_aw=9, src_ok_ar=14)
C2_FIELDS_QF = dict(C2_FIELDS, src_ok_aw=0, src_ok_ar=0)
# Exact max_lid observed on the C2 firmware's port-0 master traffic
# (measured storamic-c21de13e03e0: port-0 local ids reach only 1). c2-po and
# c2-qf assert this exact value; the m5 mutant width derives from the same
# measurement at run time.
MAX_LID_C2 = 1
# ariane_axi_soc::IdWidth for this target (topology idw=4); a mutant width at
# or above it would be equivalent, so no valid m5 exists then.
M5_MAX_WIDTH = 4

# +storamic_sba_probe cases: one real DMI SBA read (0x50008000) and one write
# (0x50008008) through dm_top -> axi_adapter -> xbar slave port 1 -> route.
# Both target the reserved window (unserved -> DECERR), the scored refusal.
# The adapter fixes AXI size=3, so port-1 traffic is never a source_ok
# candidate (route needs size==2) and src_ok stays at the port-0 values.
# Route Enable=0 refuses both -> err_resp = 2 firmware + 2 SBA = 4; each SBA
# access is a single beat -> done +1/+1, beats1 = 2.
C2_SBA_FIELDS = {"p0_aw": 10, "p0_ar": 18, "p1_aw": 1, "p1_ar": 1,
                 "p2_aw": 0, "p2_ar": 0, "m0_aw": 10, "m0_ar": 18,
                 "m1_aw": 1, "m1_ar": 1, "m2_aw": 0, "m2_ar": 0,
                 "done_w": 11, "done_r": 19, "err_resp": 4,
                 "pending": 0, "violations": 0}
C2_SBA_PO = dict(C2_SBA_FIELDS, src_ok_aw=9, src_ok_ar=14,
                 max_lid=MAX_LID_C2)
C2_SBA_QF = dict(C2_SBA_FIELDS, src_ok_aw=0, src_ok_ar=0,
                 max_lid=MAX_LID_C2)
SBA_EXPECT = {"reads": 1, "writes": 1, "rd_sberror": 0, "wr_sberror": 0}


def m5_width_for(max_lid):
    """Mutant LocalIdWidth that is provably non-equivalent: floor(log2(max_lid)).

    The mutant drops the local id's top set bit into the prefix field, so the
    widest observed local id decodes to a non-zero prefix and must fatal.
    Returns None when max_lid is unknown/zero (no non-equivalent width exists)
    or would not shrink below the real LocalIdWidth.
    """
    if not max_lid or max_lid < 1:
        return None
    w = max_lid.bit_length() - 1
    return w if 0 <= w < M5_MAX_WIDTH else None

SIM_TIMEOUT = int(os.environ.get("C2_TIMEOUT", "3600"))
BUILD_TIMEOUT = int(os.environ.get("C2_BUILD_TIMEOUT", "5400"))


def log(m):
    print(f"[native-c2] {m}", flush=True)


def sha256_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sh(argv, cwd, env, logfile, timeout=3600):
    log("RUN " + " ".join(str(a) for a in argv[:5]) + " ...")
    t0 = time.time()
    with open(logfile, "w") as lf:
        p = subprocess.Popen([str(a) for a in argv], cwd=str(cwd), env=env,
                             stdout=lf, stderr=subprocess.STDOUT)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            rc = -9
    dt = time.time() - t0
    log(f"  rc={rc} in {dt:.1f}s")
    txt = Path(logfile).read_text(errors="replace") if Path(logfile).exists() else ""
    return rc, dt, txt


def base_env(verilator, verilator_root):
    env = dict(os.environ)
    env.update({
        "PATH": f"{verilator_root}/bin:{RISCV}/bin:{SPIKE}/bin:"
                "/usr/local/bin:/usr/bin:/bin",
        "VERILATOR": verilator, "VERILATOR_INSTALL_DIR": verilator_root,
        "VERILATOR_ROOT": verilator_root,
        "RISCV": RISCV, "SPIKE_INSTALL_DIR": SPIKE,
        "LD_LIBRARY_PATH": f"{SPIKE}/lib:{RISCV}/lib:" +
                           env.get("LD_LIBRARY_PATH", ""),
        "CXX": env.get("CXX", "g++"), "CC": env.get("CC", "gcc"),
        "NUM_JOBS": env.get("NUM_JOBS", "8"),
        "TARGET_CFG": TARGET,
    })
    return env


def tohost_addr(elf):
    r = subprocess.run([f"{RISCV}/bin/riscv-none-elf-nm", str(elf)],
                       capture_output=True, text=True)
    m = re.search(r"([0-9a-f]+) [dDbB] tohost", r.stdout)
    return int(m.group(1), 16) if m else 0


def parse_native(logtxt):
    m = re.findall(r"STORAMIC_C2_NATIVE[^\n]*", logtxt)
    if not m:
        return None
    line = m[-1]
    d = {"line": line}
    for kv in re.findall(r"(\w+)=(-?\d+)", line):
        d[kv[0]] = int(kv[1])
    return d


def parse_topo(logtxt):
    m = re.findall(r"STORAMIC_C2_TOPOLOGY[^\n]*", logtxt)
    return m[-1] if m else None


def parse_sba(logtxt):
    """STORAMIC_SBA_PROBE line -> {line, reads, writes, rd_sberror, wr_sberror}."""
    m = re.findall(r"STORAMIC_SBA_PROBE[^\n]*", logtxt)
    if not m:
        return None
    line = m[-1]
    d = {"line": line}
    for kv in re.findall(r"(\w+)=(-?\d+)", line):
        d[kv[0]] = int(kv[1])
    return d


def fields_ok(nat, expected):
    if nat is None:
        return False, "missing STORAMIC_C2_NATIVE"
    bad = {k: (nat.get(k), v) for k, v in expected.items()
           if nat.get(k) != v}
    return (not bad), (f"mismatch {bad}" if bad else "ok")


def p_eq_m(nat):
    return all(nat.get(f"p{i}_aw") == nat.get(f"m{i}_aw") and
               nat.get(f"p{i}_ar") == nat.get(f"m{i}_ar") for i in range(3))


class Ctx:
    """Holds the extracted source tree, tools, and per-run state."""

    def __init__(self, src, out, verilator, verilator_root, env):
        self.src = Path(src)
        self.out = Path(out)
        self.verilator = verilator
        self.vroot = verilator_root
        self.env = env
        self.models = {}   # tag -> Path to Variane_testharness
        self.builds = []   # build_model records
        self.results = {}

    def model(self, tag):
        return self.src / f"work-ver-{tag}" / "Variane_testharness"

    def ensure_model(self, tag, defines):
        """Build the ariane_testharness model for a define set."""
        if self.model(tag).exists():
            return True, 0.0
        e = dict(self.env)
        e["G6LC_STORAMIC_DEFINES"] = defines
        cmd = ["make", "verilate", f"target={TARGET}",
               f"ver-library=work-ver-{tag}", f"verilator={self.verilator}",
               f"VERILATOR_INSTALL_DIR={self.vroot}", f"RISCV={RISCV}",
               f"SPIKE_INSTALL_DIR={SPIKE}",
               f"G6LC_STORAMIC_DEFINES={defines}", f"NUM_JOBS={e['NUM_JOBS']}"]
        rc, dt, txt = sh(cmd, self.src, e, self.out / f"verilate-{tag}.log",
                         timeout=BUILD_TIMEOUT)
        ok = rc == 0 and self.model(tag).exists() and txt.count("%Error") == 0
        self.builds.append({"model": tag, "defines": defines, "rc": rc,
                            "seconds": round(dt, 1), "ok": ok,
                            "verilator_errors": txt.count("%Error")})
        return ok, dt

    def compile_fw(self, src_rel, tag, cflags):
        elf = self.src / f"native_{tag}.elf"
        cflags = list(cflags)
        argv = [f"{RISCV}/bin/riscv-none-elf-gcc", "-static",
                "-mcmodel=medany", "-march=rv64imafdc", "-mabi=lp64d",
                "-fvisibility=hidden", "-nostdlib", "-nostartfiles", "-O2",
                "-T", f"{COMMON}/link_verilator.ld",
                f"{COMMON}/syscalls.c", f"{COMMON}/crt.S", src_rel,
                "-lgcc", f"-I{COMMON}", f"-I{ENVDIR}", *cflags,
                "-o", str(elf)]
        rc, _, txt = sh(argv, self.src, self.env,
                        self.out / f"gcc-{tag}.log")
        return elf if rc == 0 else None

    def run_sim(self, tag, elf, plusargs=(), debug_disable=True):
        sim = self.model(tag)
        th = tohost_addr(elf)
        argv = [str(sim), "+time_out=20000000"]
        if debug_disable:
            argv.append("+debug_disable")
        argv += ["+storamic_c2_report", "+g6lc_storamic_mem_trace",
                 *plusargs, f"+tohost_addr=0x{th:x}", str(elf)]
        rc, dt, txt = sh(argv, self.src, self.env,
                         self.out / f"sim-{tag}.log", timeout=SIM_TIMEOUT)
        nat = parse_native(txt)
        topo = parse_topo(txt)
        sba = parse_sba(txt)
        success = "*** SUCCESS ***" in txt and "cycle budget reached" not in txt
        failed = re.findall(r"\*\*\* FAILED \*\*\* \(tohost\s*=\s*(\d+)", txt)
        # NB: the benign report line "STORAMIC_C2_TOPOLOGY slv=..." is printed
        # on every run, so the bare token must NOT be a fatal marker — only the
        # $fatal variants (which all emit %Error) count. ``rule_range`` is the
        # m3 topology fatal tag; every $fatal/$stop also trips %Error.
        fatal = bool(re.search(
            r"STORAMIC_C2_VIOLATION|%Error|aw_overlap|ar_overlap|"
            r"r_spurious|b_spurious|w_no_owner|wrong.*port|"
            r"source_ok_value|_without_device|bad_prefix|unmatched|payload|"
            r"STORAMIC_CHECKPOINT_ROUTE_CONFIG|rule_range",
            txt))
        fl = [l.strip() for l in txt.splitlines() if re.search(
            r"STORAMIC|%Error|Assert|Fatal|VIOLATION|spurious|unmatched|"
            r"bad_prefix|payload|without_device|source_ok|overlap|"
            r"w_no_owner|rule_range", l)]
        return {"rc": rc, "seconds": round(dt, 1), "tohost": hex(th),
                "success": success, "timed_out": rc == -9,
                "fail_code": failed[0] if failed else None,
                "fail_tohost": failed[0] if failed else None,
                "topology": topo, "native": nat, "fatal": fatal,
                "sba_probe": sba,
                "fatal_msg": (fl[-1] if fl else None),
                "native_line": (nat or {}).get("line"),
                "violations": (nat or {}).get("violations"),
                "pending": (nat or {}).get("pending"),
                "tail": txt[-600:]}


def _case(ctx, name, tag, elf, expect_fields=None, expect_gt=None,
          expect_success=True, expect_fail_tohost=None, require_topo=True,
          plusargs=(), expect_sba=None, debug_disable=True):
    """Run one sim and evaluate it against the case contract."""
    sim = ctx.run_sim(tag, elf, plusargs=plusargs,
                      debug_disable=debug_disable)
    nat = sim.get("native")
    checks = []

    def add(label, ok, why=""):
        checks.append({"check": label, "ok": bool(ok), "why": why})

    add("report_line", nat is not None, "missing STORAMIC_C2_NATIVE")
    if nat is not None:
        add("violations0", nat.get("violations") == 0,
            f"violations={nat.get('violations')}")
        add("pending0", nat.get("pending") == 0, f"pending={nat.get('pending')}")
        add("p_eq_m", p_eq_m(nat), "p!=m")
        if expect_fields:
            ok, why = fields_ok(nat, expect_fields)
            add("fields", ok, why)
        if expect_gt:
            for k, thr in expect_gt.items():
                add(f"gt_{k}", (nat.get(k) or 0) > thr,
                    f"{k}={nat.get(k)} !> {thr}")
    if require_topo:
        add("topology", sim.get("topology") == TOPO_EXPECT,
            f"topology={sim.get('topology')}")
    if expect_success is not None:
        add("success", sim.get("success") == expect_success,
            f"success={sim.get('success')} fail_code={sim.get('fail_code')}")
    if expect_fail_tohost is not None:
        add("fail_tohost", sim.get("fail_tohost") == str(expect_fail_tohost),
            f"tohost={sim.get('fail_tohost')}")
    if expect_sba is not None:
        sba = sim.get("sba_probe")
        bad = ({k: ((sba or {}).get(k), v) for k, v in expect_sba.items()
                if (sba or {}).get(k) != v}
               if sba else {"line": None})
        add("sba_probe", sba is not None and not bad,
            f"sba mismatch {bad}" if bad else "sba ok")
    add("no_fatal", not sim.get("fatal"), "monitor/RTL fatal")
    rec = {"case": name, "model": tag, "elf": elf.name,
           "elf_sha256": sha256_file(elf)[:16], "sim": sim,
           "report_line": sim.get("native_line"),
           "topology_line": sim.get("topology"),
           "checks": checks}
    # A missing STORAMIC_C2_NATIVE (or topology) report line, or a wall-clock
    # kill, means the run produced no verdict evidence -> incomplete, not a
    # functional fail. Only a produced-but-wrong report is a fail.
    missing = (nat is None or
               (require_topo and sim.get("topology") is None) or
               sim.get("timed_out") or
               # An SBA case with no STORAMIC_SBA_PROBE line produced no
               # port-1 verdict evidence -> incomplete, not a functional fail.
               (expect_sba is not None and sim.get("sba_probe") is None))
    if missing:
        rec["status"] = "incomplete"
    else:
        rec["status"] = "pass" if all(c["ok"] for c in checks) else "fail"
    rec["pass"] = rec["status"] == "pass"
    return rec


def execute(ctx):
    """Run the full native-c2 matrix + mutants; returns the report dict."""
    rep = {"work": str(ctx.src), "out": str(ctx.out),
           "defines": {"po": DEFS_PO, "qf": DEFS_QF, "io": DEFS_IO,
                       "default": DEFS_DEFAULT},
           "verilator": ctx.verilator,
           "verilator_bin_sha256": (sha256_file(Path(ctx.verilator).parent /
                                     "verilator_bin")
                                   if Path(ctx.verilator).parent.joinpath(
                                       "verilator_bin").exists() else None),
           "gcc": subprocess.run([f"{RISCV}/bin/riscv-none-elf-gcc", "--version"],
                                 capture_output=True, text=True
                                 ).stdout.splitlines()[0],
           "gcc_sha256": sha256_file(f"{RISCV}/bin/riscv-none-elf-gcc"),
           "libfesvr_sha256": (sha256_file(f"{SPIKE}/lib/libfesvr.so")
                               if Path(f"{SPIKE}/lib/libfesvr.so").exists()
                               else None),
           "cases": {}, "mutants": {}, "builds": ctx.builds,
           "port1_native_traffic": "not-exercised",
           "incomplete": []}

    # Compile firmware once per role (c2 is role-independent -> one ELF).
    c2_elf = ctx.compile_fw(FW_C2, "c2", ["-DSTORAMIC_COHERENT_DMA",
                                          "-DSTORAMIC_PRIMARY"])
    # Port-1 SBA variant: an ALU-only register spin at main() start gives the
    # fesvr producer thread time to finish dm_top init and run the DMI SBA
    # sequence (preload_aware_dtm_t::reset) before the firmware's first
    # control-page access — required so the SBA traffic lands before both the
    # c2 exit and the m6 source_ok fatal. No memory ops -> identical counts.
    c2_sba_elf = ctx.compile_fw(FW_C2, "c2-sba",
                                ["-DSTORAMIC_COHERENT_DMA",
                                 "-DSTORAMIC_PRIMARY", "-DSTORAMIC_DELAY_EARLY"])
    virtio_pos_elf = ctx.compile_fw(FW_VIRTIO, "virtio-io-pos",
                                    ["-DSTORAMIC_COHERENT_DMA"])
    virtio_neg_elf = ctx.compile_fw(FW_VIRTIO, "virtio-io-neg",
                                    ["-DSTORAMIC_COHERENT_DMA",
                                     "-DORACLE_NEGATIVE"])
    if c2_elf is None:
        rep["incomplete"].append("c2 firmware gcc failed")
    if virtio_pos_elf is None or virtio_neg_elf is None:
        rep["incomplete"].append("virtio firmware gcc failed")

    # ---- models -------------------------------------------------------------
    for tag, defines in (("po", DEFS_PO), ("qf", DEFS_QF), ("io", DEFS_IO)):
        ok, _ = ctx.ensure_model(tag, defines)
        if not ok:
            rep["incomplete"].append(f"model {tag} build failed")

    # ---- case a: primary probe-on c2 ---------------------------------------
    po_max_lid = None
    if c2_elf is not None and ctx.model("po").exists():
        po_fields = dict(C2_FIELDS_PO)
        if MAX_LID_C2 is not None:
            po_fields["max_lid"] = MAX_LID_C2
        rep["cases"]["c2-po"] = _case(ctx, "c2-po", "po", c2_elf,
                                       expect_fields=po_fields,
                                       expect_gt={"max_lid": 0},
                                       expect_success=True)
        po_max_lid = (((rep["cases"]["c2-po"].get("sim") or {})
                       .get("native") or {}).get("max_lid"))
        rep["max_lid_c2_po"] = po_max_lid
    # ---- case b: primary probe-off c2 (same ELF) ----------------------------
    if c2_elf is not None and ctx.model("qf").exists():
        # Same ELF -> identical port-0 traffic -> identical max_lid. Assert the
        # pinned value when known, else the value measured on c2-po.
        qf_lid = MAX_LID_C2 if MAX_LID_C2 is not None else po_max_lid
        qf_fields = dict(C2_FIELDS_QF)
        qf_gt = {}
        if qf_lid is not None:
            qf_fields["max_lid"] = qf_lid
        else:
            qf_gt = {"max_lid": 0}
        rep["cases"]["c2-qf"] = _case(ctx, "c2-qf", "qf", c2_elf,
                                       expect_fields=qf_fields,
                                       expect_gt=qf_gt,
                                       expect_success=True)
    # ---- cases b2: port-1 debug SBA native traffic -------------------------
    # Same models + firmware as c2-po/c2-qf plus +storamic_sba_probe: the
    # fesvr DTM issues real sbcs/sbaddress/sbdata ops whose SBA master traffic
    # crosses xbar slave port 1 into the Storamic window. These run WITHOUT
    # +debug_disable: debug_req_core must reach the hart so producer_thread's
    # halt(0)/get_xlen()/resume(0) completes and htif_t::run()->reset() (where
    # the probe fires) is reached. All other cases keep +debug_disable.
    if c2_sba_elf is not None and ctx.model("po").exists():
        rep["cases"]["c2-po-sba"] = _case(
            ctx, "c2-po-sba", "po", c2_sba_elf,
            expect_fields=C2_SBA_PO, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=SBA_EXPECT,
            debug_disable=False)
    if c2_sba_elf is not None and ctx.model("qf").exists():
        rep["cases"]["c2-qf-sba"] = _case(
            ctx, "c2-qf-sba", "qf", c2_sba_elf,
            expect_fields=C2_SBA_QF, expect_success=True,
            plusargs=("+storamic_sba_probe",), expect_sba=SBA_EXPECT,
            debug_disable=False)
    # ---- case c: IO role virtio pos/neg ------------------------------------
    if virtio_pos_elf is not None and ctx.model("io").exists():
        nat_sem = {"m2_aw": 0, "m2_ar": 0, "src_ok_aw": 0, "src_ok_ar": 0,
                   "pending": 0, "violations": 0}
        rep["cases"]["virtio-io-pos"] = _case(
            ctx, "virtio-io-pos", "io", virtio_pos_elf,
            expect_fields=nat_sem,
            expect_gt={"beats2": 0, "max_lid": 0},
            expect_success=True)
    if virtio_neg_elf is not None and ctx.model("io").exists():
        rep["cases"]["virtio-io-neg"] = _case(
            ctx, "virtio-io-neg", "io", virtio_neg_elf,
            expect_fields={"violations": 0, "pending": 0},
            expect_success=False, expect_fail_tohost=16)

    # ---- case d: default-config lint ---------------------------------------
    e = dict(ctx.env); e["G6LC_STORAMIC_DEFINES"] = DEFS_DEFAULT
    rc, dt, txt = sh(["make", "verilate", f"target={TARGET}",
                      "ver-library=work-ver-default",
                      f"verilator={ctx.verilator}",
                      f"VERILATOR_INSTALL_DIR={ctx.vroot}", f"RISCV={RISCV}",
                      f"SPIKE_INSTALL_DIR={SPIKE}", "G6LC_STORAMIC_DEFINES=",
                      f"NUM_JOBS={e['NUM_JOBS']}"],
                     ctx.src, e, ctx.out / "verilate-default.log",
                     timeout=BUILD_TIMEOUT)
    gen = ctx.src / "work-ver-default"
    leak = []
    leak_ext = {".cpp", ".h", ".hpp", ".cc", ".cxx", ".v", ".sv",
                ".svh", ".vh", ".tree", ".mk", ".d"}
    if gen.is_dir():
        for p in gen.rglob("*"):
            if not p.is_file() or p.suffix not in leak_ext:
                continue
            try:
                c = p.read_text(errors="replace")
            except Exception:
                continue
            if "i_storamic_route" in c or "i_storamic_c2_monitor" in c:
                leak.append(str(p.relative_to(gen)))
    lint_ok = (rc == 0 and txt.count("%Error") == 0 and not leak)
    rep["cases"]["lint-default"] = {
        "make_rc": rc, "seconds": round(dt, 1),
        "verilator_errors": txt.count("%Error"),
        "leak_files": leak[:20],
        "status": "pass" if lint_ok else "fail", "pass": lint_ok}
    rep["builds"].append({"model": "default", "defines": DEFS_DEFAULT,
                          "rc": rc, "seconds": round(dt, 1),
                          "ok": rep["cases"]["lint-default"]["pass"]})

    # ---- case e: mutants ----------------------------------------------------
    rep["mutants"] = run_mutants(ctx, c2_elf, po_max_lid,
                                 c2_sba_elf=c2_sba_elf)
    rep["m5_width"] = m5_width_for(po_max_lid)

    # ---- verdict -------------------------------------------------------------
    sba_ok = (rep["cases"].get("c2-po-sba", {}).get("pass") and
              rep["cases"].get("c2-qf-sba", {}).get("pass"))
    rep["port1_native_traffic"] = "exercised" if sba_ok else "not-exercised"
    # Aggregate per-item status. A definite deviation (wrong count, leaked
    # instance, mutant that ran clean) is FAIL; a missing report line,
    # timeout, build/identity gap, or unexercised mutant is INCOMPLETE; only
    # an all-clean matrix is PASS.
    def _st(rec):
        if not isinstance(rec, dict):
            return None
        return rec.get("status") or ("pass" if rec.get("pass") else "fail")
    statuses = [_st(r) for r in rep["cases"].values()]
    statuses += [_st(m) for m in rep["mutants"].values()]
    statuses = [s for s in statuses if s]
    if "fail" in statuses:
        rep["verdict"] = "FAIL"
    elif rep["incomplete"] or "incomplete" in statuses:
        rep["verdict"] = "INCOMPLETE"
    else:
        rep["verdict"] = "PASS"
    (ctx.out / "native-c2.json").write_text(json.dumps(rep, indent=2))
    return rep


def _patch_span(t, begin, end, old, new):
    """Return t with the first ``old``->``new`` inside the span
    [begin, end] rewritten, or None if the span/needle is absent. Used to hit
    one module's parameter without touching an identical parameter on the
    sibling instance (route vs monitor both set .LocalIdWidth)."""
    i = t.find(begin)
    if i < 0:
        return None
    j = t.find(end, i + len(begin))
    if j < 0:
        return None
    j += len(end)
    seg = t[i:j]
    if old not in seg:
        return None
    return t[:i] + seg.replace(old, new, 1) + t[j:]


def _sim_reason(sim):
    nat = sim.get("native") or {}
    return (f"success={sim.get('success')} fatal={sim.get('fatal')} "
            f"fatal_msg={sim.get('fatal_msg')!r} "
            f"src_ok_aw={nat.get('src_ok_aw')} src_ok_ar={nat.get('src_ok_ar')} "
            f"violations={nat.get('violations')} pending={nat.get('pending')}")


# --- mutant source patches (module-level so the unit suite can apply them) --
def _mut_patch_m1(t):
    """m1: route TrustedMaster 0->1 -> trusted-port source_ok candidates die."""
    for old, new in ((".TrustedMaster(0)", ".TrustedMaster(1)"),
                     (".TrustedMaster(1'b0)", ".TrustedMaster(1'b1)")):
        if old in t:
            return t.replace(old, new, 1)
    return None


def _mut_patch_m2(t):
    """m2: route .LocalIdWidth -> IdWidth+1 -> ROUTE_CONFIG fatal at t=0."""
    return _patch_span(t, "g6lc_storamic_checkpoint_route",
                       ") i_storamic_route",
                       ".LocalIdWidth(ariane_axi_soc::IdWidth)",
                       ".LocalIdWidth(ariane_axi_soc::IdWidth + 1)")


def _mut_patch_m3(t):
    """m3: storamic_rule end_addr halved -> TOPOLOGY rule_range fatal."""
    old = ("end_addr: ariane_soc::StoramicBase + "
           "ariane_soc::StoramicLength")
    new = ("end_addr: ariane_soc::StoramicBase + "
           "(ariane_soc::StoramicLength >> 1)")
    return t.replace(old, new, 1) if old in t else None


def _mut_patch_m4(t):
    """m4: swap c2_slv_resp slave[0]<->[1] taps -> response-port fatal."""
    old = "AXI_ASSIGN_TO_RESP(c2_slv_resp[gi], slave[gi])"
    new = ("AXI_ASSIGN_TO_RESP(c2_slv_resp[gi], "
           "slave[(gi == 0) ? 1 : ((gi == 1) ? 0 : gi)])")
    return t.replace(old, new, 1) if old in t else None


def _mut_patch_m5(t, width):
    """m5: monitor .LocalIdWidth -> ``width`` -> prefix/payload fatal.

    ``width`` is derived from the measured c2-po max_lid (floor(log2)) so the
    mutant is provably non-equivalent on the exercised traffic. Only the
    monitor instance's parameter is touched; .IdWidthSlave stays unchanged.
    """
    return _patch_span(t, "g6lc_storamic_c2_monitor",
                       ") i_storamic_c2_monitor",
                       ".LocalIdWidth(ariane_axi_soc::IdWidth)",
                       f".LocalIdWidth({width})")


M5_KILL_TOKENS = ("aw_bad_prefix", "ar_bad_prefix", "aw_unmatched",
                  "ar_unmatched", "aw_payload", "ar_payload")


def _judge_m5(sim):
    """m5 kill judge: a runtime monitor violation on prefix/payload decode.

    Only a ``STORAMIC_C2_VIOLATION`` fatal carrying one of the decode tokens
    counts. An elaboration/config %Error (e.g. a parameter consistency check
    tripping before any traffic) is NOT an acceptable kill -> (False, note).
    """
    blob = ((sim.get("fatal_msg") or "") + "\n" +
            (sim.get("tail") or ""))
    if not sim.get("fatal"):
        return False, "no fatal"
    for tok in M5_KILL_TOKENS:
        if tok in blob:
            return True, f"monitor fatal {tok}"
    return False, "fatal without monitor decode violation (elaboration?)"


def _mutant_status(good, sim):
    """Map a mutant sim result to a stage-contribution status.

    ``good`` is the per-mutant judge's failed_as_expected verdict. A mutant
    that ran to a clean pass (success, report present, no fatal, violations=0)
    proves the guarded check is dead -> ``fail``. An inconclusive run (no
    report line, timeout, build gap) -> ``incomplete``. Otherwise the mutant
    failed as expected -> ``pass``.
    """
    nat = sim.get("native") or {}
    clean_pass = (sim.get("success") and not sim.get("fatal")
                  and sim.get("native") is not None
                  and nat.get("violations") == 0)
    if good:
        return "pass"
    if clean_pass:
        return "fail"
    return "incomplete"


def run_mutants(ctx, c2_elf, max_lid=None, c2_sba_elf=None):
    """Build each mutant from a patched copy inside the run dir.

    Every mutant patches only ``ariane_testharness.sv`` in the extracted run
    tree, builds a dedicated ``work-ver-mut-*`` model under the primary
    probe-on define set, and runs the C2 firmware. A mutant that completes
    cleanly (success + no fatal + correct counts) is recorded ``pass=False``
    so the stage fails — the mutant proved the check is dead.

    ``max_lid`` is the measured c2-po monitor ``max_lid``; m5's mutant width
    is derived from it so the mutant is provably non-equivalent. When it is
    zero/unknown no valid width exists and m5 is recorded ``incomplete``.
    """
    mutants = {}
    src = ctx.src
    hpath = src / HARNESS
    orig = hpath.read_text()
    m5_width = m5_width_for(max_lid)

    def _has(sim, *subs):
        blob = ((sim.get("fatal_msg") or "") + "\n" +
                (sim.get("tail") or ""))
        return any(s in blob for s in subs)

    # (name, patch, expected-reason desc, judge(sim)->(failed_as_expected, note),
    #  plusargs)
    specs = [
        ("m1-trustedmaster", _mut_patch_m1,
         "src_ok count mismatch or source_ok monitor fatal",
         lambda s: ((lambda n: (n.get("src_ok_aw") != 9 or
                                n.get("src_ok_ar") != 14 or
                                s.get("fatal") or not s.get("success"))
                    )((s.get("native") or {})),
                    "src_ok not 9/14 or fatal"), ()),
        ("m2-localidwidth", _mut_patch_m2,
         "STORAMIC_CHECKPOINT_ROUTE_CONFIG fatal at time 0",
         lambda s: (_has(s, "STORAMIC_CHECKPOINT_ROUTE_CONFIG") or
                    (s.get("fatal") and s.get("rc") != 0),
                    "route config fatal"), ()),
        ("m3-rule-range", _mut_patch_m3,
         "STORAMIC_C2_TOPOLOGY rule_range fatal",
         lambda s: (_has(s, "rule_range", "STORAMIC_C2_TOPOLOGY") or
                    (s.get("fatal") and s.get("rc") != 0),
                    "topology rule_range fatal"), ()),
        ("m4-tapswap", _mut_patch_m4,
         "response-port fatal (b_spurious/r_spurious/*_without_device)",
         lambda s: (s.get("fatal") and _has(
             s, "spurious", "without_device", "unmatched", "bad_prefix",
             "payload", "w_no_owner"), "response-port fatal"), ()),
        # m6: same TrustedMaster flip as m1 but with real port-1 SBA traffic
        # present. The monitor's src_shape model is port-0-only, so the flip
        # must still die on *_source_ok_value — and the SBA probe line proves
        # port 1 was exercised while the check fired.
        ("m6-trustedmaster-sba", _mut_patch_m1,
         "aw/ar_source_ok_value monitor fatal with port-1 SBA traffic",
         lambda s: (_has(s, "source_ok_value") and
                    (s.get("sba_probe") or {}).get("reads") == 1 and
                    (s.get("sba_probe") or {}).get("writes") == 1,
                    "source_ok_value fatal + SBA exercised"),
         ("+storamic_sba_probe",)),
    ]
    if m5_width is not None:
        specs.append(
            ("m5-monitor-idw",
             lambda t, w=m5_width: _mut_patch_m5(t, w),
             f"monitor decode fatal at LocalIdWidth={m5_width} "
             "(aw/ar_bad_prefix|unmatched|payload)",
             _judge_m5, ()))
    else:
        mutants["m5-monitor-idw"] = {
            "mutant": "m5-monitor-idw",
            "expected_reason": "monitor decode fatal at derived width",
            "m5_width": None, "max_lid": max_lid,
            "error": "max_lid=0/unknown: no non-equivalent LocalIdWidth",
            "status": "incomplete", "pass": False}

    for name, patch, reason, judge, plusargs in specs:
        mrec = {"mutant": name, "expected_reason": reason}
        # m6 exercises port-1 SBA traffic: it needs the delayed-spin ELF so
        # the DTM init + SBA sequence completes before the source_ok fatal.
        elf = c2_sba_elf if name == "m6-trustedmaster-sba" else c2_elf
        if name == "m5-monitor-idw":
            mrec["m5_width"] = m5_width
            mrec["max_lid"] = max_lid
        new_text = patch(orig)
        if new_text is None or new_text == orig:
            mrec["error"] = "mutant patch not applied (pattern miss)"
            mrec["status"] = "incomplete"
            mrec["pass"] = False
            mutants[name] = mrec
            continue
        tag = "mut-" + name
        hpath.write_text(new_text)
        try:
            ok, dt = ctx.ensure_model(tag, DEFS_PO)
            mrec["build_ok"] = ok
            mrec["build_seconds"] = round(dt, 1)
            if not ok:
                blog = ctx.out / f"verilate-{tag}.log"
                btxt = blog.read_text(errors="replace") if blog.exists() else ""
                mrec["build_log_tail"] = btxt[-400:]
                mrec["status"] = "incomplete"
                mrec["pass"] = False
                mrec["judge"] = "mutant model build failed"
            elif elf is None:
                mrec["error"] = "c2 firmware ELF missing"
                mrec["status"] = "incomplete"
                mrec["pass"] = False
            else:
                # m6 needs exercised port-1 SBA traffic, so like the SBA
                # cases it runs without +debug_disable (halt(0) must reach
                # htif_t::run()->reset()). Every other mutant keeps it.
                sim = ctx.run_sim(tag, elf, plusargs=plusargs,
                                  debug_disable=(name !=
                                                 "m6-trustedmaster-sba"))
                good, note = judge(sim)
                mrec["sim"] = {"rc": sim["rc"], "success": sim["success"],
                               "fatal": sim["fatal"],
                               "fatal_msg": sim.get("fatal_msg"),
                               "native_line": sim.get("native_line"),
                               "topology_line": sim.get("topology"),
                               "sba_probe": (sim.get("sba_probe") or {})
                                            .get("line"),
                               "reason": _sim_reason(sim)}
                mrec["failed_as_expected"] = bool(good)
                mrec["judge"] = note
                if name == "m5-monitor-idw":
                    mrec["kill_reason"] = note
                # pass=failed-as-expected; fail=ran to a clean pass (the
                # guarded check is dead); incomplete=no verdict evidence.
                mrec["status"] = _mutant_status(good, sim)
                # m6 must be killed WITH port-1 SBA traffic actually
                # exercised. A source_ok fatal with no/partial SBA evidence
                # is a vacuous kill (it is m1's evidence, not m6's) -> fail,
                # not incomplete. No fatal at all is handled by
                # _mutant_status (clean pass -> fail; no report -> incomplete).
                if name == "m6-trustedmaster-sba" and sim.get("fatal"):
                    sba = sim.get("sba_probe") or {}
                    if not (sba.get("reads") == 1 and sba.get("writes") == 1):
                        mrec["status"] = "fail"
                        mrec["judge"] = ("vacuous kill: fatal without "
                                         "exercised SBA traffic")
                mrec["pass"] = mrec["status"] == "pass"
        finally:
            hpath.write_text(orig)
        mutants[name] = mrec
    return mutants


def _extract_tar(src_tar, dest):
    dest = Path(dest)
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True, exist_ok=True)
    with tarfile.open(src_tar) as t:
        for m in t.getmembers():
            if m.name.startswith("/") or ".." in Path(m.name).parts:
                raise RuntimeError(f"unsafe tar member {m.name}")
        t.extractall(dest)
    return dest


def _tools(src):
    """Resolve + verify tool identity from storamic_tools.json in the tree.

    Returns ``(record, verilator_path, verilator_root, error)``. The Verilator
    compiler binary's sha256 must equal the recorded ``compiler_sha256``;
    any mismatch (or an absent/unparseable record) is an identity failure the
    caller turns into ``incomplete``.
    """
    tj = src / TOOLS_JSON
    rec = {"tools_json": TOOLS_JSON,
           "leaf_verilator": None}
    if not tj.is_file():
        return rec, None, None, "missing storamic_tools.json in source tar"
    rec["tools_json_sha256"] = sha256_file(tj)
    try:
        j = json.loads(tj.read_text())
    except Exception as exc:
        return rec, None, None, f"storamic_tools.json parse: {exc}"
    vt = j.get("verilator", {})
    # storamic_tools.json keys the Verilator fields as
    # {head, verilator(path), compiler_sha256, runtime_header_sha256}.
    verilator = vt.get("verilator") or vt.get("path")
    comp_sha = vt.get("compiler_sha256")
    rec["verilator"] = verilator
    rec["verilator_head"] = vt.get("head")
    rec["verilator_expected_sha256"] = comp_sha
    rec["verilator_runtime_header_sha256"] = vt.get("runtime_header_sha256")
    yt = j.get("yosys", {})
    rec["yosys_sha256"] = yt.get("sha256")
    rec["yosys_head"] = yt.get("head")
    rec["solver_bin"] = j.get("solver_bin")
    if not verilator or not Path(verilator).is_file():
        return rec, None, None, f"verilator path absent: {verilator}"
    vbin = Path(verilator).with_name("verilator_bin")
    actual = sha256_file(vbin) if vbin.is_file() else None
    rec["verilator_bin_sha256"] = actual
    if not comp_sha or actual != comp_sha:
        return rec, None, None, (
            f"verilator_bin sha256 mismatch: {actual} != {comp_sha}")
    rec["verilator_root"] = str(Path(verilator).parent.parent)
    return rec, verilator, rec["verilator_root"], None


class _Incomplete(Exception):
    """Raised for timeout / missing report line / identity mismatch so the
    leaf records status ``incomplete`` (a non-RuntimeError)."""


def run(data, out, stages, manifest, builds, outcomes, verilator, build_model):
    """run_leaf.py stage entry for ``native-c2``.

    Builds ariane_testharness only from the frozen, manifest-hashed source tar
    uploaded for this run — never a shared work tree. Tool identity comes from
    the tar's storamic_tools.json (Verilator compiler sha256 verified; gcc and
    libfesvr sha256 recorded). Returns normally only on PASS; raises
    RuntimeError on FAIL and _Incomplete on INCOMPLETE so the leaf propagates
    the verdict.
    """
    data = Path(data); out = Path(out); out.mkdir(parents=True, exist_ok=True)
    src_tar = data / SRC_TAR_NAME
    expected = (manifest.get("sources") or {}).get(SRC_TAR_NAME)
    rep = {"stage": "native-c2", "src_tar": str(src_tar),
           "leaf_verilator": str(verilator) if verilator else None}

    def _inc(reason):
        rep["verdict"] = "incomplete"
        rep["reason"] = reason
        (out / "native-c2.json").write_text(json.dumps(rep, indent=2))
        outcomes.append({"native_c2": "incomplete", "reason": reason,
                         "pass": False})
        raise _Incomplete(reason)

    if not src_tar.is_file():
        _inc(f"missing {SRC_TAR_NAME} in run data")
    actual = sha256_file(src_tar)
    rep["src_tar_sha256"] = actual
    if expected and actual != expected:
        _inc("source tar sha256 mismatch vs manifest")
    # Build the extracted tree + all Verilator Mdirs under the run's kept-local
    # ``work/`` dir so the ~9 ariane_testharness binaries are not pulled back
    # with ``output/``. Only logs/JSON evidence land in ``out``.
    run_dir = Path(os.environ.get("TH_RUN_DIR") or out.parent)
    work = run_dir / "work" / "native-c2"
    rep["work_dir"] = str(work)
    try:
        src = _extract_tar(src_tar, work / "src")
    except Exception as exc:
        _inc(f"source tar extract failed: {exc}")
    tools, verilator_use, vroot_use, terr = _tools(src)
    rep["tools"] = tools
    if terr:
        _inc(terr)
    env = base_env(verilator_use, vroot_use)
    ctx = Ctx(src, out, verilator_use, vroot_use, env)
    result = execute(ctx)
    result.update({"tools": tools, "leaf_verilator": rep["leaf_verilator"]})
    (out / "native-c2.json").write_text(json.dumps(result, indent=2))
    verdict = result.get("verdict", "incomplete")
    def _st(rec):
        return (rec.get("status") or ("pass" if rec.get("pass") else "fail")
                ) if isinstance(rec, dict) else None
    outcomes.append({"native_c2": verdict, "verdict": verdict,
                     "incomplete": result.get("incomplete", []),
                     "pass": verdict == "PASS",
                     "cases": {k: _st(v) for k, v in
                               result.get("cases", {}).items()},
                     "mutants": {k: _st(v) for k, v in
                                 result.get("mutants", {}).items()}})
    if verdict == "PASS":
        return
    if verdict == "FAIL":
        bad = [k for k, v in result.get("cases", {}).items()
               if isinstance(v, dict) and not v.get("pass")]
        bad += [k for k, v in result.get("mutants", {}).items()
                if isinstance(v, dict) and not v.get("pass")]
        raise RuntimeError("native-c2 FAIL: " + ", ".join(bad or ["unknown"]))
    raise _Incomplete("; ".join(result.get("incomplete") or ["incomplete"]))


def main():
    """Ad-hoc entry: run the matrix against an already-extracted tree.

    Not the qualification path — ``run_leaf`` uses ``run()`` which builds from
    the manifest-hashed source tar. ``C2_WORK`` points at a tree that already
    contains Makefile/RTL/firmware (e.g. a manual extraction for debugging).
    """
    work = Path(os.environ.get("C2_WORK", "/opt/testharness/work/c2-native"))
    out = Path(os.environ.get("C2_OUT", "output")); out.mkdir(exist_ok=True)
    tools, v, vr, terr = _tools(work)
    if terr:
        print(f"[native-c2] tool identity: {terr}", flush=True)
        return 1
    env = base_env(v, vr)
    ctx = Ctx(work, out, v, vr, env)
    rep = execute(ctx)
    rep.update({"tools": tools})
    (out / "native-c2.json").write_text(json.dumps(rep, indent=2))
    return 0 if rep.get("verdict") == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
