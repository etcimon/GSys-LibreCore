#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 leaf runner: HYP8_LEAF=memory|csr|csr-credit|issue|dispatch|realign|queue|alu
selects the boundary
under test while sharing one closure/upload/runtime mechanism.

  memory  g6lc_prf read-enable hold + write select, stb_insert pending
          reservation, stb_fwd payload snapshot / committed-pending.
  csr     commit_stage + csr_buffer + csr_regfile common-event seam:
          two-phase request, ID-qualified completion, apply at the same
          commit_ack_o, halted/no-request response, trap, flush, WFI,
          MRET, counter carry. Copied-source negatives: delayed ack,
          commit-gated address.
  issue   g6lc_iq_payload + g6lc_iq_arb + g6lc_flu_reserve: registered
          grant payload, held presentation, serial port-0 restriction,
          IRO-acceptance reservation distances and divider ownership.
          Copied-source negative: combinational payload read.
  dispatch the real g6lc_ooo_dispatch + children on the full core flist
          (Flist.g6lc_hyp8): busy-bitmap IQ allocation wakeup through the
          rename window (int and FP), intra-group RAW, and checkpoint
          retire-between-select-and-repair ownership.

Isolated uploaded source closure (the hyp8 core flist materialized under
data/), pinned private verilator runtime, --timing --assert --threads 1.
No global warning suppression that would hide WIDTH/IMPLICIT/MULTIDRIVEN/
LATCH failures: the build log is scanned for those classes explicitly.
Only the leaf bench is compiled and reported; the flist supplies package
dependencies, not core elaboration."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

