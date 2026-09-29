#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
#
# M4 reduced-geometry FPU synthesis: `fpu_wrap` at the g6lc64_ooo_int2_l3
# shape (FLen=64, OoOEn=1, NR_SB_ENTRIES=8), once with the owner-live writeback
# gate and once with it compiled out via G6LC_MUT_FP_NO_OWNER_LIVE. The
# cell/bit delta is the cost of the T9g owner check on the FP writeback seam.
#
# This is a leaf stat comparison, not a mapped timing run.
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def sha(path):
    import hashlib
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    repo = Path('/opt/testharness/repo')
    flist = (data / 'Flist.cva6').read_text()
    entries = [line.strip().replace('${CVA6_REPO_DIR}/', '') for line in flist.splitlines()
               if line.strip().startswith('${CVA6_REPO_DIR}/')]
    fp = [p for p in entries if p.startswith('core/cvfpu/') and p.endswith(('.sv', '.v'))]
    common = [p for p in entries if p.startswith('vendor/pulp-platform/common_cells/src/')
              and p.endswith('.sv')]
    fixed = ['core/include/config_pkg.sv', 'core/include/g6lc64_ooo_int2_l3_config_pkg.sv',
             'core/include/build_config_pkg.sv', 'core/include/riscv_pkg.sv',
             'core/cvfpu/src/fpnew_pkg.sv', 'core/include/ariane_pkg.sv',
             'core/include/g6lc_core_types.svh']
    paths = list(dict.fromkeys(['vendor/pulp-platform/common_cells/src/cf_math_pkg.sv', *fixed,
                               *common, *fp, 'core/fpu_wrap.sv']))
    pins = {}
    for rel in paths:
        original = data / Path(rel).name
        if not original.is_file():
            original = repo / rel
        dest = source / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, dest)
        pins[rel] = sha(dest)
    includes = []
    for directory in ('vendor/pulp-platform/common_cells/include',
                      'core/cvfpu/src/common_cells/include'):
        if (repo / directory).is_dir():
            for original in (repo / directory).rglob('*.svh'):
                rel = original.relative_to(repo)
                dest = source / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(original, dest)
                pins[str(rel)] = sha(dest)
            includes.append('-I' + str(source / directory))
    top = 'g6lc_fpu_synth'
    wrapper = source / 'g6lc_fpu_synth.sv'
    wrapper.write_text(
        'module ' + top + '\n'
        '  import ariane_pkg::*;\n'
        '(\n'
        '  input  logic        clk_i,\n'
        '  input  logic        rst_ni,\n'
        '  input  logic        flush_i,\n'
        '  input  logic [7:0]  cancelled_mask_i,\n'
        '  input  logic        fpu_valid_i,\n'
        '  output logic        fpu_ready_o,\n'
        '  input  fu_t         fu_i,\n'
        '  input  fu_op        fu_op_i,\n'
        '  input  logic [63:0] fu_operand_a_i, fu_operand_b_i, fu_imm_i,\n'
        '  input  logic [2:0]  fpu_tid_i,\n'
        '  input  logic [1:0]  fpu_fmt_i,\n'
        '  input  logic [2:0]  fpu_rm_i,\n'
        '  input  logic [2:0]  fpu_frm_i,\n'
        '  input  logic [6:0]  fpu_prec_i,\n'
        '  output logic [2:0]  fpu_trans_id_o,\n'
        '  output logic [63:0] result_o,\n'
        '  output logic        fpu_valid_o,\n'
        '  output logic [225:0] fpu_exception_o,\n'
        '  output logic        fpu_early_valid_o\n'
        ');\n'
        '  // Layout-identical to the fu_data_t/exception_t the FU boundary uses;\n'
        '  // same typedef pattern as core/ooo/formal/g6lc_ooo_fp_owner_props.sv.\n'
        '  typedef struct packed {\n'
        '    logic [2:0]   trans_id;\n'
        '    fu_t          fu;\n'
        '    fu_op         operation;\n'
        '    logic [63:0]  operand_a, operand_b, imm;\n'
        '  } fu_typed_t;\n'
        '  typedef struct packed {\n'
        '    logic [63:0] cause, tval, tval2;\n'
        '    logic [31:0] tinst;\n'
        '    logic        gva, valid;\n'
        '  } exc_t;\n'
        '  fu_typed_t fu_data;\n'
        '  assign fu_data = \'{trans_id: fpu_tid_i, fu: fu_i, operation: fu_op_i,\n'
        '                      operand_a: fu_operand_a_i, operand_b: fu_operand_b_i,\n'
        '                      imm: fu_imm_i};\n'
        '  exc_t fpu_exception;\n'
        '  assign fpu_exception_o = fpu_exception;\n'
        '  fpu_wrap #(\n'
        '    .CVA6Cfg(build_config_pkg::build_config(cva6_config_pkg::cva6_cfg)),\n'
        '    .exception_t(exc_t), .fu_data_t(fu_typed_t)\n'
        '  ) dut (\n'
        '    .clk_i, .rst_ni, .flush_i, .cancelled_mask_i,\n'
        '    .fpu_valid_i, .fpu_ready_o, .fu_data_i(fu_data),\n'
        '    .fpu_fmt_i, .fpu_rm_i, .fpu_frm_i, .fpu_prec_i,\n'
        '    .fpu_trans_id_o, .result_o, .fpu_valid_o,\n'
        '    .fpu_exception_o(fpu_exception), .fpu_early_valid_o);\n'
        'endmodule\n')
    results = []
    for label, define in [('owner', ''), ('no_owner', '-DG6LC_MUT_FP_NO_OWNER_LIVE')]:
        inputs = ' '.join(str(source / p) for p in paths)
        script = (f'read_slang --std 1800-2017 {define} {" ".join(includes)} --top {top} '
                  f'{inputs} {wrapper}\n'
                  f'synth -top {top}\ncheck -assert\n'
                  'select -assert-none t:$dlatch t:$_DLATCH_*\nscc -expect 0\n'
                  f'tee -o {out}/fpu_wrap-{label}-stats.json stat -json\n')
        ys = out / f'{label}.ys'
        ys.write_text(script)
        with (out / f'{label}.log').open('w') as log:
            rc = subprocess.run(['yosys', '-s', str(ys)], stdout=log, stderr=subprocess.STDOUT,
                                timeout=900).returncode
        stats = json.loads((out / f'fpu_wrap-{label}-stats.json').read_text())
        modules = stats.get('modules', {})
        tstat = modules.get(top) or modules.get(f'\\{top}', {})
        results.append({'variant': label, 'define': define or 'none', 'rc': rc,
                        'cells': tstat.get('num_cells'),
                        'wireBits': tstat.get('num_wire_bits'),
                        'memories': tstat.get('num_memories'),
                        'processes': tstat.get('num_processes')})
    ok = all(r['rc'] == 0 for r in results)
    if ok and results[0]['cells'] is not None and results[1]['cells'] is not None:
        delta = {'cells': results[0]['cells'] - results[1]['cells'],
                 'wireBits': results[0]['wireBits'] - results[1]['wireBits']}
    else:
        delta = None
    (out / 'results.json').write_text(json.dumps({
        'target': 'fpu_wrap', 'geometry': 'g6lc64_ooo_int2_l3 (FLen=64 OoOEn=1 NSB=8)',
        'runs': results, 'ownerDelta': delta,
        'sources': pins, 'scope': 'leaf stat, generic cells; not mapped timing'}, indent=2))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
