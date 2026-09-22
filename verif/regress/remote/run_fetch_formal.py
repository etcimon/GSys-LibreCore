#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded live fetch assertions and separate reachability tasks; proxy py only."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time
import re


def sat_profile(formal, name):
    task = (formal / (name + '.sby')).read_text()
    script = task.split('[script]\n', 1)[1].split('[files]', 1)[0]
    script = ' '.join(line.split('#', 1)[0].replace('\\', ' ').strip() for line in script.splitlines())
    script = ' '.join(script.split())
    files = 'g6lc64_smt2_config_pkg.sv config_pkg.sv riscv_pkg.sv ariane_pkg.sv g6lc_fetch_pkg.sv cva6_fifo_v3.sv instr_queue.sv g6lc_fetch_iq_order_props.sv'
    expected = 'read_slang --std 1800-2017 --top g6lc_fetch_iq_order_props -DFORMAL ' + files + ' prep -top g6lc_fetch_iq_order_props'
    if script != expected:
        raise ValueError('SAT review does not support altered SBY preprocessing or parameters')
    properties = (formal / (name + '_props.sv')).read_text()
    geometry = {}
    for key in ['FW', 'AB', 'NH', 'NI', 'VLEN', 'XLEN', 'GPLEN']:
        match = re.search(r'(?:parameter|localparam)\s+int\s+unsigned\s+' + key + r'\s*=\s*(\d+)', properties)
        if match is None:
            raise ValueError('unsupported SAT geometry declaration: ' + key)
        geometry[key] = int(match[1])
    if geometry != {'FW': 64, 'AB': 3, 'NH': 2, 'NI': 2, 'VLEN': 32, 'XLEN': 32, 'GPLEN': 32}:
        raise ValueError('SAT review is scoped to the documented four-slot 32-bit envelope')
    return {'geometry': geometry, 'stateSemantics': 'two-state', 'baseFrames': 4, 'maxInductionLength': 4}


