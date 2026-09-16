#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import copy
import hashlib
import json
import os
from pathlib import Path
import re

MASK = (1 << 64) - 1
HEX_FIELDS = set('pc bits a b imm rf1 rf2 value result cause wdata paddr vaddr raw data be index tag target cancel saved_pc restore_pc transport_pc bypass'.split())


def signed(value, width):
    value &= (1 << width) - 1
    return value - (1 << width) if value & (1 << (width - 1)) else value


def expand_rvc(word):
    quadrant, funct = word & 3, (word >> 13) & 7
    rd, rs2 = (word >> 7) & 31, (word >> 2) & 31
    immediate = signed(((word >> 12) & 1) << 5 | rs2, 6)
    if quadrant == 1:
        if funct == 0:
            return ((immediate & 4095) << 20) | (rd << 15) | (rd << 7) | 0x13
        if funct == 1 and rd:
            return ((immediate & 4095) << 20) | (rd << 15) | (rd << 7) | 0x1b
        if funct == 2 and rd:
            return ((immediate & 4095) << 20) | (rd << 7) | 0x13
        if funct == 3 and rd not in (0, 2) and immediate:
            return ((immediate & 0xfffff) << 12) | (rd << 7) | 0x37
    if quadrant == 2:
        if funct == 0 and rd:
            amount = ((word >> 12) & 1) << 5 | rs2
            return (amount << 20) | (rd << 15) | (1 << 12) | (rd << 7) | 0x13
        if funct == 4 and rd:
            if rs2:
                source = rd if word & 0x1000 else 0
                return (rs2 << 20) | (source << 15) | (rd << 7) | 0x33
            link = 1 if word & 0x1000 else 0
            return (rd << 15) | (link << 7) | 0x67
    return None


def read_events(path):
    events = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = re.fullmatch(r'\[ot-([a-z-]+)\] (.*)', line)
        if not match:
            raise ValueError(f'unrecognized trace row {number}')
        record = {'kind': match[1], 'line': number}
        for item in match[2].split():
            key, value = item.split('=', 1)
            record[key] = int(value, 16 if key in HEX_FIELDS else 10)
        events.append(record)
    if not events or events[0]['kind'] != 'config' or events[-1]['kind'] != 'end':
        raise ValueError('incomplete trace')
    if events[0]['xlen'] != 64:
        raise ValueError('reference profile requires XLEN64')
    return events


