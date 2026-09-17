#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Rebuild checked-work payloads and classify cookies, not the harness banner."""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


CACHE_TRACE = r'''
`ifndef SYNTHESIS
  if (1) begin : gen_cacheability_trace
    integer enabled, fd;
    longint unsigned limit_t;
    logic [HPDCACHE_NREQUESTERS-1:0] pending;
    hpdcache_req_t accepted_req[HPDCACHE_NREQUESTERS];
    initial begin
      enabled = 0;
      fd = 0;
      limit_t = 50000;
      void'($value$plusargs("g6lc_operand_trace=%d", enabled));
      void'($value$plusargs("g6lc_operand_trace_limit=%d", limit_t));
      if (enabled != 0) begin
        fd = $fopen($sformatf("cache-trace-%m.log"), "w");
        if (!fd) $fatal(1, "cacheability trace file unavailable");
        $fdisplay(fd, "[hc-config] path=%m requesters=%0d plen=%0d index_bits=%0d limit=%0d", HPDCACHE_NREQUESTERS, CVA6Cfg.PLEN, CVA6Cfg.DCACHE_INDEX_WIDTH, limit_t);
      end
    end
    always @(posedge clk_i) begin
      if (!rst_ni) begin
        pending = '0;
        foreach (accepted_req[r]) accepted_req[r] = '0;
      end else if (enabled != 0 && $time <= limit_t) begin
        for (int r = 0; r < HPDCACHE_NREQUESTERS; r++) begin
          if (pending[r])
            $fdisplay(fd, "[hc-tag] t=%0t port=%0d sid=%0d tid=%0d paddr=%h uc=%0d abort=%0d", $time, r, accepted_req[r].sid, accepted_req[r].tid, 64'({dcache_req_tag[r], accepted_req[r].addr_offset}), dcache_req_pma[r].uncacheable, dcache_req_abort[r]);
          if (dcache_req_valid[r] && dcache_req_ready[r])
            $fdisplay(fd, "[hc-request] t=%0t port=%0d sid=%0d tid=%0d offset=%h tag=%h op=%0d size=%0d be=%h data=%h phys=%0d uc=%0d", $time, r, dcache_req[r].sid, dcache_req[r].tid, dcache_req[r].addr_offset, dcache_req[r].addr_tag, dcache_req[r].op, dcache_req[r].size, dcache_req[r].be, dcache_req[r].wdata, dcache_req[r].phys_indexed, dcache_req[r].pma.uncacheable);
          if (dcache_rsp_valid[r])
            $fdisplay(fd, "[hc-response] t=%0t port=%0d sid=%0d tid=%0d data=%h", $time, r, dcache_rsp[r].sid, dcache_rsp[r].tid, dcache_rsp[r].rdata);
          pending[r] = dcache_req_valid[r] && dcache_req_ready[r] && !dcache_req[r].phys_indexed;
          if (pending[r]) accepted_req[r] = dcache_req[r];
        end
        if (i_hpdcache.hpdcache_ctrl_i.st1_req_valid_q)
          $fdisplay(fd, "[hc-stage1] t=%0t sid=%0d tid=%0d paddr=%h load=%0d uc=%0d abort=%0d hit=%0d replay=%0d", $time, i_hpdcache.hpdcache_ctrl_i.st1_req.req.sid, i_hpdcache.hpdcache_ctrl_i.st1_req.req.tid, i_hpdcache.hpdcache_ctrl_i.st1_req_addr, i_hpdcache.hpdcache_ctrl_i.st1_req_is_load, i_hpdcache.hpdcache_ctrl_i.st1_req_is_uncacheable, i_hpdcache.hpdcache_ctrl_i.st1_req_abort, i_hpdcache.hpdcache_ctrl_i.cachedir_hit_o, i_hpdcache.hpdcache_ctrl_i.st1_req.from_rtab);
        if (dcache_mem_req_read_valid_o && dcache_mem_req_read_ready_i)
          $fdisplay(fd, "[hc-memory-read] t=%0t id=%0d addr=%h len=%0d size=%0d cacheable=%0d", $time, dcache_mem_req_read_o.mem_req_id, dcache_mem_req_read_o.mem_req_addr, dcache_mem_req_read_o.mem_req_len, dcache_mem_req_read_o.mem_req_size, dcache_mem_req_read_o.mem_req_cacheable);
        if (dcache_mem_resp_read_valid_i && dcache_mem_resp_read_ready_o)
          $fdisplay(fd, "[hc-memory-response] t=%0t id=%0d data=%h last=%0d error=%0d", $time, dcache_mem_resp_read_i.mem_resp_r_id, dcache_mem_resp_read_i.mem_resp_r_data, dcache_mem_resp_read_i.mem_resp_r_last, dcache_mem_resp_read_i.mem_resp_r_error);
        if (dcache_mem_req_write_valid_o && dcache_mem_req_write_ready_i)
          $fdisplay(fd, "[hc-memory-write] t=%0t id=%0d addr=%h len=%0d size=%0d cacheable=%0d", $time, dcache_mem_req_write_o.mem_req_id, dcache_mem_req_write_o.mem_req_addr, dcache_mem_req_write_o.mem_req_len, dcache_mem_req_write_o.mem_req_size, dcache_mem_req_write_o.mem_req_cacheable);
        if (dcache_mem_req_write_data_valid_o && dcache_mem_req_write_data_ready_i)
          $fdisplay(fd, "[hc-memory-data] t=%0t data=%h be=%h last=%0d", $time, dcache_mem_req_write_data_o.mem_req_w_data, dcache_mem_req_write_data_o.mem_req_w_be, dcache_mem_req_write_data_o.mem_req_w_last);
        if (dcache_mem_resp_read_inval_i)
          $fdisplay(fd, "[hc-invalidation] t=%0t nline=%h", $time, dcache_mem_resp_read_inval_nline_i);
        if (i_hpdcache.refill_write_dir)
          $fdisplay(fd, "[hc-install] t=%0t nline=%h way=%h error=%0d", $time, i_hpdcache.refill_nline, i_hpdcache.refill_way, i_hpdcache.refill_is_error);
        if (dcache_read_miss || dcache_write_miss || i_hpdcache.evt_uncached_req_o)
          $fdisplay(fd, "[hc-event] t=%0t read_miss=%0d write_miss=%0d uncached=%0d", $time, dcache_read_miss, dcache_write_miss, i_hpdcache.evt_uncached_req_o);
      end
    end
    final begin
      if (enabled != 0 && fd) begin
        $fdisplay(fd, "[hc-end] t=%0t", $time);
        $fclose(fd);
      end
    end
  end
`endif
'''


