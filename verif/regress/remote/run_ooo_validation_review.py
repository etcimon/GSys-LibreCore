"""Isolated OoO formal and live-port structural qualification.

Copyright (c) 2026 Etienne Cimon
SPDX-License-Identifier: MIT
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def main():
    data, out = Path(os.environ['TH_DATA_DIR']), Path(os.environ['TH_OUT_DIR'])
    source = out / 'source'
    source.mkdir()
    formal = os.environ.get('OOO_RENAME_FORMAL') == '1'
    names = (['g6lc_rename.sv', 'g6lc_ooo_rename_props.sv', 'g6lc_ooo_rename.sby'] if formal else
             ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv',
              'g6lc_ooo_pkg.sv', 'g6lc_rename.sv', 'g6lc_rob.sv', 'g6lc_lsq.sv', 'g6lc_prf.sv',
              'g6lc_memdep.sv', 'g6lc_iq.sv', 'g6lc_ooo_dispatch.sv', 'tb_g6lc_rtl_review.sv'])
    paths = {}
    for name in names:
        paths[name] = source / ('formal/' + name if formal and name != 'g6lc_rename.sv' else name)
        paths[name].parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(data / name, paths[name])
    if formal:
        task = paths['g6lc_ooo_rename.sby']
        task.write_text(task.read_text().replace('[options]\n', '[options]\naigsmt z3\n'))
    negative = os.environ.get('OOO_FORMAL_NEGATIVE') == '1'
    if negative:
        props = paths['g6lc_ooo_rename_props.sv']
        text = props.read_text()
        old = "assert (dut.map_q[0] == '0);"
        if text.count(old) != 1:
            raise RuntimeError('rename checker mutation site changed')
        props.write_text(text.replace(old, "assert (dut.map_q[0] != '0);"))
    (out / 'sources.json').write_text(json.dumps({n: hashlib.sha256(paths[n].read_bytes()).hexdigest()
                                                 for n in names}, indent=2))
    env = os.environ.copy()
    env['PATH'] = '/opt/testharness/toolchains/formal/bin:' + env.get('PATH', '')
    if formal and negative:
        script = out / 'checker.ys'
        script.write_text('read_slang --std 1800-2017 --top g6lc_ooo_rename_props -DFORMAL '
                          + str(paths['g6lc_rename.sv']) + ' ' + str(paths['g6lc_ooo_rename_props.sv'])
                          + '\nprep -top g6lc_ooo_rename_props\nasync2sync\nflatten\n'
                          + 'chformal -cover -remove\nchformal -lower\nmemory_map\nopt\n'
                          + f'sat -seq 4 -set-assumes -prove-asserts -verify -show-ports -dump_json {out}/witness.json\n')
        with (out / 'checker.log').open('w') as log:
            rc = subprocess.run(['yosys', '-s', str(script)], env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=180).returncode
        text = (out / 'checker.log').read_text()
        matched = rc != 0 and 'model found: FAIL!' in text and (out / 'witness.json').is_file()
        (out / 'result.json').write_text(json.dumps({'negative': True, 'rc': rc, 'matched': matched,
                                                    'scope': 'four-step SAT checker counterexample'}))
        if not matched:
            raise RuntimeError('rename negative checker did not produce a counterexample')
        return
    if formal:
        command = ['sby', '-j', '2', '-d', str(out / 'proof'), 'g6lc_ooo_rename.sby']
        (out / 'command.json').write_text(json.dumps(command))
        with (out / 'formal.log').open('w') as log:
            rc = subprocess.run(command, cwd=source / 'formal', env=env, stdout=log,
                                stderr=subprocess.STDOUT, timeout=300).returncode
        text = (out / 'formal.log').read_text()
        matched = (rc != 0 and 'DONE (FAIL' in text) if negative else rc == 0 and 'DONE (PASS' in text
        (out / 'result.json').write_text(json.dumps({'negative': negative, 'rc': rc, 'matched': matched}))
        if not matched:
            raise RuntimeError('rename formal outcome mismatch')
        return
    bench = (source / 'tb_g6lc_rtl_review.sv').read_text().split('module tb_g6lc_review_dispatch;', 1)[1]
    definitions = bench[bench.index('  function automatic'):bench.index('  logic clk=')]
    dispatch = (source / 'g6lc_ooo_dispatch.sv').read_text()
    ports = dispatch.split(') (', 1)[1].split('\n);', 1)[0]
    ports = ports.replace('CVA6Cfg', 'C').replace('scoreboard_entry_t', 'sbe_t')
    wrapper = source / 'g6lc_ooo_live_review.sv'
    wrapper.write_text('// Copyright (c) 2026 Etienne Cimon\n// SPDX-License-Identifier: MIT\n'
                       + 'package g6lc_ooo_review_types;\nimport ariane_pkg::*;\n'
                       + 'localparam bit MDP=1, FPEN=0;\nlocalparam int HARTS=1;\n'
                       + definitions + '\nendpackage\n'
                       + 'module g6lc_ooo_live_review import g6lc_ooo_review_types::*; (\n' + ports + '\n);\n'
                       + 'g6lc_ooo_dispatch #(.CVA6Cfg(C),.scoreboard_entry_t(sbe_t)) dut(.*);\nendmodule\n')
    script = out / 'synth.ys'
    script.write_text('read_slang --std 1800-2017 --top g6lc_ooo_live_review '
                      + ' '.join(str(source / n) for n in names if n.endswith('.sv') and not n.startswith('tb_'))
                      + ' ' + str(wrapper) + '\nsynth -top g6lc_ooo_live_review -flatten\ncheck -assert\n'
                      + 'select -assert-none t:$dlatch t:$_DLATCH_*\nscc -expect 0\n'
                      + f'tee -o {out}/stats.json stat -json\n')
    with (out / 'synth.log').open('w') as log:
        rc = subprocess.run(['yosys', '-s', str(script)], cwd=source, env=env,
                            stdout=log, stderr=subprocess.STDOUT, timeout=300).returncode
    if rc:
        raise RuntimeError('live OoO synthesis failed')
    stats = json.loads((out / 'stats.json').read_text())['modules']['\\g6lc_ooo_live_review']
    (out / 'result.json').write_text(json.dumps({'cells': stats['num_cells'],
        'cellTypes': stats['num_cells_by_type'], 'latches': 0, 'scc': 0,
        'scope': 'single-hart integer fixture, generic cells, not mapped PPA'}, indent=2))


if __name__ == '__main__':
    main()