def sat_cover(formal, out, name, task_timeout):
    started = time.monotonic()
    task_text = (formal / (name + '.sby')).read_text()
    depth = int(re.search(r'^cover:\s*depth\s+(\d+)', task_text, re.M)[1])
    original = (formal / (name + '_props.sv')).read_text()
    goals = []
    def replace_cover(match):
        index = len(goals)
        goals.append(match[1])
        return f'reach_{index} <= reach_{index} || ({match[1]});'
    transformed = re.sub(r'\bcover\s*\((.*?)\);', replace_cover, original, flags=re.S)
    assert len(goals) == 12
    outputs = ',\n    '.join('output logic reach_' + str(i) for i in range(len(goals)))
    outputs += ',\n    output logic unreachable_o,\n    output logic [5:0] observed_count,\n    output logic [FW/16-1:0] observed_empty, observed_full'
    marker = 'watch_slot_i\n);'
    assert transformed.count(marker) == 1
    transformed = transformed.replace(marker, 'watch_slot_i,\n    ' + outputs + '\n);')
    transformed = transformed.replace('module ' + name + '_props', 'module g6lc_fetch_iq_reach_props', 1)
    initial = '\n'.join(f'  initial reach_{i} = 0;' for i in range(len(goals)))
    initial += '\n  assign unreachable_o = 0;\n  assign observed_count = ref_count_q;\n  assign observed_empty = dut.instr_queue_empty;\n  assign observed_full = dut.instr_queue_full;\n'
    assert transformed.count('\n`endif\n') == 1
    transformed = transformed.replace('\n`endif\n', '\n' + initial + '\n`endif\n', 1)
    work = out / 'sat-cover'
    work.mkdir()
    source = work / 'g6lc_fetch_iq_reach_props.sv'
    source.write_text(transformed)
    files = [(formal / line).resolve() for line in task_text.split('[files]\n', 1)[1].splitlines() if line and not line.startswith('#')]
    files = [source if p.name == name + '_props.sv' else p for p in files]
    (work / 'goals.json').write_text(json.dumps({'depth': depth, 'goals': goals, 'transformedSha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'originalSha256': hashlib.sha256(original.encode()).hexdigest()}, indent=2))
    build = 'read_slang --std 1800-2017 --top g6lc_fetch_iq_reach_props -DFORMAL ' + ' '.join(map(str, files))
    build += '\nprep -top g6lc_fetch_iq_reach_props\nchformal -assert -cover -remove\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\nwrite_rtlil reach.il\n'
    (work / 'build.ys').write_text(build)
    def run(script, logfile):
        remaining = task_timeout - (time.monotonic() - started)
        if remaining <= 0:
            return 124
        with logfile.open('w') as log:
            proc = subprocess.Popen(['yosys', '-s', str(script)], cwd=work, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                return proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                proc.wait()
                return 124
    rc = run(work / 'build.ys', work / 'build.log')
    if rc != 0:
        (out / 'result.json').write_text(json.dumps([{'mode': 'sat-cover-build', 'rc': rc, 'timeoutSeconds': task_timeout}], indent=2))
        return 1
    results = []
    for index in range(len(goals) + 1):
        negative = index == len(goals)
        signal_name = 'unreachable_o' if negative else 'reach_' + str(index)
        script = work / (signal_name + '.ys')
        script.write_text(f'read_rtlil reach.il\nsat -seq {depth} -set-assumes -prove {signal_name} 0 -prove-skip {depth - 1} -show-ports -dump_vcd {signal_name}.vcd -verify\n')
        log = work / (signal_name + '.log')
        rc = run(script, log)
        text = log.read_text() if log.exists() else ''
        reached = rc != 0 and rc != 124 and 'model found: FAIL!' in text and 'proof did fail' in text and (work / (signal_name + '.vcd')).is_file()
        matched = (rc == 0 and 'SUCCESS!' in text) if negative else reached
        results.append({'goal': signal_name, 'expression': 'constant false' if negative else goals[index], 'negativeControl': negative, 'rc': rc, 'reached': reached, 'matched': matched, 'depth': depth, 'stateSemantics': 'two-state', 'timeoutSeconds': task_timeout})
        (out / 'result.json').write_text(json.dumps(results, indent=2))
        if not matched:
            break
    return 0 if len(results) == len(goals) + 1 and all(r['matched'] for r in results) else 1


def sat_prove(formal, out, name, task_timeout):
    negative = os.environ.get('REVIEW_FORMAL_NEGATIVE') == '1'
    task_text = (formal / (name + '.sby')).read_text()
    work = out / 'sat-prove'
    work.mkdir()
    files = [(formal / line).resolve() for line in task_text.split('[files]\n', 1)[1].splitlines() if line and not line.startswith('#')]
    if negative:
        queue = next(p for p in files if p.name == 'instr_queue.sv')
        original = queue.read_text()
        before = 'fetch_entry_o[p].instruction = instr_data_out[f].instr;'
        after = "fetch_entry_o[p].instruction = instr_data_out[f].instr ^ 32'h1;"
        assert original.count(before) == 1
        faulty = work / 'instr_queue_negative.sv'
        faulty.write_text(original.replace(before, after))
        files = [faulty if p == queue else p for p in files]
        (work / 'mutation.json').write_text(json.dumps({'originalSha256': hashlib.sha256(queue.read_bytes()).hexdigest(), 'mutatedSha256': hashlib.sha256(faulty.read_bytes()).hexdigest(), 'before': before, 'after': after}, indent=2))
    script = 'read_slang --std 1800-2017 --top ' + name + '_props -DFORMAL ' + ' '.join(map(str, files))
    script += '\nprep -top ' + name + '_props\nchformal -cover -remove\nasync2sync\nchformal -lower\nflatten\nmemory_map\nopt -full\ndffunmap\nopt_clean -purge\n'
    script += 'sat -seq 4 -set-assumes -prove-asserts -show-ports -dump_vcd base.vcd -verify\n'
    if not negative:
        script += 'sat -seq 1 -tempinduct -maxsteps 4 -set-assumes -prove-asserts -show-ports -dump_vcd induction.vcd -verify\n'
    (work / 'prove.ys').write_text(script)
    with (work / 'proof.log').open('w') as log:
        proc = subprocess.Popen(['yosys', '-s', 'prove.ys'], cwd=work, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = proc.wait(timeout=task_timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait()
            rc = 124
    text = (work / 'proof.log').read_text()
    matched = (rc != 0 and rc != 124 and 'proof did fail' in text and (work / 'base.vcd').is_file()) if negative else (rc == 0 and 'SUCCESS!' in text and 'Induction step proven' in text)
    (out / 'result.json').write_text(json.dumps([{'mode': 'sat-prove', 'negativeControl': negative, 'rc': rc, 'matched': matched, 'stateSemantics': 'two-state', 'timeoutSeconds': task_timeout}], indent=2))
    return 0 if matched else 1


def token_bmc(formal, out, task_timeout):
    """Fetch-response ownership by request token: single-task sby bmc against the
    live frontend with an independent I$ ledger. The negative removes the
    frontend's take gate so a killed response is accepted; the ledger must then
    produce a counterexample, or the proof is vacuous."""
    mutate = os.environ.get("REVIEW_FORMAL_TOKEN_MUTATE") == "1"
    record = {"mode": "token-bmc", "negativeControl": mutate, "timeoutSeconds": task_timeout}
    if mutate:
        frontend = formal / "../frontend.sv"
        original = frontend.read_text()
        before = "      && !kill_drop\n"
        after = "      && 1'b1\n"
        if original.count(before) != 1:
            raise ValueError("token take-gate mutation site changed")
        frontend.write_text(original.replace(before, after))
        record["mutation"] = {"before": before, "after": after,
                              "originalSha256": hashlib.sha256(original.encode()).hexdigest()}
    log_path = out / "g6lc_fetch_token-bmc.log"
    with log_path.open("w") as log:
        proc = subprocess.Popen(["sby", "-f", "g6lc_fetch_token.sby"], cwd=formal,
                                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            rc = proc.wait(timeout=task_timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait()
            rc = 124
    text = log_path.read_text()
    asserts = 0
    ywa = formal / "g6lc_fetch_token/model/design_aiger.ywa"
    aiger_log = formal / "g6lc_fetch_token/model/design_aiger.log"
    if ywa.is_file():
        asserts = len(json.loads(ywa.read_text()).get("asserts", []))
    elif aiger_log.is_file():
        found = re.search(r"(\d+)\s+\$?asserts?", aiger_log.read_text())
        asserts = int(found[1]) if found else 0
    record.update(rc=rc, assertCount=asserts,
                  matched=(rc != 0 and rc != 124 and "FAIL" in text and asserts > 0) if mutate else
                          (rc == 0 and "PASS" in text and asserts > 0))
    (out / "result.json").write_text(json.dumps([record], indent=2))
    return 0 if record["matched"] else 1


def main():
    data = Path(os.environ["TH_DATA_DIR"])
    out = Path(os.environ["TH_OUT_DIR"])
    formal = out / "source/core/fetch_B/formal"
    formal.mkdir(parents=True)
    hashes = {}
    selected = os.environ.get("REVIEW_FORMAL_TASK", "")
    modes_text = os.environ.get("REVIEW_FORMAL_MODES", "")
    modes = modes_text.split(",") if modes_text else None
    if modes is not None and (not selected or len(modes) != len(set(modes)) or any(m not in {"cover", "bmc", "prove"} for m in modes)):
        raise ValueError("formal modes require one selected task and unique cover/bmc/prove names")
    task_timeout = int(os.environ.get("REVIEW_FORMAL_TIMEOUT", "120"))
    if not 120 <= task_timeout <= 600:
        raise ValueError("formal timeout outside 120..600 seconds")
    if selected not in {"", "g6lc_fetch_iq", "g6lc_fetch_realign", "g6lc_fetch_iq_order", "g6lc_fetch_smt", "g6lc_fetch_token"}:
        raise ValueError("unknown formal task")
    names = [selected] if selected else ["g6lc_fetch_realign", "g6lc_fetch_iq"]
    for name in names:
        task = data / (name + ".sby")
        shutil.copy2(task, formal / task.name)
        hashes[str((formal / task.name).relative_to(out))] = hashlib.sha256(task.read_bytes()).hexdigest()
        for entry in task.read_text().split("[files]\n", 1)[1].splitlines():
            if not entry or entry.startswith("#"):
                continue
            src = data / Path(entry).name
            dst = (formal / entry).resolve()
            if not dst.is_relative_to(out.resolve()):
                raise RuntimeError("task input outside snapshot")
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            hashes[str(dst.relative_to(out))] = hashlib.sha256(dst.read_bytes()).hexdigest()
    (out / "sources.json").write_text(json.dumps(hashes, indent=2))
    if selected == "g6lc_fetch_token":
        if modes is not None:
            raise ValueError("the token task is single-mode bmc")
        return token_bmc(formal, out, task_timeout)
    if os.environ.get("REVIEW_FORMAL_NEGATIVE") == "1" and os.environ.get("REVIEW_FORMAL_SAT_PROVE") != "1":
        raise ValueError("instruction mutation is available only for SAT prove")
    if os.environ.get("REVIEW_FORMAL_SAT_PROVE") == "1" or os.environ.get("REVIEW_FORMAL_SAT_COVER") == "1":
        if selected != "g6lc_fetch_iq_order":
            raise ValueError("SAT review supports only the IQ order task")
        (out / "sat-profile.json").write_text(json.dumps(sat_profile(formal, selected), indent=2))
    if os.environ.get("REVIEW_FORMAL_SAT_PROVE") == "1":
        if selected != "g6lc_fetch_iq_order" or modes != ["prove"] or os.environ.get("REVIEW_FORMAL_SAT_COVER") == "1":
            raise ValueError("SAT prove requires the IQ order task and prove-only mode")
        return sat_prove(formal, out, selected, task_timeout)
    if os.environ.get("REVIEW_FORMAL_SAT_COVER") == "1":
        if selected != "g6lc_fetch_iq_order" or modes != ["cover"]:
            raise ValueError("SAT cover requires the IQ order task and cover-only mode")
        return sat_cover(formal, out, selected, task_timeout)
    results = []
    for name in names:
        selected_modes = modes if modes is not None else ["cover", "prove" if name == "g6lc_fetch_smt" else "bmc"]
        if modes is not None:
            task_text = (formal / (name + ".sby")).read_text()
            declared = {line.split()[0] for line in task_text.split("[tasks]\n", 1)[1].split("[", 1)[0].splitlines() if line.strip() and not line.lstrip().startswith("#")}
            if not set(modes) <= declared:
                raise ValueError("requested mode absent from selected task")
        for mode in selected_modes:
            log_path = out / f"{name}-{mode}.log"
            with log_path.open("w") as log:
                proc = subprocess.Popen(["sby", "-f", name + ".sby", mode], cwd=formal,
                                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    rc = proc.wait(timeout=task_timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait()
                    rc = 124
            status_file = formal / f"{name}_{mode}/status"
            status = status_file.read_text().strip() if status_file.exists() else "MISSING"
            results.append({"task": name, "mode": mode, "rc": rc, "status": status, "timeoutSeconds": task_timeout})
            (out / "result.json").write_text(json.dumps(results, indent=2))
            print(results[-1], flush=True)
            print(log_path.read_text()[-2500:], flush=True)
    (out / "result.json").write_text(json.dumps(results, indent=2))
    return 0 if all(r["rc"] == 0 and r["status"].startswith("PASS") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