def analyze(events, image, index_bits):
    cfg = events[0]
    regs = [[0] * 32 for _ in range(cfg['harts'])]
    next_pc = [None] * cfg['harts']
    memory = {}
    issues = {}
    linked = {}
    execution = {}
    for event in events:
        if 'gen' in event:
            linked.setdefault(event['gen'], []).append(event)
        if event['kind'] == 'issue':
            if event['gen'] in issues:
                raise ValueError('duplicate generation')
            issues[event['gen']] = event
        if event['kind'] == 'ex':
            execution.setdefault((event['gen'], event['t']), []).append(event)
    counts = {'retired': 0, 'known_loads': 0, 'unchecked_loads': 0, 'stores': 0, 'operand_checks': 0}
    skipped = []

    def failure(kind, issue, retire, expected, actual, event=None):
        return {'status': 'violation', 'contract': kind, 'expected': hex(expected), 'actual': hex(actual), 'issue': issue, 'retire': retire, 'event': event, 'linkedEvents': linked.get(retire.get('gen'), []), 'counts': dict(counts), 'skipped': list(skipped)}

    retires = sorted((e for e in events if e['kind'] == 'retire'), key=lambda e: (e['t'], e['p']))
    for retire in retires:
        if not retire['ack']:
            if retire['we'] and retire['waddr']:
                return failure('register-write-without-retirement', {}, retire, 0, retire['we'])
            continue
        issue = issues.get(retire['gen'])
        if issue is None:
            return failure('retirement-without-captured-allocation', {}, retire, 1, 0)
        h, pc, inst = issue['h'], issue['pc'], issue['bits']
        if h >= len(regs) or retire['h'] != h or retire['pc'] != pc or retire['tid'] != issue['tid']:
            return failure('allocation-retirement-identity', issue, retire, pc, retire['pc'])
        if retire['ex']:
            return {'status': 'unsupported', 'reason': 'architectural exception outside reference profile', 'issue': issue, 'retire': retire, 'counts': counts}
        ilen = 2 if issue['compressed'] else 4
        if (inst & 3 != 3) != bool(issue['compressed']):
            return failure('instruction-length-at-issue', issue, retire, 2 if inst & 3 != 3 else 4, ilen)
        if pc in image:
            word, width = image[pc]
            if width != ilen:
                return failure('instruction-length-from-image', issue, retire, width, ilen)
            if word != inst & ((1 << (8 * ilen)) - 1):
                return failure('instruction-bytes-at-issue', issue, retire, word, inst)
        if issue['compressed']:
            inst = expand_rvc(inst & 65535)
            if inst is None:
                return {'status': 'unsupported', 'reason': 'compressed instruction outside reference subset', 'issue': issue, 'retire': retire, 'counts': counts}
        if next_pc[h] is not None and next_pc[h] != pc:
            return failure('architectural-instruction-sequence', issue, retire, next_pc[h], pc)
        opcode, rd, f3, rs1, rs2, f7 = inst & 127, (inst >> 7) & 31, (inst >> 12) & 7, (inst >> 15) & 31, (inst >> 20) & 31, inst >> 25
        a, b = regs[h][rs1], regs[h][rs2]
        result = None
        expected_a = None
        expected_b = None
        b_mask = MASK
        target = (pc + ilen) & MASK
        store = None
        load = None
        operation = ''
        if opcode == 0x37:
            operation = 'lui'
            result = signed(inst & 0xfffff000, 32) & MASK
        elif opcode == 0x17:
            operation = 'auipc'
            result = (pc + signed(inst & 0xfffff000, 32)) & MASK
            expected_a, expected_b = pc, signed(inst & 0xfffff000, 32) & MASK
        elif opcode in (0x13, 0x1b):
            imm = signed(inst >> 20, 12)
            expected_a, expected_b = a, imm & MASK
            if f3 == 0:
                operation, result = 'addi', a + imm
            elif opcode == 0x13 and f3 in (2, 3, 4, 6, 7):
                operation = {2: 'slti', 3: 'sltiu', 4: 'xori', 6: 'ori', 7: 'andi'}[f3]
                result = {2: int(signed(a, 64) < imm), 3: int(a < (imm & MASK)), 4: a ^ (imm & MASK), 6: a | (imm & MASK), 7: a & (imm & MASK)}[f3]
            elif f3 in (1, 5):
                width = 32 if opcode == 0x1b else 64
                amount = (inst >> 20) & (width - 1)
                expected_b, b_mask = amount, width - 1
                operand = a & ((1 << width) - 1)
                operation = 'shift-immediate'
                result = operand << amount if f3 == 1 else signed(operand, width) >> amount if inst & (1 << 30) else operand >> amount
            if result is not None:
                result = signed(result, 32) if opcode == 0x1b else result
                result &= MASK
        elif opcode in (0x33, 0x3b):
            expected_a, expected_b = a, b
            if f7 == 1 and f3 == 0:
                operation, result = 'mul', a * b
            elif f7 in (0, 0x20):
                operation = 'integer-register'
                width = 32 if opcode == 0x3b else 64
                x = a & ((1 << width) - 1)
                if f3 == 0:
                    result = a - b if f7 == 0x20 else a + b
                elif f3 == 4:
                    result = a ^ b
                elif f3 == 6:
                    result = a | b
                elif f3 == 7:
                    result = a & b
                elif f3 == 2:
                    result = int(signed(a, 64) < signed(b, 64))
                elif f3 == 3:
                    result = int(a < b)
                elif f3 in (1, 5):
                    result = x << (b & (width - 1)) if f3 == 1 else signed(x, width) >> (b & (width - 1)) if f7 == 0x20 else x >> (b & (width - 1))
            if result is not None:
                result = (signed(result, 32) if opcode == 0x3b else result) & MASK
        elif opcode == 0x03 and f3 != 7:
            operation = 'load'
            address = (a + signed(inst >> 20, 12)) & MASK
            size = 1 << (f3 & 3)
            load = (address, size)
            expected_a = a
            cells = [memory.get(address + i) for i in range(size)]
            if all(cell is not None and cell[1] == h for cell in cells):
                value = sum(cell[0] << (8 * i) for i, cell in enumerate(cells))
                result = (signed(value, size * 8) if f3 < 4 else value) & MASK
                counts['known_loads'] += 1
            else:
                result = retire['wdata']
                counts['unchecked_loads'] += 1
        elif opcode == 0x23 and f3 <= 3:
            operation = 'store'
            imm = signed(((inst >> 25) << 5) | ((inst >> 7) & 31), 12)
            store = ((a + imm) & MASK, 1 << f3, b)
            expected_a, expected_b = a, b
        elif opcode == 0x63:
            operation = 'branch'
            imm = signed(((inst >> 31) << 12) | (((inst >> 7) & 1) << 11) | (((inst >> 25) & 63) << 5) | (((inst >> 8) & 15) << 1), 13)
            conditions = {0: a == b, 1: a != b, 4: signed(a, 64) < signed(b, 64), 5: signed(a, 64) >= signed(b, 64), 6: a < b, 7: a >= b}
            if f3 not in conditions:
                operation = ''
            elif conditions[f3]:
                target = (pc + imm) & MASK
            expected_a, expected_b = a, b
        elif opcode == 0x6f:
            operation = 'jal'
            imm = signed(((inst >> 31) << 20) | (((inst >> 12) & 255) << 12) | (((inst >> 20) & 1) << 11) | (((inst >> 21) & 1023) << 1), 21)
            target, result = (pc + imm) & MASK, (pc + ilen) & MASK
        elif opcode == 0x67 and f3 == 0:
            operation = 'jalr'
            target, result = (a + signed(inst >> 20, 12)) & (MASK ^ 1), (pc + ilen) & MASK
            expected_a = a
        elif opcode == 0x0f:
            operation = 'fence'
        elif opcode == 0x73:
            if f3 and (inst >> 20) == 0xf14:
                operation, result = 'mhartid', h
            elif inst == 0x10500073:
                operation = 'wfi'
            elif f3:
                operation, result = 'unmodelled-csr', retire['wdata']
                skipped.append({'pc': hex(pc), 'bits': hex(inst), 'reason': 'CSR state not modelled'})
        if not operation or (opcode in (0x13, 0x1b, 0x33, 0x3b) and result is None):
            return {'status': 'unsupported', 'reason': 'instruction outside reference subset', 'issue': issue, 'retire': retire, 'counts': counts}
        related = linked.get(issue['gen'], [])
        active_alu = []
        for event in related:
            if event['kind'] == 'alu':
                strobes = execution.get((event['gen'], event['t']), [])
                if any((event['lane'] == 0 and (s['alu'] or s['branch'])) or (event['lane'] == 1 and s['alu2']) for s in strobes):
                    active_alu.append(event)
        operand_events = [e for e in related if e['kind'] == 'lsu-enqueue' and not e['flush']] if load or store else [e for e in related if e['kind'] == 'mult'] if operation == 'mul' else active_alu
        for event in operand_events:
            if expected_a is not None:
                counts['operand_checks'] += 1
                if event['a'] != expected_a:
                    return failure('execution-operand-a', issue, retire, expected_a, event['a'], event)
            if expected_b is not None and not load:
                counts['operand_checks'] += 1
                if event['b'] & b_mask != expected_b & b_mask:
                    return failure('execution-operand-b', issue, retire, expected_b & b_mask, event['b'] & b_mask, event)
            if load or store:
                address = load[0] if load else store[0]
                if event['vaddr'] != address:
                    return failure('LSU-effective-address', issue, retire, address, event['vaddr'], event)
        if expected_a is not None and operation not in ('unmodelled-csr',) and not operand_events:
            return {'status': 'unsupported', 'reason': 'missing execution boundary capture', 'issue': issue, 'retire': retire, 'counts': counts}
        if result is not None and opcode in (0x13, 0x1b, 0x33, 0x3b, 0x17, 0x37) and operation != 'mul':
            for event in active_alu:
                if event['value'] != result:
                    return failure('ALU-result', issue, retire, result, event['value'], event)
        if load:
            address, size = load
            requests = [e for e in related if e['kind'] == 'load-request']
            forwards = [e for e in related if e['kind'] == 'load-forward']
            if not requests and not forwards:
                return {'status': 'unsupported', 'reason': 'missing load acceptance capture', 'issue': issue, 'retire': retire, 'counts': counts}
            for event in requests + forwards:
                if event['vaddr'] != address:
                    return failure('load-acceptance-address', issue, retire, address, event['vaddr'], event)
            if all(not e['translated'] for e in operand_events):
                for event in [e for e in related if e['kind'] == 'load-tag' and e['tag_valid'] and not e['kill']]:
                    if event['tag'] != address >> index_bits:
                        return failure('load-tag-address', issue, retire, address >> index_bits, event['tag'], event)
            responses = [e for e in related if e['kind'] == 'load-response' and e['result_valid'] and not e['ex']]
            for event in responses:
                value = (event['raw'] >> (8 * (address & 7))) & ((1 << (8 * size)) - 1)
                expected_result = (signed(value, 8 * size) if f3 < 4 else value) & MASK
                if event['result'] != expected_result:
                    return failure('load-result-extraction', issue, retire, expected_result, event['result'], event)
                if event['result'] != result:
                    return failure('load-response-data', issue, retire, result, event['result'], event)
            for event in forwards:
                if event['value'] != result:
                    return failure('store-load-forward-data', issue, retire, result, event['value'], event)
        if store:
            address, size, value = store
            stores = [e for e in related if e['kind'] == 'store-enqueue' and not e['cancelled']]
            if not stores:
                return {'status': 'unsupported', 'reason': 'missing store acceptance capture', 'issue': issue, 'retire': retire, 'counts': counts}
            for event in stores:
                expected_data = (value << (8 * (address & 7))) & MASK
                be = ((1 << size) - 1) << (address & 7)
                mask = sum(255 << (8 * i) for i in range(8) if be & (1 << i))
                if event['paddr'] != address:
                    return failure('store-buffer-address', issue, retire, address, event['paddr'], event)
                if event['be'] != be or event['data'] & mask != expected_data & mask:
                    return failure('store-buffer-data', issue, retire, expected_data & mask, event['data'] & mask, event)
            for i in range(size):
                memory[address + i] = ((value >> (8 * i)) & 255, h)
            counts['stores'] += 1
        if result is not None and rd:
            if not retire['we'] or retire['waddr'] != rd or retire['whart'] != h:
                return failure('required-register-write', issue, retire, rd, retire['waddr'])
            if retire['wdata'] != result:
                return failure('load-result' if load else 'instruction-result', issue, retire, result, retire['wdata'])
            regs[h][rd] = result
        elif retire['we'] and retire['waddr']:
            return failure('unexpected-register-write', issue, retire, 0, retire['waddr'])
        next_pc[h] = target
        counts['retired'] += 1
    return {'status': 'pass', 'counts': counts, 'skipped': skipped, 'lastPcByHart': [hex(pc) if pc is not None else None for pc in next_pc]}