COMMON = [
    'config_pkg.sv',
    'build_config_pkg.sv',
    'g6lc_hyp_pkg.sv',
    'g6lc64_hyp8_config_pkg.sv',
    'riscv_pkg.sv',
    'g6lc_core_pkg.sv',
]
LEAFS = {
    'pmp-write': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'g6lc_hyp8_pmp_bank_reference.sv',
            'g6lc_hyp8_pmp_bank_candidate.sv', 'tb_g6lc_hyp8_control.sv'],
        'includes': ['g6lc_core_types.svh', 'rvfi_types.svh'],
        'top': 'tb_g6lc_hyp8_pmp_write',
        'model': 'hyp8_pmp_write',
        'token': 'HYP8_PMP_WRITE_PASS',
        'verify_manifest': True,
        'x_initial_edge': True,
        'strict_widths': True,
    },
    'memory': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'g6lc_prf.sv', 'stb_insert.sv', 'stb_fwd.sv',
            'store_buffer.sv', 'stb_commit.sv', 'stb_drain.sv',
            'cf_math_pkg.sv', 'g6lc_hyp_lzc.sv', 'load_unit.sv',
            'tb_g6lc_hyp8_memory.sv',
        ],
        'includes': [],
        'top': 'tb_g6lc_hyp8_memory',
        'model': 'hyp8_memory',
        'token': 'HYP8_MEMORY_PASS',
    },
    'csr': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv',
            'csr_decode.sv', 'csr_read.sv', 'csr_trap.sv', 'csr_irq.sv',
            'csr_counters.sv', 'csr_write.sv', 'csr_regfile.sv',
            'csr_buffer.sv', 'commit_stage.sv',
            'mut_commit_stage_delayed.sv', 'mut_csr_buffer_gated.sv',
            'tb_g6lc_hyp8_control.sv',
        ],
        'includes': ['g6lc_core_types.svh', 'rvfi_types.svh'],
        'top': 'tb_g6lc_hyp8_csr',
        'model': 'hyp8_csr',
        'token': 'HYP8_CSR_PASS',
    },
    'csr-credit': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'csr_buffer.sv',
            'tb_g6lc_hyp8_csr_credit.sv',
        ],
        'top': 'tb_g6lc_hyp8_csr_credit',
        'model': 'hyp8_csr_credit',
        'token': 'HYP8_CSR_CREDIT_PASS',
        'verify_manifest': True,
        'x_initial_edge': True,
        'strict_widths': True,
    },
    'issue': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'g6lc_iq_payload.sv', 'mut_iq_payload_comb.sv',
            'g6lc_iq_arb.sv', 'g6lc_flu_reserve.sv',
            # IRO stale-lane section (h33 regression): the real
            # issue_read_operands; helper packages precede it in compile
            # order, and its leaf children close the instantiation set.
            'g6lc_sb_keep.sv', 'g6lc_rvc_enc.sv', 'g6lc_jalr_usable.sv',
            'raw_checker.sv',
            'cvxif_issue_register_commit_if_driver.sv',
            'g6lc_regfile_ff.sv', 'g6lc_regfile_fpga.sv',
            'g6lc_smt_regfile.sv', 'issue_read_operands.sv',
            'tb_g6lc_hyp8_control.sv',
        ],
        'includes': ['g6lc_core_types.svh', 'rvfi_types.svh'],
        'top': 'tb_g6lc_hyp8_issue',
        'model': 'hyp8_issue',
        'token': 'HYP8_ISSUE_PASS',
    },
    'mshr': {
        'sources': [
            'g6lc_l2_mshr.sv', 'g6lc_l2_mshr_reference.sv',
            'tb_g6lc_l2_units.sv'],
        'includes': [],
        'top': 'tb_g6lc_hyp8_mshr',
        'model': 'hyp8_mshr',
        'token': 'HYP8_MSHR_PASS',
        'verify_manifest': True,
        'x_initial_edge': True,
        'strict_widths': True,
    },
    'lsq-credit': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'g6lc_lsq_event.sv', 'g6lc_lsq_slot.sv',
            'g6lc_lsq_cam_bank.sv', 'g6lc_lsq_age.sv', 'g6lc_lsq_reduce.sv',
            'g6lc_lsq_verdict.sv', 'g6lc_lsq_release.sv', 'g6lc_lsq.sv',
            'tb_g6lc_hyp8_control.sv'],
        'includes': ['g6lc_core_types.svh', 'rvfi_types.svh'],
        'extra_defines': ['G6LC_HYP8_LSQ_LEAF'],
        'top': 'tb_g6lc_hyp8_lsq',
        'model': 'hyp8_lsq_credit',
        'token': 'HYP8_LSQ_CREDIT_PASS',
        'verify_manifest': True,
        'x_initial_edge': True,
        'strict_widths': True,
    },
    'flu': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'g6lc_flu_reserve.sv', 'tb_g6lc_hyp8_control.sv'],
        'includes': ['g6lc_core_types.svh', 'rvfi_types.svh'],
        'top': 'tb_g6lc_hyp8_flu',
        'model': 'hyp8_flu',
        'token': 'HYP8_FLU_PASS',
        'verify_manifest': True,
        'x_initial_edge': True,
        'strict_widths': True,
    },
    # r68 IQ legality occupant-identity leaf: the real g6lc_iq_legal behind
    # a bank stand-in with the bank's pend-staged allocation timing. A
    # head-only (AMO/LR/SC, system CSR, CVXIF) occupant is never legal
    # off the commit head -- not even in its first live cycle, whatever
    # record its slot held before (the r62 kernel LR/SC wedge owner); a
    # fresh load/store/CSR waits for facts computed for itself. Negative
    # control: HYP8_EXTRA_DEFINES=G6LC_MUT_IQLEG_STALE_OCCUPANT -> L1 fails
    # by name and the module's own r68 assertion fires.
    'iqleg': {
        'sources': COMMON + [
            'g6lc_ooo_pkg.sv', 'g6lc_iq_legal.sv',
            'tb_g6lc_hyp8_iqleg.sv',
        ],
        'includes': [],
        'top': 'tb_g6lc_hyp8_iqleg',
        'model': 'hyp8_iqleg',
        'token': 'HYP8_IQLEG_PASS',
    },
    # The dispatch leaf compiles the actual full core flist (the uploaded
    # closure carries Flist.g6lc_hyp8 plus every source and include-dir
    # file it names) rather than a hand-picked subset: the seam under test
    # is the whole g6lc_ooo_dispatch hierarchy with real children.
    'dispatch': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'top': 'tb_g6lc_hyp8_dispatch',
        'model': 'hyp8_dispatch',
        'token': 'HYP8_DISPATCH_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # Same full-flist closure as dispatch (instr_realign.sv is already a
    # flist source); the top is the dedicated carry-bank bench. The $unit
    # DPI decl in id_stage.sv lands in the same generated DepSet object as
    # package helpers this top references, so the link needs the MIT peek
    # stub (dead code under this top; the real peek belongs to the
    # testharness).
    'realign': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_realign',
        'model': 'hyp8_realign',
        'token': 'HYP8_REALIGN_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # Nextline kernel + line table bench (tb_g6lc_hyp8_linecheck): the
    # fetch-window line-table/tag-domain seam that owns g6lc_fe_override
    # verdict inputs. Same full-flist closure and stub rationale as
    # realign.
    'linecheck': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_linecheck',
        'model': 'hyp8_linecheck',
        'token': 'HYP8_LINECHECK_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # Same full-flist closure as realign: instr_queue/alu are flist
    # sources and each top gets its own dedicated bench. The $unit peek
    # stub rationale is identical (dead code under these tops).
    'queue': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_queue',
        'model': 'hyp8_queue',
        'token': 'HYP8_QUEUE_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    'alu': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_alu',
        'model': 'hyp8_alu',
        'token': 'HYP8_ALU_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # ROM boundary leaf: the APU-side adapter/ROM pair is not on the core
    # flist, so the leaf carries them as ordered extra sources (packages
    # before the modules that take their types; g6lc_config_pkg/axi_pkg
    # are already flist units).
    'rom': {
        'flist': 'core/Flist.g6lc_hyp8',
        'extra': [
            'g6lc_axi_pkg.sv',
            'g6lc_soc_pkg.sv',
            'g6lc_axi_soc_pkg.sv',
            'g6lc_axi2mem_reg.sv',
            'bootrom.sv',
        ],
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        # The shared bench guards the rom top on this define: other leaves
        # do not compile the APU-side AXI packages its ports name.
        'extra_defines': ['G6LC_HYP8_ROM_LEAF'],
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_rom',
        'model': 'hyp8_rom',
        'token': 'HYP8_ROM_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # Data-PMP leaf: pmp_data_if/pmp/pmp_entry are already flist sources;
    # the bench top exercises the DATA_VERDICT_STAGES=0 same-cycle data
    # contract (the staged variant's two-cycle paddr/exception delay was
    # the r9 lost-store root cause).
    'pmp': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_pmp',
        'model': 'hyp8_pmp',
        'token': 'HYP8_PMP_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # D$ store->load forwarding leaf: the actual wt_dcache (read ctrls,
    # tag/data mem, wbuffer, missunit) behind a single-outstanding memory
    # model; drives the h33 pattern (forward at request distances 0..4,
    # byte merge, coalesce). Default builds Hyp8 (DcacheHitExtra=2);
    # HYP8_EXTRA_DEFINES=G6LC_HYP8_DCHX0 builds the same bench against the
    # DcacheHitExtra=0 reference single-cycle read-ctrl arm.
    'dcache': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'extra_defines': ['G6LC_HYP8_DCACHE_LEAF'],
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_dcache',
        'model': 'hyp8_dcache',
        'token': 'HYP8_DCACHE_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # LSQ memory-order leaf: the actual g6lc_lsq (event staging, STL/vio
    # CAM banks, reduce, verdict, slot/release) behind a directed bench.
    # G1: store address resolves after a younger load's verdict ->
    # mem_violation names the load (replay required).  G2a/G2b: store
    # resolved at the verdict (data late / data present) -> later
    # data/commit/phys events produce no violation.
    'lsq': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'extra_defines': ['G6LC_HYP8_LSQ_LEAF'],
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_lsq',
        'model': 'hyp8_lsq',
        'token': 'HYP8_LSQ_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # MMU leaf (r45): UseSharedTlb=0 miss/return specialization
    # (g6lc_tlb_miss_router) mitred against the real g6lc_shared_tlb's
    # bypass arm on every output every cycle, plus the g6lc_tlb
    # row-flush-predicate rewrite exercised by fill/lookup/flush with an
    # independent entry-outcome oracle. A bench-embedded router copy with
    # its I-return arm suppressed is the negative control.
    'mmu': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'extra_defines': ['G6LC_HYP8_MMU_LEAF'],
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_mmu',
        'model': 'hyp8_mmu',
        'token': 'HYP8_MMU_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # Controller flush-gate leaf (r28): an invalid resolve record (valid=0)
    # must raise no flush even with a stale is_mispredict=1 field standing
    # (the ghost-flush/FTQ-reseed loss of the redirect target); a valid
    # mispredict keeps the IF+unissued contract. Mutant A/B:
    # HYP8_EXTRA_DEFINES=G6LC_MUT_CTRL_STALE_RESOLVE restores the ungated
    # leg -> CTRL_STALE_RESOLVE_NO_FLUSH fails.
    'ctrl': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_ctrl',
        'model': 'hyp8_ctrl',
        'token': 'HYP8_CTRL_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
    # Loop-buffer hit-identity leaf (r31): the real g6lc_loop_buffer on the
    # full flist. A hit registered for head H must not inject H's block under
    # a different head/epoch, and a flush coincident with detection must not
    # re-arm. Mutant A/B: HYP8_EXTRA_DEFINES=G6LC_MUT_LBUF_STALE_HIT restores
    # consume-without-identity -> LBUF_STALE_NO_INJECT fails.
    'lbuf': {
        'flist': 'core/Flist.g6lc_hyp8',
        'bench': 'verif/tb/core/tb_g6lc_hyp8_control.sv',
        'stub': 'verif/tb/apu/g6lc_dram_peek64_stub.cpp',
        'top': 'tb_g6lc_hyp8_lbuf',
        'model': 'hyp8_lbuf',
        'token': 'HYP8_LBUF_PASS',
        'verilate_timeout': 1800,
        'make_timeout': 1800,
    },
}
# Fatal-if-seen diagnostics (unchanged escalation): exact class tokens so
# WIDTHCONCAT/WIDTHEXPAND/WIDTHTRUNC are never counted as WIDTH.
WARN_CLASSES = ('%Warning-WIDTH:', '%Warning-IMPLICIT:',
                '%Warning-MULTIDRIVEN:', '%Warning-LATCH:', '%Error')