def cacheability_review():
    root = Path(os.environ['TH_RUN_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    base = Path('/opt/testharness/runs/review-iq-ring-core-20260916')
    identity = json.loads((base / 'output/model.json').read_text())
    source_root = Path(identity['sourceRoot'])
    source_manifest = json.loads((base / 'output/sources.json').read_text())
    runtime_info = json.loads((base / 'output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    fixed_header = 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    assert digest(runtime / 'include/verilated_funcs.h') == fixed_header
    canaries = json.loads((base / 'output/canaries.json').read_text())
    assert [(r['tag'], r['rc']) for r in canaries] == [('original', 1), ('fixed', 0)]
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    (out / 'canaries.json').write_text(json.dumps(canaries, indent=2))
    tool = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-'
    payloads = []
    linker = out / 'cacheability.ld'
    linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { *(.text.init) *(.text*) } . = 0x80001000; .tohost : { *(.tohost) } . = 0x80001080; .data : { *(.data*) } .bss : { *(.bss*) } }\n')
    for name in ['mini_hpd_2jr', 'mini_hpd_2jr_data', 'mini_hpd_2jr_pad', 'mini_hpd_2jr_fencei']:
        work = out / (name + '-payload')
        work.mkdir()
        source = work / (name + '.S')
        shutil.copy2(data / source.name, source)
        elf = work / (name + '.elf')
        command = [tool + 'gcc', '-march=rv64imac_zicsr_zifencei', '-mabi=lp64', '-nostdlib', '-static', '-Wl,--no-relax', '-T', str(linker), str(source), '-o', str(elf)]
        subprocess.run(command, check=True, capture_output=True)
        (work / 'disassembly.txt').write_text(subprocess.check_output([tool + 'objdump', '-d', str(elf)], text=True))
        symbols = subprocess.check_output([tool + 'nm', '-n', str(elf)], text=True)
        (work / 'symbols.txt').write_text(symbols)
        symbol_map = {name: int(addr, 16) for addr, kind, name in re.findall(r'^([0-9a-fA-F]+)\s+(\S)\s+(\S+)$', symbols, re.M)}
        assert all(name in symbol_map for name in ['_start', 'do_jr', 'jr_one', 'jr_three', 'jtab', 'phase', 'tohost'])
        payloads.append({'name': name, 'elf': str(elf), 'elfSha256': digest(elf), 'sourceSha256': digest(source), 'linkerSha256': digest(linker), 'compile': command, 'symbols': symbol_map})
    (out / 'payloads.json').write_text(json.dumps(payloads, indent=2))
    models = []
    results = []
    old = '!config_pkg::is_inside_cacheable_regions(CVA6Cfg, load_paddr) ||\n          config_pkg::is_inside_execute_regions(CVA6Cfg, load_paddr)'
    new = '!config_pkg::is_inside_cacheable_regions(CVA6Cfg, load_paddr)'
    suffixes = {'.sv', '.svh', '.v', '.vh', '.h', '.hpp', '.c', '.cc', '.cpp', '.mk', '.sh', '.py', '.tcl', '.ld', '.S', '.f', '.bin'}
    def closure(repo):
        return {str(p.relative_to(repo)): digest(p) for p in repo.rglob('*') if p.is_file() and '.git' not in p.relative_to(repo).parts and (p.suffix in suffixes or p.name == 'Makefile' or p.name.startswith('Flist'))}
    for policy in ['execute-uncached', 'pma-only']:
        repo = root / ('repo-' + policy)
        model = root / ('model-' + policy)
        shutil.copytree(source_root, repo)
        for name, expected in source_manifest.items():
            assert digest(repo / name) == expected, name
        core = repo / 'core/cva6.sv'
        original = core.read_text()
        old_include = str(source_root / 'verif/tb/core/g6lc_operand_trace.svh')
        assert original.count(old_include) == 1
        core.write_text(original.replace(old_include, str(repo / 'verif/tb/core/g6lc_operand_trace.svh')))
        wrapper = repo / 'core/cache_subsystem/cva6_hpdcache_wrapper.sv'
        original = wrapper.read_text()
        assert original.count('endmodule : cva6_hpdcache_wrapper') == 1
        wrapper.write_text(original.replace('endmodule : cva6_hpdcache_wrapper', CACHE_TRACE + '\nendmodule : cva6_hpdcache_wrapper'))
        adapter = repo / 'core/cache_subsystem/cva6_hpdcache_if_adapter.sv'
        original = adapter.read_text()
        assert original.count(old) == 1
        if policy == 'pma-only':
            adapter.write_text(original.replace(old, new))
        package = repo / 'core/include/g6lc64_stream8_config_pkg.sv'
        assert "L2RoundRobinEn: bit'(0)" in package.read_text()
        manifest = closure(repo)
        command = ['bash', '-c', '. /opt/testharness/env.sh; export VERILATOR_ROOT="$3" CVA6_REPO_DIR="$1" SOFT_LADDER_VERLIB="$2" SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_TARGET=g6lc64_stream8 SOFT_LADDER_BUILD_JOBS=4; bash verif/regress/soft-ladder-build-harness.sh B', 'cacheability', str(repo), str(model), str(runtime)]
        with (out / (policy + '-build.log')).open('w') as log:
            build = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        assert build.returncode == 0, 'cacheability model build failed: ' + policy
        after = closure(repo)
        assert after == manifest, {'sourceDrift': sorted(k for k in set(manifest) | set(after) if manifest.get(k) != after.get(k))}
        dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
        assert str(runtime / 'include/verilated_funcs.h') in dependencies
        assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
        exe = model / 'Variane_testharness'
        model_sha = digest(exe)
        (out / (policy + '-sources.json')).write_text(json.dumps(manifest, indent=2))
        models.append({'policy': policy, 'exe': str(exe), 'sha256': model_sha, 'sourceRoot': str(repo), 'build': command, 'configSha256': digest(package), 'adapterSha256': digest(adapter), 'observerSha256': digest(repo / 'verif/tb/core/g6lc_operand_trace.svh'), 'wrapperSha256': digest(wrapper), 'iqSha256': digest(repo / 'core/fetch_B/instr_queue.sv'), 'runtimeHeaderSha256': fixed_header, 'strictQualification': False})
        (out / 'models.json').write_text(json.dumps(models, indent=2))
        for payload in payloads:
            trials = [False, True, True] if payload['name'] == 'mini_hpd_2jr' else [False, True]
            controls = []
            for trial, enabled in enumerate(trials):
                for proc in Path('/proc').iterdir():
                    if proc.name.isdecimal():
                        try:
                            assert (proc / 'exe').resolve().name != 'Variane_testharness', 'another harness is active'
                        except OSError:
                            pass
                elf = Path(payload['elf'])
                assert digest(exe) == model_sha and digest(elf) == payload['elfSha256']
                work = out / (policy + '-' + payload['name'] + '-' + str(trial))
                work.mkdir()
                cmd = [str(exe), '-m', '50000', '-s', '1', '+debug_disable']
                if enabled:
                    cmd += ['+g6lc_operand_trace=1', '+g6lc_operand_trace_limit=50000']
                cmd.append(str(elf))
                rules = '; '.join('exit cookie off=0x1000 val=' + str(value) for value in [1, 3, 5, 9, 25])
                with (work / 'sim.log').open('w') as log:
                    run = subprocess.run(cmd, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': rules}, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                text = (work / 'sim.log').read_text(errors='replace')
                cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
                clean = run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
                status = 'pass' if clean and len(cookies) == 1 and int(cookies[0][1], 16) == 1 else 'no-verdict' if clean and not cookies else 'fail'
                retirement = {p.name: digest(p) for p in work.glob('trace_hart_*.dasm')}
                traces = {p.name: digest(p) for p in work.glob('operand-trace-*.log')}
                cache_traces = {p.name: digest(p) for p in work.glob('cache-trace-*.log')}
                assert retirement
                if enabled:
                    assert traces and cache_traces
                    assert all('[ot-end]' in (work / name).read_text() for name in traces)
                    assert all('[hc-end]' in (work / name).read_text() for name in cache_traces)
                else:
                    assert not traces and not cache_traces
                assert digest(exe) == model_sha and digest(elf) == payload['elfSha256']
                record = {'policy': policy, 'payload': payload['name'], 'trial': trial, 'observer': enabled, 'status': status, 'rc': run.returncode, 'cookie': cookies, 'modelSha256': model_sha, 'elfSha256': payload['elfSha256'], 'command': cmd, 'work': str(work), 'retirement': retirement, 'operandTraces': traces, 'cacheTraces': cache_traces, 'strictQualification': False}
                controls.append(record)
                results.append(record)
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                assert clean, record
            assert all(r['retirement'] == controls[0]['retirement'] and r['cookie'] == controls[0]['cookie'] for r in controls)
            if len(controls) == 3:
                assert controls[1]['operandTraces'] == controls[2]['operandTraces']
                assert controls[1]['cacheTraces'] == controls[2]['cacheTraces']
        assert closure(repo) == manifest
    assert models[0]['configSha256'] == models[1]['configSha256']
    assert models[0]['iqSha256'] == models[1]['iqSha256']
    assert models[0]['observerSha256'] == models[1]['observerSha256']
    assert models[0]['wrapperSha256'] == models[1]['wrapperSha256']
    return 0 if all(r['status'] == 'pass' for r in results) else 1


def locality_controls(out):
    data = Path(os.environ['TH_DATA_DIR'])
    tool = '/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-14.2.0-3/bin/riscv-none-elf-'
    linker = out / 'locality.ld'
    linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { *(.text.init) *(.text*) } . = 0x80001000; .tohost : { *(.tohost) } . = 0x80001100; .data : { *(.data*) } .bss : { *(.bss*) } }\n')
    controls = []
    for nodes, negative in [(128, False), (1024, False), (8192, False), (128, True)]:
        name = 'locality-' + str(nodes * 8) + ('-negative' if negative else '')
        work = out / (name + '-payload')
        work.mkdir()
        source = work / 'mini_l2_hot_scan.S'
        shutil.copy2(data / source.name, source)
        elf = work / (name + '.elf')
        command = [tool + 'gcc', '-march=rv64imac_zicsr_zifencei', '-mabi=lp64', '-nostdlib', '-static', '-Wl,--no-relax', '-T', str(linker), '-DG6LC_LOCALITY_PROBE=1', '-DLOCAL_NODES=' + str(nodes), '-DLOCAL_STEPS=8192']
        if negative:
            command.append('-DLOCAL_NEGATIVE=1')
        command += [str(source), '-o', str(elf)]
        (work / 'compile-command.json').write_text(json.dumps(command, indent=2))
        compiled = subprocess.run(command, capture_output=True, text=True)
        (work / 'compile.log').write_text(compiled.stdout + compiled.stderr)
        compiled.check_returncode()
        disassembly = subprocess.check_output([tool + 'objdump', '-d', str(elf)], text=True)
        symbols = subprocess.check_output([tool + 'nm', '-n', str(elf)], text=True)
        (work / 'disassembly.txt').write_text(disassembly)
        (work / 'symbols.txt').write_text(symbols)
        widths = re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', disassembly, re.M)
        assert widths and all(len(word) == 8 for word in widths)
        symbol_map = {name: int(addr, 16) for addr, kind, name in re.findall(r'^([0-9a-fA-F]+)\s+(\S)\s+(\S+)$', symbols, re.M)}
        assert symbol_map['locality_roi_begin'] < symbol_map['locality_roi_end']
        assert symbol_map['report'] == 0x80001080 and symbol_map['tohost'] == 0x80001000
        rules = ['exit cookie off=0x1000 val=1', 'exit cookie off=0x1000 val=3']
        for index, field in enumerate(['roi_cycles', 'l2_miss', 'l1d_miss', 'load', 'store', 'data_req', 'l1i_miss']):
            rules.append(f'log mem tag={field} off={hex(0x1080 + 8 * index)} max=1000')
        controls.append({'payload': name, 'command': ['', '-m', '1000000', '-s', '1', '+debug_disable', str(elf)], 'elfSha256': digest(elf), 'sourceSha256': digest(source), 'linkerSha256': digest(linker), 'compile': command, 'symbols': symbol_map, 'traceRules': rules, 'nodes': nodes, 'workingSetBytes': nodes * 8, 'warmupLoads': nodes, 'measuredLoads': 8192, 'strideNodes': 37, 'expectedCookie': 3 if negative else 1, 'negativeControl': negative})
    return controls


def cacheability_work_review():
    out = Path(os.environ['TH_OUT_DIR'])
    paired = Path('/opt/testharness/runs/review-cacheability-pair-20260916/output')
    models = json.loads((paired / 'models.json').read_text())
    assert [m['policy'] for m in models] == ['execute-uncached', 'pma-only']
    predictor_output = None
    size_model = os.environ.get('REVIEW_L2_STREAM_MODEL')
    if size_model:
        assert os.environ.get('REVIEW_PREDICTOR_WORK') == '1'
    if os.environ.get('REVIEW_PREDICTOR_WORK') == '1':
        predictor_output = Path(size_model).parent if size_model else Path('/opt/testharness/runs/review-predictor-absolute-sc-20260916/output')
        predictor_model = json.loads((predictor_output / 'model.json').read_text())
        assert predictor_model['predictorCandidate'] and predictor_model['absoluteCorrector']
        models = [dict(predictor_model, policy='response-absolute', runtimeHeaderSha256=predictor_model['runtime']['fixedHeaderSha256'])]
    if os.environ.get('REVIEW_CACHEABILITY_LOCALITY') == '1':
        controls = locality_controls(out)
    else:
        references = json.loads(Path('/opt/testharness/runs/review-private-runtime-rebuild-20260915/output/results.json').read_text())
        controls = [r for r in references if r['tag'] == 'g6lc64_stream8-rr0']
        expected_elfs = {'mini_checked_work': '57c9e51f5552bafae375fefd8dd4b473076558e066c05f30707cbcd8e7b77fee', 'mini_l2_hot_scan': '69ef15f4b679f4a7ac77de21fb9ab4972c23fb54382fa413eb93f50a71a80ba0'}
        assert len(controls) == 2 and {r['payload']: r['elfSha256'] for r in controls} == expected_elfs
        if predictor_output:
            locality = json.loads(Path('/opt/testharness/runs/review-cache-locality-v2-20260916/output/controls.json').read_text())
            selected = ['locality-8192', 'locality-65536', 'locality-1024-negative'] + (['locality-1024'] if size_model else [])
            controls += [r for r in locality if r['payload'] in selected]
            assert len(controls) == (6 if size_model else 5)
    runtime = json.loads((paired / 'runtime.json').read_text())
    assert digest(Path(runtime['privateRoot']) / 'include/verilated_funcs.h') == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    (out / 'models.json').write_text(json.dumps(models, indent=2))
    (out / 'controls.json').write_text(json.dumps(controls, indent=2))
    (out / 'runtime.json').write_text(json.dumps(runtime, indent=2))
    results = []
    for model in models:
        exe = Path(model['exe'])
        source_root = Path(model['sourceRoot'])
        source_file = predictor_output / 'sources.json' if predictor_output else paired / (model['policy'] + '-sources.json')
        sources = json.loads(source_file.read_text())
        for name, expected in sources.items():
            assert digest(source_root / name) == expected, name
        for control in controls:
            elf = Path(control['command'][-1])
            trials = []
            expected_cookie = control.get('expectedCookie', 1)
            for trial in range(1 if control.get('negativeControl') else 2):
                for proc in Path('/proc').iterdir():
                    if proc.name.isdecimal():
                        try:
                            assert (proc / 'exe').resolve().name != 'Variane_testharness', 'another harness is active'
                        except OSError:
                            pass
                assert digest(exe) == model['sha256'] and digest(elf) == control['elfSha256']
                work = out / (model['policy'] + '-' + control['payload'] + '-' + str(trial))
                work.mkdir()
                command = [str(exe), *control['command'][1:]]
                with (work / 'sim.log').open('w') as log:
                    run = subprocess.run(command, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': '; '.join(control['traceRules'])}, stdout=log, stderr=subprocess.STDOUT, timeout=240)
                text = (work / 'sim.log').read_text(errors='replace')
                cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
                clean = run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
                status = 'pass' if clean and len(cookies) == 1 and int(cookies[0][1], 16) == 1 else 'no-verdict' if clean and not cookies else 'fail'
                report = {}
                samples = {}
                matched_expected = clean and len(cookies) == 1 and int(cookies[0][1], 16) == expected_cookie
                if size_model:
                    assert text.count(f"L2SIZE_CONFIG target=g6lc64_stream8 depth={model['l2Size']['effectiveDepth']} bytes=262144 ways=8 banks=4 cores=2 harts=1") == 1
                if (control['payload'] == 'mini_l2_hot_scan' or control['payload'].startswith('locality-')) and status == 'pass' and expected_cookie == 1:
                    for name in ['roi_cycles', 'l2_miss', 'l1d_miss', 'load', 'store', 'data_req', 'l1i_miss']:
                        values = [int(value, 16) for value in re.findall(r'\[trace\] t=\d+ tag=' + name + r' loc=0x([0-9a-fA-F]+)', text)]
                        assert len(values) >= 2 and values[-1] == values[-2], 'missing/unstable report: ' + name
                        report[name] = values[-1]
                        samples[name] = len(values)
                    assert report['roi_cycles'] > 0
                    if 'measuredLoads' in control:
                        assert report['load'] == control['measuredLoads'] and report['store'] == 0
                assert digest(exe) == model['sha256'] and digest(elf) == control['elfSha256']
                retirement = {p.name: digest(p) for p in work.glob('trace_hart_*.dasm')}
                assert retirement and not list(work.glob('operand-trace-*.log')) and not list(work.glob('cache-trace-*.log'))
                record = {'policy': model['policy'], 'payload': control['payload'], 'trial': trial, 'status': status, 'rc': run.returncode, 'cookie': cookies, 'report': report, 'reportSampleCounts': samples, 'retirement': retirement, 'command': command, 'modelSha256': model['sha256'], 'elfSha256': control['elfSha256'], 'runtimeHeaderSha256': model['runtimeHeaderSha256'], 'logSha256': digest(work / 'sim.log'), 'strictQualification': False}
                record.update(expectedCookie=expected_cookie, matchedExpected=matched_expected, negativeControl=control.get('negativeControl', False))
                trials.append(record)
                results.append(record)
                (out / 'results.json').write_text(json.dumps(results, indent=2))
            assert trials[0]['status'] == trials[-1]['status'] and trials[0]['cookie'] == trials[-1]['cookie']
            assert trials[0]['report'] == trials[-1]['report'] and trials[0]['retirement'] == trials[-1]['retirement']
        for name, expected in sources.items():
            assert digest(source_root / name) == expected, name
    return 0 if all(r['matchedExpected'] for r in results) else 1


ICACHE_TRACE = r'''
`ifndef SYNTHESIS
  if (1) begin : gen_icache_contract_trace
    integer enabled, fd;
    longint unsigned limit_t;
    initial begin
      enabled = 0;
      fd = 0;
      limit_t = 30000;
      void'($value$plusargs("g6lc_operand_trace=%d", enabled));
      void'($value$plusargs("g6lc_operand_trace_limit=%d", limit_t));
      if (enabled != 0) begin
        fd = $fopen($sformatf("icache-trace-%m.log"), "w");
        if (!fd) $fatal(1, "icache trace file unavailable");
        $fdisplay(fd, "[ic-config] path=%m ways=%0d line_bits=%0d fetch_bits=%0d limit=%0d", CVA6Cfg.ICACHE_SET_ASSOC, CVA6Cfg.ICACHE_LINE_WIDTH, CVA6Cfg.FETCH_WIDTH, limit_t);
      end
    end
    always @(posedge clk_i) begin
      if (rst_ni && enabled != 0 && $time <= limit_t &&
          (dreq_i.req || state_q != IDLE || mem_rtrn_vld_i || flush_i)) begin
        $fdisplay(fd, "[ic-cycle] t=%0t state=%0d req=%0d ready=%0d offered=%h pc=%h index=%h tag=%h next_tag=%h translated=%0d hit=%h valids=%h compare=%0d rden=%0d data_req=%h tag_req=%h mem_req=%0d mem_ack=%0d mem_addr=%h miss=%0d enabled=%0d nc=%0d kill1=%0d kill2=%0d flush=%0d flush_pending=%0d invalidate=%0d response=%0d response_type=%0d write=%0d write_index=%h write_way=%h delivered=%0d", $time, state_q, dreq_i.req, dreq_o.ready, dreq_i.vaddr, vaddr_q, cl_index, cl_tag_q, cl_tag_d, areq_i.fetch_valid, cl_hit, vld_rdata, cmp_en_q, cache_rden, cl_req, vld_req, mem_data_req_o, mem_data_ack_i, mem_data_o.paddr, miss_o, cache_en_q, paddr_is_nc, dreq_i.kill_s1, dreq_i.kill_s2, flush_i, flush_q, inv_en, mem_rtrn_vld_i, mem_rtrn_i.rtype, cache_wren, vld_addr, repl_way_oh_q, dreq_o.valid);
        if (state_q == READ && cl_hit == '0) begin
          for (int w = 0; w < CVA6Cfg.ICACHE_SET_ASSOC; w++)
            $fdisplay(fd, "[ic-way] t=%0t way=%0d valid=%0d tag=%h", $time, w, vld_rdata[w], cl_tag_rdata[w]);
        end
      end
    end
    final begin
      if (enabled != 0 && fd) begin
        $fdisplay(fd, "[ic-end] t=%0t", $time);
        $fclose(fd);
      end
    end
  end
`endif
'''


def locality_icache_review():
    root = Path(os.environ['TH_RUN_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    pair = Path('/opt/testharness/runs/review-cacheability-pair-20260916/output')
    prior = next(m for m in json.loads((pair / 'models.json').read_text()) if m['policy'] == 'execute-uncached')
    controls = Path('/opt/testharness/runs/review-cache-locality-v2-20260916/output')
    reference = next(r for r in json.loads((controls / 'results.json').read_text()) if r['policy'] == 'execute-uncached' and r['payload'] == 'locality-1024' and r['trial'] == 0)
    assert reference['status'] == 'pass' and reference['matchedExpected']
    control = next(r for r in json.loads((controls / 'controls.json').read_text()) if r['payload'] == 'locality-1024')
    predictor_candidate = os.environ.get('REVIEW_PREDICTOR_CANDIDATE') == '1'
    absolute_corrector = os.environ.get('REVIEW_SC_ABSOLUTE') == '1'
    assert not absolute_corrector or predictor_candidate
    runtime_info = json.loads((pair / 'runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    assert digest(runtime / 'include/verilated_funcs.h') == reference['runtimeHeaderSha256']
    reuse = os.environ.get('REVIEW_ICACHE_MODEL')
    if reuse:
        model_file = Path(reuse)
        identity = json.loads(model_file.read_text())
        assert identity['baseline']['sha256'] == prior['sha256'] and identity['runtime'] == runtime_info
        assert identity.get('predictorCandidate', False) == predictor_candidate
        assert identity.get('absoluteCorrector', False) == absolute_corrector
        repo = Path(identity['sourceRoot'])
        exe = Path(identity['exe'])
        model = exe.parent
        model_sha = identity['sha256']
        sources = json.loads((model_file.parent / 'sources.json').read_text())
        assert digest(exe) == model_sha
        assert ICACHE_TRACE in (repo / 'core/cache_subsystem/g6lc_icache.sv').read_text()
        identity = dict(identity, reusedFrom=str(model_file))
    else:
        repo = root / 'repo'
        shutil.copytree(Path(prior['sourceRoot']), repo)
        sources = json.loads((pair / 'execute-uncached-sources.json').read_text())
        for name, expected in sources.items():
            assert digest(repo / name) == expected, name
        core = repo / 'core/cva6.sv'
        original = core.read_text()
        old_include = str(Path(prior['sourceRoot']) / 'verif/tb/core/g6lc_operand_trace.svh')
        assert original.count(old_include) == 1
        core.write_text(original.replace(old_include, str(repo / 'verif/tb/core/g6lc_operand_trace.svh')))
        icache = repo / 'core/cache_subsystem/g6lc_icache.sv'
        original = icache.read_text()
        assert original.count('endmodule') == 1
        icache.write_text(original.replace('endmodule', ICACHE_TRACE + '\nendmodule'))
        if predictor_candidate:
            frontend = repo / 'core/fetch_B/frontend.sv'
            text = frontend.read_text()
            old_btb = 'assign vpc_btb = CVA6Cfg.FpgaEn ? icache_dreq_i.vaddr : icache_vaddr_q;'
            old_bht = 'assign vpc_bht = (CVA6Cfg.FpgaEn && CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid)\n                   ? icache_dreq_i.vaddr : icache_vaddr_q;'
            assert text.count(old_btb) == 1 and text.count(old_bht) == 1
            text = text.replace(old_btb, 'assign vpc_btb = CVA6Cfg.FpgaEn ? icache_dreq_i.vaddr : realigner_vaddr;')
            text = text.replace(old_bht, 'assign vpc_bht = !CVA6Cfg.FpgaEn ? realigner_vaddr :\n      (CVA6Cfg.FpgaAlteraEn && icache_dreq_i.valid) ? icache_dreq_i.vaddr : icache_vaddr_q;')
            frontend.write_text(text)
            sources['core/fetch_B/frontend.sv'] = digest(frontend)
        if absolute_corrector:
            corrector = repo / 'core/frontend/g6lc_bp_statcor.sv'
            text = corrector.read_text()
            old_sc = "      if (pred_i[i].valid && w_q[idx] < 3'b010) begin\n        pred_o[i].taken = ~pred_i[i].taken;\n      end"
            new_sc = "      if (pred_i[i].valid && w_q[idx] < 3'b010) begin\n        pred_o[i].taken = 1'b0;\n      end else if (pred_i[i].valid && w_q[idx] > 3'b101) begin\n        pred_o[i].taken = 1'b1;\n      end"
            assert text.count(old_sc) == 1
            corrector.write_text(text.replace(old_sc, new_sc))
            sources['core/frontend/g6lc_bp_statcor.sv'] = digest(corrector)
        for name in ['core/cva6.sv', 'core/cache_subsystem/g6lc_icache.sv']:
            sources[name] = digest(repo / name)
        model = root / 'model'
        command = ['bash', '-c', '. /opt/testharness/env.sh; export VERILATOR_ROOT="$3" CVA6_REPO_DIR="$1" SOFT_LADDER_VERLIB="$2" SOFT_LADDER_VERILATOR_THREADS=1 SOFT_LADDER_BUILD_TARGET=g6lc64_stream8 SOFT_LADDER_BUILD_JOBS=4; bash verif/regress/soft-ladder-build-harness.sh B', 'icache-observer', str(repo), str(model), str(runtime)]
        with (out / 'build.log').open('w') as log:
            built = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        assert built.returncode == 0
        exe = model / 'Variane_testharness'
        model_sha = digest(exe)
        identity = {'exe': str(exe), 'sha256': model_sha, 'build': command, 'sourceRoot': str(repo), 'baseline': prior, 'runtime': runtime_info, 'predictorCandidate': predictor_candidate, 'absoluteCorrector': absolute_corrector, 'strictQualification': False}
    for name, expected in sources.items():
        assert digest(repo / name) == expected, name
    dependencies = '\n'.join(p.read_text(errors='replace') for p in model.glob('*.d'))
    assert str(runtime / 'include/verilated_funcs.h') in dependencies
    assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in dependencies
    (out / 'model.json').write_text(json.dumps(identity, indent=2))
    (out / 'sources.json').write_text(json.dumps(sources, indent=2))
    context = out / 'context'
    context.mkdir()
    for name in ['corev_apu/tb/ariane_testharness.sv', 'corev_apu/src/g6lc_ai_dram_backend.sv', 'corev_apu/include/g6lc_ai_island_cfg_pkg.sv', 'core/include/g6lc64_stream8_config_pkg.sv', 'core/cache_subsystem/cva6_hpdcache_subsystem_axi_arbiter.sv', 'core/cache_subsystem/g6lc_icache.sv']:
        destination = context / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(repo / name, destination)
    for name in ['Variane_testharness.mk', 'Variane_testharness__verFiles.dat']:
        shutil.copy2(model / name, context / name)
    def committed_prefix(path, stop_pc):
        rows = []
        for line in path.read_text().splitlines():
            match = re.fullmatch(r'\s*(\d+) (0x[0-9a-fA-F]+) (.*)', line)
            assert match, 'unrecognized retirement row'
            rows.append((match[2], match[3]))
            if int(match[2], 16) == stop_pc:
                return rows
        raise RuntimeError('retirement prefix did not reach its boundary')
    baseline_dir = Path(reference['command'][-1]).parents[1] / 'execute-uncached-locality-1024-0'
    baseline_prefix = committed_prefix(baseline_dir / 'trace_hart_0.dasm', control['symbols']['write_tohost'])
    results = []
    for trial, enabled in enumerate([False, True, True]):
        for proc in Path('/proc').iterdir():
            if proc.name.isdecimal():
                try:
                    assert (proc / 'exe').resolve().name != 'Variane_testharness', 'another harness is active'
                except OSError:
                    pass
        elf = Path(reference['command'][-1])
        assert digest(elf) == reference['elfSha256'] and digest(exe) == model_sha
        work = out / ('trial-' + str(trial))
        work.mkdir()
        cmd = [str(exe), *reference['command'][1:-1]]
        if enabled:
            cmd += ['+g6lc_operand_trace=1', '+g6lc_operand_trace_limit=30000']
        cmd.append(str(elf))
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(cmd, cwd=work, env={'PATH': '/usr/bin:/bin', 'CVA6_TRACE_SPEC': '; '.join(control['traceRules'])}, stdout=log, stderr=subprocess.STDOUT, timeout=240)
        text = (work / 'sim.log').read_text(errors='replace')
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        retirement = {p.name: digest(p) for p in work.glob('trace_hart_*.dasm')}
        traces = {p.name: digest(p) for pattern in ['icache-trace-*.log', 'cache-trace-*.log', 'operand-trace-*.log'] for p in work.glob(pattern)}
        assert run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
        if predictor_candidate:
            assert len(cookies) == 1 and int(cookies[0][1], 16) == 1
            assert committed_prefix(work / 'trace_hart_0.dasm', control['symbols']['write_tohost']) == baseline_prefix
        else:
            assert [list(cookie) for cookie in cookies] == reference['cookie'] and retirement == reference['retirement']
        report = {}
        for field in ['roi_cycles', 'l2_miss', 'l1d_miss', 'load', 'store', 'data_req', 'l1i_miss']:
            values = [int(v, 16) for v in re.findall(r'\[trace\] t=\d+ tag=' + field + r' loc=0x([0-9a-fA-F]+)', text)]
            assert len(values) >= 2 and values[-1] == values[-2]
            report[field] = values[-1]
        assert report['load'] == 8192 and report['store'] == 0 and report['roi_cycles'] > 0
        assert digest(exe) == model_sha and digest(elf) == reference['elfSha256']
        if enabled:
            assert any(name.startswith('icache-trace-') for name in traces)
            for name in traces:
                marker = '[ic-end]' if name.startswith('icache-trace-') else '[hc-end]' if name.startswith('cache-trace-') else '[ot-end]'
                assert marker in (work / name).read_text()
        else:
            assert not traces
        results.append({'trial': trial, 'observer': enabled, 'cookie': cookies, 'retirement': retirement, 'report': report, 'traces': traces, 'command': cmd, 'modelSha256': model_sha, 'elfSha256': reference['elfSha256'], 'matched': True, 'predictorCandidate': predictor_candidate, 'absoluteCorrector': absolute_corrector, 'strictQualification': False})
        (out / 'results.json').write_text(json.dumps(results, indent=2))
    assert results[1]['traces'] == results[2]['traces']
    assert all(r['retirement'] == results[0]['retirement'] and r['cookie'] == results[0]['cookie'] and r['report'] == results[0]['report'] for r in results)
    return 0


def predictor_leaf_review():
    root = Path(os.environ['TH_RUN_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    runtime_info = json.loads(Path('/opt/testharness/runs/review-cacheability-pair-20260916/output/runtime.json').read_text())
    runtime = Path(runtime_info['privateRoot'])
    header_sha = digest(runtime / 'include/verilated_funcs.h')
    assert header_sha == 'dfbc2c4aa3c1065d4465027c893c9677de10da4cfe7fb152e485eb32b8125166'
    old_sc = "      if (pred_i[i].valid && w_q[idx] < 3'b010) begin\n        pred_o[i].taken = ~pred_i[i].taken;\n      end"
    new_sc = "      if (pred_i[i].valid && w_q[idx] < 3'b010) begin\n        pred_o[i].taken = 1'b0;\n      end else if (pred_i[i].valid && w_q[idx] > 3'b101) begin\n        pred_o[i].taken = 1'b1;\n      end"
    supplied = (data / 'g6lc_bp_statcor.sv').read_text()
    if supplied.count(old_sc) == 1:
        original = supplied
        candidate = original.replace(old_sc, new_sc)
    else:
        assert supplied.count(new_sc) == 1, 'unrecognized corrector implementation'
        before_output = Path('/opt/testharness/runs/review-statcor-contract-v2-20260916/output/before')
        before_source = before_output / 'source/g6lc_bp_statcor.sv'
        before_manifest = json.loads((before_output / 'sources.json').read_text())
        assert digest(before_source) == before_manifest['g6lc_bp_statcor.sv']
        original = before_source.read_text()
        assert original.count(old_sc) == 1
        candidate = supplied
    names = ['config_pkg.sv', 'g6lc64_smt2_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv', 'g6lc_bp_statcor.sv', 'tb_g6lc_bp_statcor.sv']
    results = []
    wrapper = '''module g6lc_statcor_synth (
  input logic clk, rst_n, flush, update_valid, update_taken,
  input logic [63:0] pc, update_pc,
  input logic [1:0] pred_valid, pred_taken,
  output logic [1:0] result_valid, result_taken
);
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.RVC = 1;
    c.INSTR_PER_FETCH = 2;
    return c;
  endfunction
  typedef struct packed { logic valid; logic [63:0] pc; logic taken; } update_t;
  update_t update;
  bht_prediction_t [1:0] prediction, result;
  assign update = '{valid: update_valid, pc: update_pc, taken: update_taken};
  for (genvar p = 0; p < 2; p++) begin
    assign prediction[p] = '{valid: pred_valid[p], taken: pred_taken[p]};
    assign result_valid[p] = result[p].valid;
    assign result_taken[p] = result[p].taken;
  end
  g6lc_bp_statcor #(.CVA6Cfg(cfg()), .bht_update_t(update_t), .NR_ENTRIES(64)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .vpc_i(pc),
    .bht_update_i(update), .pred_i(prediction), .pred_o(result)
  );
endmodule
'''
    for variant in ['before', 'absolute']:
        source = out / variant / 'source'
        source.mkdir(parents=True)
        for name in names:
            shutil.copy2(data / name, source / name)
        (source / 'g6lc_bp_statcor.sv').write_text(candidate if variant == 'absolute' else original)
        manifest = {name: digest(source / name) for name in names}
        (source.parent / 'sources.json').write_text(json.dumps(manifest, indent=2))
        cases = [(2, 4, 1)] if variant == 'before' else [(1, 4, 0), (2, 4, 0), (2, 4, 1), (4, 4, 1), (8, 4, 1), (2, 64, 1)]
        for slots, entries, rvc in cases:
            work = source.parent / f's{slots}-e{entries}-c{rvc}'
            work.mkdir()
            command = ['verilator', '--cc', '--main', '--exe', '--timing', '--assert', '--threads', '1', '-Wno-fatal', '--top-module', 'tb_g6lc_bp_statcor', f'-GSLOTS={slots}', f'-GENTRIES={entries}', f'-GRVC={rvc}', '--Mdir', str(work), '-o', 'statcor-test', *[str(source / name) for name in names]]
            make_command = ['make', '-C', str(work), '-f', 'Vtb_g6lc_bp_statcor.mk', '-j4', 'VERILATOR_ROOT=' + str(runtime)]
            for label, cmd in [('verilate', command), ('build', make_command)]:
                (work / (label + '-command.json')).write_text(json.dumps(cmd, indent=2))
                with (work / (label + '.log')).open('w') as log:
                    built = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=180)
                assert built.returncode == 0, str(work / (label + '.log'))
            deps = '\n'.join(p.read_text(errors='replace') for p in work.glob('*.d'))
            assert str(runtime / 'include/verilated_funcs.h') in deps
            assert str(Path(runtime_info['originalRoot']) / 'include/verilated_funcs.h') not in deps
            exe = work / 'statcor-test'
            trials = [False] if variant == 'before' else [False, True]
            for negative in trials:
                cmd = [str(exe)] + (['+oracle_negative'] if negative else [])
                run = subprocess.run(cmd, cwd=work, capture_output=True, text=True, timeout=30)
                text = run.stdout + run.stderr
                (work / ('negative.log' if negative else 'sim.log')).write_text(text)
                expect_failure = variant == 'before' or negative
                matched = (run.returncode != 0 and 'STATCOR_MISMATCH' in text and 'STATCOR_PASS' not in text) if expect_failure else (run.returncode == 0 and text.count('STATCOR_PASS ') == 1)
                results.append({'variant': variant, 'slots': slots, 'entries': entries, 'rvc': rvc, 'negativeControl': negative, 'expectedFailure': expect_failure, 'rc': run.returncode, 'matched': matched, 'executableSha256': digest(exe), 'runtimeHeaderSha256': header_sha, 'strictQualification': False})
                (out / 'results.json').write_text(json.dumps(results, indent=2))
                assert matched, str(work)
        (source / 'synth.sv').write_text(wrapper)
        script = 'read_slang --ignore-assertions --ignore-initial --top g6lc_statcor_synth ' + ' '.join(names[:-1] + ['synth.sv']) + '\nsynth -top g6lc_statcor_synth\ncheck -assert\nselect -assert-none t:$_DLATCH_*\nstat\n'
        (source / 'synth.ys').write_text(script)
        with (source.parent / 'synth.log').open('w') as log:
            synth = subprocess.run(['yosys', '-s', 'synth.ys'], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=180)
        assert synth.returncode == 0
        assert all(digest(source / name) == expected for name, expected in manifest.items())
    (out / 'runtime.json').write_text(json.dumps(runtime_info, indent=2))
    return 0


def predictor_synth_review():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    template = (data / 'g6lc64_smt2.f').read_text()
    synth_reference = os.environ.get('REVIEW_PREDICTOR_SYNTH_REUSE')
    identities = json.loads((Path(synth_reference) / 'results.json').read_text()) if synth_reference else {}
    if synth_reference:
        assert set(identities) == {'g6lc64_smt2', 'g6lc64_stream8'}
        assert all(r['rc'] == 0 for r in identities.values())
        (out / 'synth-reference.json').write_text(json.dumps({'source': synth_reference, 'results': identities}, indent=2))
    for target, run in [('g6lc64_smt2', 'review-predictor-smt2-20260916'), ('g6lc64_stream8', 'review-predictor-absolute-sc-20260916')]:
        evidence = Path('/opt/testharness/runs') / run / 'output'
        identity = json.loads((evidence / 'model.json').read_text())
        repo = Path(identity['sourceRoot'])
        sources = json.loads((evidence / 'sources.json').read_text())
        for name, expected in sources.items():
            assert digest(repo / name) == expected, name
        if synth_reference:
            assert identities[target]['model']['sha256'] == identity['sha256']
            assert digest(Path(synth_reference) / target / 'core.f') == identities[target]['manifestSha256']
            continue
        work = out / target
        work.mkdir()
        text = template.replace('E:/cva6/', str(repo) + '/')
        if target == 'g6lc64_stream8':
            text = text.replace('g6lc64_smt2_config_pkg.sv', 'g6lc64_stream8_config_pkg.sv')
        assert 'E:/cva6/' not in text
        for line in text.splitlines():
            line = line.strip()
            if line and not line.startswith('//') and not line.startswith('+define+'):
                path = Path(line.removeprefix('+incdir+'))
                assert path.exists() and path.resolve().is_relative_to(repo.resolve()), line
        manifest = work / 'core.f'
        manifest.write_text(text)
        script = f'read_slang -f {manifest} --top cva6 --single-unit -DHPDCACHE_ASSERT_OFF -DSYNTHESIS; hierarchy -check -top cva6; proc; opt -fast; check -assert; stat'
        command = ['yosys', '-p', script]
        (work / 'command.json').write_text(json.dumps(command, indent=2))
        with (work / 'synth.log').open('w') as log:
            run_result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        assert run_result.returncode == 0, str(work / 'synth.log')
        assert all(digest(repo / name) == expected for name, expected in sources.items())
        identities[target] = {'model': identity, 'manifestSha256': digest(manifest), 'rc': run_result.returncode, 'strictQualification': False}
        (out / 'results.json').write_text(json.dumps(identities, indent=2))
    before = Path('/opt/testharness/runs/review-iq-ring-core-20260916/output')
    before_identity = json.loads((before / 'model.json').read_text())
    before_sources = json.loads((before / 'sources.json').read_text())
    before_file = Path(before_identity['sourceRoot']) / 'core/fetch_B/frontend.sv'
    assert digest(before_file) == before_sources['core/fetch_B/frontend.sv']
    candidate_file = Path(identities['g6lc64_stream8']['model']['sourceRoot']) / 'core/fetch_B/frontend.sv'
    def selectors(text):
        matches = re.findall(r'assign\s+(vpc_bht|vpc_btb)\s*=\s*([^;]+);', text)
        assert len(matches) == 2
        replacements = {'CVA6Cfg.FpgaEn': 'fpga', 'CVA6Cfg.FpgaAlteraEn': 'altera', 'icache_dreq_i.valid': 'response_valid', 'icache_dreq_i.vaddr': 'response_pc', 'icache_vaddr_q': 'previous_pc', 'realigner_vaddr': 'current_pc'}
        result = {}
        for key, expression in matches:
            for old, new in replacements.items():
                expression = expression.replace(old, new)
            result[key] = expression
        return result
    old, new = selectors(before_file.read_text()), selectors(candidate_file.read_text())
    proofs = []
    for negative in [False, True]:
        work = out / ('pc-negative' if negative else 'pc-contract')
        work.mkdir()
        body = '''module g6lc_predictor_pc_contract (
 input fpga, altera, response_valid,
 input [63:0] current_pc, previous_pc, response_pc,
 output [63:0] old_bht, old_btb, new_bht, new_btb
);
'''
        body += f"assign old_bht = {old['vpc_bht']};\nassign old_btb = {old['vpc_btb']};\n"
        body += f"assign new_bht = ({new['vpc_bht']})" + (" ^ 64'h1" if negative else '') + ';\n'
        body += f"assign new_btb = {new['vpc_btb']};\n"
        body += '''always @* begin
 if (fpga) begin
   assert(new_bht == old_bht);
   assert(new_btb == old_btb);
 end else begin
   assert(new_bht == current_pc);
   assert(new_btb == current_pc);
 end
end
endmodule
'''
        (work / 'pc.v').write_text(body)
        command = ['yosys', '-p', 'read_verilog -formal pc.v; prep -top g6lc_predictor_pc_contract; flatten; opt; chformal -lower; sat -verify -prove-asserts -set-def-inputs -show-ports']
        (work / 'command.json').write_text(json.dumps(command, indent=2))
        run_result = subprocess.run(command, cwd=work, capture_output=True, text=True, timeout=60)
        text = run_result.stdout + run_result.stderr
        (work / 'proof.log').write_text(text)
        matched = ('proof did fail' in text and run_result.returncode != 0) if negative else ('SUCCESS!' in text and run_result.returncode == 0)
        proofs.append({'negativeControl': negative, 'rc': run_result.returncode, 'matched': matched, 'sourceSha256': digest(work / 'pc.v')})
        (out / 'pc-results.json').write_text(json.dumps(proofs, indent=2))
        assert matched, str(work / 'proof.log')
    return 0


def predictor_promotion_review():
    out = Path(os.environ['TH_OUT_DIR'])
    data = Path(os.environ['TH_DATA_DIR'])
    reference = Path('/opt/testharness/runs/review-predictor-absolute-sc-20260916/output')
    model = json.loads((reference / 'model.json').read_text())
    sources = json.loads((reference / 'sources.json').read_text())
    assert digest(Path(model['exe'])) == model['sha256']
    def normalized(text):
        text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
        text = re.sub(r'//[^\n]*', '', text)
        return '\n'.join(line.strip() for line in text.splitlines() if line.strip())
    results = []
    for name in ['core/fetch_B/frontend.sv', 'core/frontend/g6lc_bp_statcor.sv']:
        tested = Path(model['sourceRoot']) / name
        retained = data / Path(name).name
        assert digest(tested) == sources[name]
        assert normalized(tested.read_text()) == normalized(retained.read_text()), name
        results.append({'file': name, 'testedSha256': digest(tested), 'retainedSha256': digest(retained), 'nonCommentSourceIdentical': True, 'referenceModel': model['sha256']})
    (out / 'results.json').write_text(json.dumps(results, indent=2))
    return 0


def fetch_window_metrics(ic, events, begin, end, head):
    clock = [r for r in ic if begin <= int(r['t']) < end]
    assert [int(r['t']) for r in clock] == list(range(begin, end)), 'capture-complete'
    selected = [(kind, r) for kind, r in events if 't' in r and begin <= int(r['t']) < end]
    fetched = [r for kind, r in selected if kind == 'ot-fetch']
    assert fetched and len(fetched) % 9 == 0, 'complete-iterations'
    for i, r in enumerate(fetched):
        assert int(r['h']) == 0 and int(r['p']) == 0 and int(r['flush']) == 0 and int(r['fire']) == 1, 'fetch-transfer'
        assert int(r['pc'], 16) == head + 4 * (i % 9) and int(r['bits'], 16) & 3 == 3, 'instruction-stream'
    requests = [r for r in clock if int(r['req']) and int(r['ready'])]
    request_times = [int(r['t']) for r in requests]
    response_latencies = []
    pending = None
    seen_request = False
    for r in (r for r in ic if begin <= int(r['t']) <= end):
        if int(r['delivered']):
            if pending is not None:
                assert int(r['pc'], 16) == int(pending['offered'], 16), 'response-owner'
                response_latencies.append(int(r['t']) - int(pending['t']))
                pending = None
            else:
                assert not seen_request, 'unmatched-response'
        if int(r['t']) < end and int(r['req']) and int(r['ready']):
            assert pending is None, 'multiple-outstanding'
            pending = r
            seen_request = True
    assert pending is None and len(response_latencies) == len(requests), 'response-complete'
    retired = [r for kind, r in selected if kind == 'ot-retire' and int(r['macro_ack']) and not int(r['drop']) and not int(r['ex'])]
    allocated = [r for kind, r in selected if kind == 'ot-issue']
    branches = [r for kind, r in selected if kind == 'ot-branch']
    controls = [r for kind, r in selected if kind == 'ot-control']
    return {
        'beginInclusive': begin, 'endExclusive': end, 'clockCycles': end - begin,
        'completeFetchIterations': len(fetched) // 9, 'iqTransfers': len(fetched),
        'acceptedIcacheRequests': len(requests), 'deliveredIcacheResponses': sum(int(r['delivered']) for r in clock),
        'requestIntervalHistogram': dict(Counter(b - a for a, b in zip(request_times, request_times[1:]))),
        'requestToResponseHistogram': dict(Counter(response_latencies)),
        'stateCycleHistogram': dict(Counter(int(r['state']) for r in clock)),
        'offeredRequestCycles': sum(int(r['req']) for r in clock),
        'notReadyWithRequestCycles': sum(int(r['req']) and not int(r['ready']) for r in clock),
        'icacheMissEvents': sum(int(r['miss']) for r in clock),
        'icacheMemoryRequestCycles': sum(int(r['mem_req']) for r in clock),
        'kill1Cycles': sum(int(r['kill1']) for r in clock),
        'kill2Cycles': sum(int(r['kill2']) for r in clock),
        'flushCycles': sum(int(r['flush']) for r in clock),
        'decodedAllocations': len(allocated), 'committedRetirements': len(retired),
        'resolvedBranches': len(branches), 'mispredicts': sum(int(r['mispredict']) for r in branches),
        'controlEvents': len(controls), 'iqEmptyCycles': None, 'backendStallCycles': None,
        'missingObservations': 'No cycle-level IQ occupancy/ready or backend stall reason in this observer; missing transfers are not classified as empty/stalled.'
    }


def fetch_supply_review():
    root = Path(os.environ['REVIEW_FETCH_INPUTS'])
    controls_file = Path(os.environ['REVIEW_FETCH_CONTROLS'])
    out = Path(os.environ['TH_OUT_DIR'])
    out.mkdir(exist_ok=True)
    records = json.loads((root / 'results.json').read_text())
    assert len(records) == 3 and all(r['matched'] and r['absoluteCorrector'] for r in records)
    assert all(r['modelSha256'] == '48038fd479a89623921e300a08530f834347c42d9a5cf8fb120c34034ae00108' for r in records)
    assert all(r['elfSha256'] == 'c7650b2fc1dd65b9934a5080bd73969791fbf9f63395e8ee88cace70be884972' for r in records)
    assert all(r['report'] == records[0]['report'] and r['retirement'] == records[0]['retirement'] for r in records)
    assert records[1]['traces'] == records[2]['traces'] and records[1]['observer']
    control = next(r for r in json.loads(controls_file.read_text()) if r['payload'] == 'locality-1024')
    assert control['elfSha256'] == records[1]['elfSha256'] and control['measuredLoads'] == 8192
    trial = root / 'trial-1'
    ic_name = next(n for n in records[1]['traces'] if n.startswith('icache-trace-') and '.gen_core[0].' in n)
    ot_name = 'operand-trace-0.log'
    for name in [ic_name, ot_name]:
        assert digest(trial / name) == records[1]['traces'][name], 'trace-identity'
    def parse(path):
        result = []
        for line in path.read_text().splitlines():
            match = re.fullmatch(r'\[([^]]+)\] (.*)', line)
            assert match, 'trace-syntax'
            result.append((match[1], dict(part.split('=', 1) for part in match[2].split())))
        return result
    ic_events, events = parse(trial / ic_name), parse(trial / ot_name)
    ic_config = next(r for kind, r in ic_events if kind == 'ic-config')
    ot_config = next(r for kind, r in events if kind == 'ot-config')
    assert int(ic_config['fetch_bits']) == 32 and int(ot_config['harts']) == 1 and int(ot_config['issue']) == 1
    assert int(ic_config['limit']) == int(ot_config['limit'])
    roi_pc = control['symbols']['locality_roi_begin']
    calls = [r for kind, r in events if kind == 'ot-retire' and int(r['pc'], 16) == roi_pc and int(r['macro_ack']) and not int(r['drop']) and not int(r['ex'])]
    assert len(calls) == 1, 'roi-marker'
    call = calls[0]
    allocated = [r for kind, r in events if kind == 'ot-issue' and r['gen'] == call['gen'] and r['tid'] == call['tid']]
    assert len(allocated) == 1 and int(allocated[0]['pc'], 16) == roi_pc
    word = int(allocated[0]['bits'], 16)
    assert word & 127 == 0x6f, 'roi-call-opcode'
    immediate = ((word >> 31) << 20) | (((word >> 12) & 255) << 12) | (((word >> 20) & 1) << 11) | (((word >> 21) & 1023) << 1)
    if immediate & (1 << 20):
        immediate -= 1 << 21
    head = roi_pc + immediate
    roi_ends = [int(r['t']) for kind, r in events if kind == 'ot-retire' and int(r['pc'], 16) == control['symbols']['locality_roi_end'] and int(r['macro_ack']) and not int(r['drop'])]
    cutoff = min([int(ic_config['limit']) + 1, *roi_ends])
    heads = [int(r['t']) for kind, r in events if kind == 'ot-fetch' and int(r['pc'], 16) == head and int(call['t']) < int(r['t']) < cutoff]
    assert len(heads) >= 2, 'roi-prefix'
    begin, end = heads[0], heads[-1]
    ic = [r for kind, r in ic_events if kind == 'ic-cycle']
    measured = fetch_window_metrics(ic, events, begin, end, head)
    negatives = {}
    for name, rows, modified in [
        ('missing-clock-row', [r for r in ic if int(r['t']) != begin], events),
        ('wrong-fetch-pc', ic, [(kind, dict(r, pc=hex(head + 4))) if kind == 'ot-fetch' and int(r['t']) == begin else (kind, r) for kind, r in events])
    ]:
        try:
            fetch_window_metrics(rows, modified, begin, end, head)
        except AssertionError as error:
            negatives[name] = str(error)
    assert negatives == {'missing-clock-row': 'capture-complete', 'wrong-fetch-pc': 'instruction-stream'}
    result = {'scope': 'maximal complete loop-head-to-loop-head interval after ROI call retirement within the bounded core-0 capture; not the full ROI or multicore scaling', 'inputs': {str(root / 'results.json'): digest(root / 'results.json'), str(controls_file): digest(controls_file), ic_name: digest(trial / ic_name), ot_name: digest(trial / ot_name)}, 'modelSha256': records[1]['modelSha256'], 'elfSha256': control['elfSha256'], 'loopHead': hex(head), 'captureLimit': int(ic_config['limit']), 'fullRoiReportUnchanged': records[0]['report'], 'measurements': measured, 'negativeControls': negatives, 'strictQualification': False}
    (out / 'results.json').write_text(json.dumps(result, indent=2))
    return 0


def main():
    if os.environ.get('REVIEW_FETCH_SUPPLY') == '1':
        return fetch_supply_review()
    if os.environ.get('REVIEW_PREDICTOR_PROMOTION') == '1':
        return predictor_promotion_review()
    if os.environ.get('REVIEW_PREDICTOR_SYNTH') == '1':
        return predictor_synth_review()
    if os.environ.get('REVIEW_PREDICTOR_LEAF') == '1':
        return predictor_leaf_review()
    if os.environ.get('REVIEW_LOCALITY_ICACHE') == '1':
        return locality_icache_review()
    if any(os.environ.get(mode) == '1' for mode in ['REVIEW_CACHEABILITY_WORK', 'REVIEW_CACHEABILITY_LOCALITY', 'REVIEW_PREDICTOR_WORK']):
        return cacheability_work_review()
    if os.environ.get('REVIEW_CACHEABILITY') == '1':
        return cacheability_review()
    data = Path(os.environ['TH_DATA_DIR'])
    out = Path(os.environ['TH_OUT_DIR'])
    model = Path(os.environ['REVIEW_MODEL'])
    expected = os.environ['REVIEW_MODEL_SHA256']
    if digest(model) != expected:
        raise RuntimeError('model provenance mismatch')
    tool = os.environ['REVIEW_TOOL_PREFIX']
    source_name = os.environ.get('REVIEW_SOURCE', 'mini_checked_work.S')
    if Path(source_name).name != source_name:
        raise RuntimeError('source must be an uploaded filename')
    source = (data / source_name).read_text()
    keep_encoding = os.environ.get('REVIEW_KEEP_ENCODING', '0') == '1'
    cap = int(os.environ.get('REVIEW_CYCLE_LIMIT', '500000'))
    if cap < 10240 or cap > 1000000:
        raise ValueError('cycle cap outside 10240..1000000')
    nbytes = int(os.environ.get('REVIEW_NBYTES', '49152'))
    if nbytes < 4096 or nbytes > 49152 or nbytes % 8:
        raise ValueError('checked-work size must be an 8-byte multiple in 4096..49152')
    linker = out / 'checked.ld'
    linker.write_text('ENTRY(_start)\nSECTIONS { . = 0x80000000; .text : { *(.text.init) *(.text*) } . = 0x80001000; .tohost : { *(.tohost) } . = 0x80001080; .data : { *(.data*) } .bss : { *(.bss*) } }\n')
    if os.environ.get('REVIEW_CASE', '') not in {'', 'norvc-n1', 'rvc-n1', 'norvc-n2', 'rvc-n2'}:
        raise RuntimeError('unknown checked-work case')
    results = []
    for compressed, workers in [(False, 1), (True, 1), (False, 2), (True, 2)]:
        tag = f'{"rvc" if compressed else "norvc"}-n{workers}'
        if os.environ.get('REVIEW_CASE') and os.environ['REVIEW_CASE'] != tag:
            continue
        work = out / tag
        work.mkdir()
        asm = work / 'checked.S'
        asm.write_text(source.replace('.option norvc', '.option rvc') if compressed and not keep_encoding else source)
        elf = work / 'checked.elf'
        cmd = [tool+'gcc', '-march=rv64imac_zicsr', '-mabi=lp64', '-nostdlib', '-static',
               '-Wl,--no-relax', '-T', str(linker), f'-DNWORKERS={workers}', f'-DNBYTES={nbytes}',
               str(asm), '-o', str(elf)]
        subprocess.run(cmd, check=True, capture_output=True)
        disassembly = subprocess.check_output([tool+'objdump', '-d', str(elf)], text=True)
        (work / 'disassembly.txt').write_text(disassembly)
        widths = [len(x) for x in re.findall(r'^\s*[0-9a-f]+:\s+([0-9a-f]+)\s', disassembly, re.M)]
        if not widths or (not compressed and any(w != 8 for w in widths)):
            raise RuntimeError('uncompressed encoding check failed')
        run_cmd = [str(model), '-m', str(cap), '-s', '1', '+debug_disable', str(elf)]
        env = {'PATH':'/usr/bin:/bin', 'CVA6_TRACE_SPEC':
               'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3; log gpr after=110000 max=80 gpr=a0,a1,s0,s1,s3,s4,t5,t6; log mem after=110000 off=0x100000 max=2'}
        if os.environ.get('REVIEW_TRACE_AFTER'):
            after = int(os.environ['REVIEW_TRACE_AFTER'])
            env['CVA6_TRACE_SPEC'] = (
                'exit cookie off=0x1000 val=1; exit cookie off=0x1000 val=3; '
                f'log gpr after={after} max=3000 gpr=a0,a1,s0,s1,s3,s4,t5,t6')
        with (work / 'sim.log').open('w') as log:
            run = subprocess.run(run_cmd, cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=150)
        text = (work / 'sim.log').read_text(errors='replace')
        cookies = re.findall(r'\[cookie-exit\] t=(\d+) \[1000\]=0x([0-9a-fA-F]+)', text)
        clean = run.returncode == 0 and '%Error' not in text and 'Assertion failed' not in text
        status = ('pass' if clean and len(cookies) == 1 and int(cookies[0][1],16) == 1
                  else 'fail' if cookies or not clean else 'no-verdict')
        record = {'tag':tag,'status':status,'rc':run.returncode,'cookie':cookies,
                  'elfSha256':digest(elf),'sourceSha256':digest(asm),'compile':cmd,'run':run_cmd,
                  'compressedInstructions':sum(w == 4 for w in widths)}
        results.append(record)
        excerpt = '\n'.join(line for line in text.splitlines() if '[trace]' in line or '[cookie-exit]' in line)
        (work / 'trace.txt').write_text(excerpt)
        print(record, flush=True)
        print(excerpt[-4000:], flush=True)
    if digest(model) != expected:
        raise RuntimeError('model changed during runs')
    (out / 'result.json').write_text(json.dumps({'executableSha256':expected,
        'strictQualification':False,'runs':results},indent=2))
    return 0 if results and all(r['status'] == 'pass' for r in results) else 1


if __name__ == '__main__':
    sys.exit(main())