def image_words(path):
    return {int(a, 16): (int(b, 16), len(b) // 2) for a, b in re.findall(r'^\s*([0-9a-f]+):\s+([0-9a-f]{4}(?:[0-9a-f]{4})?)\s', path.read_text(), re.M)}


def main():
    root = Path(os.environ['OPERAND_RUN'])
    out = Path(os.environ['TH_OUT_DIR'])
    controls = json.loads(Path(os.environ.get('OPERAND_CONTROLS', str(root / 'controls.json'))).read_text())
    identity = json.loads((root / 'model.json').read_text())
    source_root = Path(identity.get('sourceRoot', str(root.parent / 'repo')))
    package = source_root / 'core/include/g6lc64_smt2_config_pkg.sv'
    sources = json.loads((root / 'sources.json').read_text())
    if hashlib.sha256(package.read_bytes()).hexdigest() != sources['core/include/g6lc64_smt2_config_pkg.sv']:
        raise ValueError('configuration provenance mismatch')
    text = package.read_text()
    size = int(re.search(r'localparam CVA6ConfigDcacheByteSize = (\d+);', text)[1])
    ways = int(re.search(r'localparam CVA6ConfigDcacheSetAssoc = (\d+);', text)[1])
    assert size % ways == 0 and (size // ways) & ((size // ways) - 1) == 0
    index_bits = (size // ways).bit_length() - 1
    if not controls.get('matched') or controls.get('sourceRun') != str(root):
        raise ValueError('observer controls are not validated')
    records = {r['tag']: r for r in json.loads((root / 'runs.json').read_text())}
    positive_path = root / 'observer-positive/operand-trace-0.log'
    witness_path = root / 'observer-on-0/operand-trace-0.log'
    for tag, path in [('observer-positive', positive_path), ('observer-on-0', witness_path)]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != records[tag]['traceSha256']:
            raise ValueError('trace provenance mismatch: ' + tag)
    positive_events = read_events(positive_path)
    positive = analyze(positive_events, image_words(root / 'positive.dis'), index_bits)
    (out / 'positive.json').write_text(json.dumps(positive, indent=2))
    if positive['status'] != 'pass':
        print(json.dumps(positive, indent=2))
        raise RuntimeError('reference checker failed its positive control; no attribution')
    mutated = copy.deepcopy(positive_events)
    mutation = next(e for e in mutated if e['kind'] == 'alu' and e['lane'] == 1)
    mutation['a'] ^= 1
    negative_control = analyze(mutated, image_words(root / 'positive.dis'), index_bits)
    if negative_control.get('contract') != 'execution-operand-a':
        raise RuntimeError('in-memory negative control was not detected')
    witness = analyze(read_events(witness_path), image_words(root / 'witness.dis'), index_bits)
    result = {'profile': 'RV64 integer subset, no architectural traps, identity-mapped stores; cross-hart memory reads not asserted against global commit order', 'positive': positive, 'negativeControl': {'inMemoryMutationOnly': True, 'detected': negative_control['contract']}, 'witness': witness, 'controls': controls, 'scriptSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (out / 'analysis.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