# Open diagnostics: counted and reported under their own exact class names
# but NOT escalated (acceptance policy unchanged). These classes were
# requested as a distinct census -- they are real diagnostics, not clean.
OPEN_WARN_CLASSES = ('WIDTHEXPAND', 'WIDTHTRUNC', 'WIDTHCONCAT')
# Reported census: every %Warning-<class>: occurrence counted under its own
# exact class name -- recorded as evidence, not escalated.
WARN_CENSUS = re.compile(r'%Warning-([A-Z]+):')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    leaf = os.environ.get('HYP8_LEAF', 'memory')
    if leaf not in LEAFS:
        raise SystemExit(f'HYP8_LEAF must be one of {sorted(LEAFS)}, got {leaf!r}')
    spec = LEAFS[leaf]
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir(exist_ok=True)
    inputs = []
    hashes = {}

    def pick(name):
        matches = list(data.rglob(name))
        if len(matches) != 1:
            # The uploaded closure must provide exactly one copy: zero is a
            # missing dependency, more than one means a stale shadow could
            # silently substitute for the intended source.
            raise FileNotFoundError(
                f'{name}: expected exactly 1 match, found {len(matches)}')
        return matches[0]

    manifest_hash = None
    if spec.get('verify_manifest'):
        manifest = pick('manifest.json')
        root = manifest.parent.resolve()
        records = json.loads(manifest.read_text())['files']
        if not isinstance(records, dict) or not records:
            raise ValueError('empty or invalid source manifest')
        for rel, expected in records.items():
            hit = (root / rel).resolve()
            if not hit.is_relative_to(root) or not hit.is_file() or digest(hit) != expected:
                raise ValueError(f'source manifest mismatch: {rel}')
        manifest_hash = digest(manifest)
        print(f'HYP8_INPUT_MANIFEST_VERIFIED files={len(records)}')

    for name in spec.get('sources', []):
        dest = source / name
        shutil.copy2(pick(name), dest)
        inputs.append(str(dest))
        hashes[name] = digest(dest)
    for name in spec.get('includes', []):
        # Include-only units are placed in the -I dir but not compiled as
        # standalone sources (macro/type headers, not modules).
        dest = source / name
        shutil.copy2(pick(name), dest)
        hashes[name] = digest(dest)

    incdirs = ['-I' + str(source)]
    defines = []
    if 'flist' in spec:
        # Full-flist leaf: the closure root is the single manifest-bearing
        # directory; the copied flist names every source/incdir/define with
        # ${HYP_CORE_DIR} relative to its hyp_core/ tree.
        roots = [m.parent for m in data.rglob('manifest.json')]
        if len(roots) != 1:
            raise FileNotFoundError(
                f'manifest.json: expected exactly 1 match, found {len(roots)}')
        root = roots[0]
        # Closure layouts: the lead's materialized `hyp_core/` tree, or the
        # repo-relative closure build_closure.py writes (the hyp tree under
        # its build-platform/workspace path).
        hyp_core = 'hyp_core'
        if not (root / 'hyp_core').is_dir() and                 (root / 'build-platform/workspace/hyp/hyp_redesign_core_8fo4').is_dir():
            hyp_core = 'build-platform/workspace/hyp/hyp_redesign_core_8fo4'
        flist = pick(str(Path(spec['flist']).name))
        for line in flist.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('+incdir+'):
                rel = line[len('+incdir+'):].replace('${HYP_CORE_DIR}', hyp_core)
                incdirs.append('-I' + str(root / rel))
            elif line.startswith('+define+'):
                defines.append('-D' + line[len('+define+'):])
            elif line.startswith('+'):
                continue
            else:
                rel = line.replace('${HYP_CORE_DIR}', hyp_core)
                hit = root / rel
                if not hit.is_file():
                    raise FileNotFoundError(f'flist source missing: {rel}')
                inputs.append(str(hit))
                hashes[rel] = digest(hit)
        defines += ['-D' + d for d in spec.get('extra_defines', [])]
        # HYP8_EXTRA_DEFINES: run-scoped defines on top of the leaf spec
        # (e.g. 'G6LC_HYP8_DCHX0' selects the dcache leaf's DcacheHitExtra=0
        # variant without forking the bench).
        defines += ['-D' + d for d in
                    shlex.split(os.environ.get('HYP8_EXTRA_DEFINES', ''))]
        # Ordered extra sources (leaf-external units like the APU-side
        # AXI/ROM pair) compile between the flist and the bench so package
        # order is explicit.
        for name in spec.get('extra', []):
            hit = pick(name)
            inputs.append(str(hit))
            hashes[name] = digest(hit)
        # The bench is not part of the flist; pull it from the same closure.
        bench = pick(str(Path(spec['bench']).name))
        inputs.append(str(bench))
        hashes[spec['bench']] = digest(bench)
        if 'stub' in spec:
            # A .cpp on the verilate command becomes a user compile unit
            # and is linked into the model.
            stub = pick(str(Path(spec['stub']).name))
            inputs.append(str(stub))
            hashes[spec['stub']] = digest(stub)
    (out / 'sources.json').write_text(json.dumps(hashes, indent=2))

    runtime = Path('/opt/testharness/runs/review-private-runtime-20260915/runtime')
    assert digest(runtime / 'include/verilated_funcs.h') == \
        'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    # The managed 5.008-mod build; the proxy PATH does not export it, so the
    # binary is pinned by absolute path like VERILATOR_ROOT itself. Both the
    # perl driver and the actual verilator_bin object are hashed into the
    # results so the toolchain identity is evidence, not just a path.
    verilator_drv = Path('/opt/testharness/src/verilator-causal/bin/verilator')
    verilator_bin = Path('/opt/testharness/src/verilator-causal/bin/verilator_bin')
    assert verilator_drv.is_file(), 'managed verilator missing'
    assert verilator_bin.is_file(), 'managed verilator_bin missing'
    env = dict(os.environ, VERILATOR_ROOT=str(runtime),
               VPATH=str(runtime / 'include'))
    verilator = [str(verilator_drv), '--cc', '--main', '--exe', '--timing',
                 '--assert',
                 *(['--x-initial-edge'] if spec.get('x_initial_edge') else []),
                 *(['-Werror-WIDTH', '-Werror-WIDTHEXPAND', '-Werror-WIDTHTRUNC']
                   if spec.get('strict_widths') else []),
                 '--threads', '1', '-Wno-fatal', '-Werror-LATCH',
                 *(defines if 'flist' in spec else
                   ['-DG6LC_FETCH_B'] + ['-D' + d for d in spec.get('extra_defines', [])] + ['-D' + d for d in shlex.split(
                       os.environ.get('HYP8_EXTRA_DEFINES', ''))]),
                 *incdirs,
                 '--top-module', spec['top']]
    mdir = 'model'
    command = verilator + ['--Mdir', str(out / mdir), '-o', spec['model'],
                           *inputs]
    (out / 'leaf.json').write_text(json.dumps(
        {'leaf': leaf, 'top': spec['top'], 'token': spec['token']}, indent=2))
    (out / f'command-{mdir}.json').write_text(json.dumps(command, indent=2))
    with (out / f'build-{mdir}.log').open('w') as log:
        build = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                               env=env,
                               timeout=spec.get('verilate_timeout', 300))
        if build.returncode != 0:
            raise RuntimeError(f'Verilator failed: build-{mdir}.log')
        build = subprocess.run(
            ['make', '-C', str(out / mdir), '-f', f'V{spec["top"]}.mk',
             '-j2'],
            stdout=log, stderr=subprocess.STDOUT, env=env,
            timeout=spec.get('make_timeout', 300))
    if build.returncode:
        print((out / f'build-{mdir}.log').read_text()[-6000:])
        raise RuntimeError(f'hyp8 {leaf} leaf build failed ({mdir})')
    deps = '\n'.join(path.read_text() for path in (out / mdir).glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in deps, \
        'compiled runtime mismatch'
    # No suppression may have hidden these classes: the build log is evidence.
    log_text = (out / f'build-{mdir}.log').read_text()
    warnings_seen = [w for w in WARN_CLASSES if w in log_text]
    warn_census = {}
    for m in WARN_CENSUS.finditer(log_text):
        warn_census[m.group(1)] = warn_census.get(m.group(1), 0) + 1
    results = [{'log': f'build-{mdir}.log', 'warnings': warnings_seen,
                'sourceManifestSha256': manifest_hash,
                'warningCensus': warn_census,
                'openDiagnostics': {c: warn_census.get(c, 0)
                                    for c in OPEN_WARN_CLASSES},
                'verilatorBinSha256': digest(verilator_bin),
                'verilatorDriverSha256': digest(verilator_drv),
                'modelSha256': digest(out / mdir / spec['model'])}]
    # HYP8_LEAF_ARGS carries explicit plusargs for a single diagnostic run
    # (e.g. '+dispatch_trace'); the empty default leaves the sim command
    # byte-identical to the uninstrumented leaf.
    leaf_args = shlex.split(os.environ.get('HYP8_LEAF_ARGS', ''))
    run = subprocess.run([str(out / mdir / spec['model']), *leaf_args],
                         capture_output=True, text=True, timeout=60)
    text = run.stdout + run.stderr
    (out / 'sim.log').write_text(text)
    print(text)
    results.append({'log': 'sim.log', 'rc': run.returncode,
                    'leafArgs': leaf_args,
                    'matched': run.returncode == 0 and
                    spec['token'] in text})
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    if warnings_seen:
        raise RuntimeError(f'unexpected compiler diagnostics: {warnings_seen}')
    if run.returncode != 0 or spec['token'] not in text:
        raise RuntimeError(f'hyp8 {leaf} leaf test failed')
    print(f'HYP8_{leaf.upper()}_LEAF_PASS warnings=%s census=%s' %
          (warnings_seen or 'none', warn_census))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
