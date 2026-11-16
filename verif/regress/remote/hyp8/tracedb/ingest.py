#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 trace database: ingest Verilator run logs into one SQLite file.

One pass over a run's model log turns every diagnostic record into a row with
categorical columns (run, core, hart, class, error type, origin), so a boot
can be compared, bucketed and joined instead of grepped. RVFI context around
selected events and a sampled PC profile are pulled from the (possibly very
large) per-core traces by bisecting on their cycle stamps -- never by a full
scan.

Layouts understood (all read-only):
  witness   <run>/output/run-hyp8.log, uart.txt, witness.json,
            trace_rvfi_hart_NN.dasm
  smokes    <run>/output/<test>.log (+ smokes-results.json)
  probe     <run>/output/<test>.log, <test>/trace_rvfi_hart_NN.dasm

Tables (see SCHEMA): run, etype, event, census, uart, rvfi, pc_sample, kv,
thread, symbol. Addresses are 16-digit hex TEXT (they exceed SQLite's signed
64-bit integers); cycles are INTEGER.

  ingest.py --db hyp8.sqlite [--runs-root /opt/testharness/runs]
            [--window 300] [--anchors 6] [--profile-step 5000000] [--force]
            TAG [TAG ...]
Under the testharness proxy (`py`): HYP8_TRACE_RUNS (space-separated tags or
globs), HYP8_TRACEDB (persistent path; a copy lands in TH_OUT_DIR).
"""
import argparse
import glob
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS run(
  id INTEGER PRIMARY KEY, tag TEXT, test TEXT, kind TEXT, rev TEXT,
  int_tag TEXT, model_sha TEXT, elf TEXT, argv TEXT, budget INTEGER,
  log_path TEXT, log_bytes INTEGER, log_mtime REAL, last_cycle INTEGER,
  cores INTEGER, harts INTEGER, verdict TEXT, ingested_utc TEXT,
  UNIQUE(tag, test));
CREATE TABLE IF NOT EXISTS etype(
  etype TEXT PRIMARY KEY, class TEXT, origin TEXT, rfix TEXT, descr TEXT);
CREATE TABLE IF NOT EXISTS event(
  id INTEGER PRIMARY KEY, run_id INTEGER, seq INTEGER, cycle INTEGER,
  cycle_exact INTEGER, core INTEGER, hart INTEGER, class TEXT, etype TEXT,
  addr TEXT, pc TEXT, aux TEXT, detail TEXT, raw TEXT);
CREATE INDEX IF NOT EXISTS event_run_class ON event(run_id, class, cycle);
CREATE INDEX IF NOT EXISTS event_run_cycle ON event(run_id, cycle);
CREATE TABLE IF NOT EXISTS census(
  run_id INTEGER, cycle INTEGER, hart INTEGER, kind TEXT, ret INTEGER,
  ipc REAL, flush_cyc INTEGER, lu_replay INTEGER, mem_viol INTEGER,
  ldbuf_full INTEGER, detail TEXT);
CREATE INDEX IF NOT EXISTS census_run ON census(run_id, hart, cycle);
CREATE TABLE IF NOT EXISTS uart(
  run_id INTEGER, line_no INTEGER, cycle INTEGER, ktime REAL, text TEXT);
CREATE TABLE IF NOT EXISTS rvfi(
  run_id INTEGER, anchor INTEGER, cycle INTEGER, core INTEGER, hart INTEGER,
  priv INTEGER, pc TEXT, insn TEXT, rd INTEGER, rd_val TEXT, mem_addr TEXT,
  mem_val TEXT);
CREATE INDEX IF NOT EXISTS rvfi_anchor ON rvfi(run_id, anchor, cycle);
CREATE TABLE IF NOT EXISTS pc_sample(
  run_id INTEGER, cycle INTEGER, core INTEGER, hart INTEGER, priv INTEGER,
  pc TEXT, region TEXT);
CREATE INDEX IF NOT EXISTS pc_sample_run ON pc_sample(run_id, cycle);
CREATE TABLE IF NOT EXISTS kv(
  run_id INTEGER, section TEXT, key TEXT, value TEXT);
CREATE TABLE IF NOT EXISTS thread(
  run_id INTEGER, core INTEGER, hart INTEGER, retired INTEGER, ipc REAL,
  last_cycle INTEGER, max_gap INTEGER, wfi INTEGER);
CREATE TABLE IF NOT EXISTS symbol(
  image TEXT, addr INTEGER, size INTEGER, name TEXT);
CREATE INDEX IF NOT EXISTS symbol_addr ON symbol(image, addr);
CREATE VIEW IF NOT EXISTS v_event AS
  SELECT r.tag, r.test, r.rev, e.*, t.origin, t.rfix
  FROM event e JOIN run r ON r.id = e.run_id
  LEFT JOIN etype t ON t.etype = e.etype;
"""

# SoC physical map (corev_apu/tb/g6lc_soc_pkg.sv): name, base, length
SOC_MAP = [
    ('debug', 0x0, 0x1000), ('rom', 0x10000, 0x10000),
    ('clint', 0x2000000, 0xC0000), ('plic', 0xC000000, 0x4000000),
    ('uart', 0x10000000, 0x1000), ('timer', 0x18000000, 0x1000),
    ('spi', 0x20000000, 0x800000), ('eth', 0x30000000, 0x10000),
    ('gpio', 0x40000000, 0x1000), ('dram', 0x80000000, 0x40000000),
]

# error type -> (origin, rfix entry, description); matched by longest prefix
ETYPES = {
    'axi.r.va-alias': ('stale-context', 'RFIX-131a-01/02',
                       'bus read of a truncated virtual address (load issued bare under MPRV)'),
    'axi.r.hole': ('wrong-path', 'RFIX-131a-01', 'bus read nothing decodes'),
    'axi.r.dev': ('wrong-path', 'RFIX-131a-01', 'bus error from a device window'),
    'axi.r.untagged': ('unknown', 'RFIX-131a-01', 'bus read error, harness without address tag'),
    'axi.b': ('unknown', '', 'bus write error'),
    'ptw.fetch.phys-alias': ('stale-context', 'RFIX-131a-02',
                             'fetch of an M-mode address walked under satp (xRET window)'),
    'ptw.data.phys-alias': ('stale-context', 'RFIX-131a-02',
                            'physical address walked under a stale MPRV context'),
    'ptw.data.null': ('wrong-path', 'RFIX-131a-03', 'wrong-path load, null/garbage base'),
    'ptw.fetch.null': ('wrong-path', 'RFIX-131a-04', 'wrong-path fetch, null target'),
    'ptw.data.user': ('architectural?', '', 'user data walk fault (demand paging or wrong path)'),
    'ptw.fetch.user': ('architectural?', '', 'user fetch walk fault (demand paging or wrong path)'),
    'ptw.data.kernel': ('unknown', '', 'kernel data walk fault'),
    'ptw.fetch.kernel': ('unknown', 'RFIX-131a-04', 'kernel fetch walk fault'),
    'ptw.data.noncanonical': ('wrong-path', 'RFIX-131a-03', 'data walk of a non-canonical address'),
    'ptw.fetch.noncanonical': ('wrong-path', 'RFIX-131a-04', 'fetch walk of a non-canonical address'),
    'ife.priv0': ('architectural?', '', 'instruction fault presented in U-mode'),
    'ife.priv1': ('wrong-path', 'RFIX-131a-04', 'instruction fault presented in S-mode'),
    'ife.priv3': ('wrong-path', 'RFIX-131a-04', 'instruction fault presented in M-mode'),
    'hang': ('liveness', 'RFIX-131a-05', 'commit gap over the +hang_dump threshold'),
    'idle.wfi': ('idle', '', 'commit gap with WFI at the head: the hart sleeps (not an error)'),
    'seqgap': ('liveness', '', 'fetch sequence gap over +seq_gap_limit'),
    'assert': ('model-assert', '', 'RTL assertion ($error/$fatal) stopped or flagged the model'),
    'tlb': ('trace', '', '+tlb_trace record'),
    'wbuf.drop': ('diagnostic', '', 'write-buffer obligation dropped by other than a plain drop'),
    'verdict': ('verdict', '', 'harness end-of-test line'),
    'warn': ('unknown', '', 'unclassified stamped warning'),
}

RE_STAMP = re.compile(rb'^\[(\d+)\] ')
RE_KV = re.compile(r'([A-Za-z_][A-Za-z0-9_\[\]\.\-]*)=([^\s|,()]+)')
RE_SCOPE_CORE = re.compile(r'gen_core\[(\d+)\]')
RE_KTIME = re.compile(r'^\[\s*(\d+\.\d+)\]')
RE_RVFI_HEAD = re.compile(rb'^core\s+(\d+): 0x([0-9a-f]+) \(0x([0-9a-f]+)\).*?(?:@(\d+))?\s*$')
RE_RVFI_TAIL = re.compile(rb'^(\d) 0x[0-9a-f]+ \(0x[0-9a-f]+\)(?: x\s*(\d+) 0x([0-9a-f]+))?'
                          rb'(?: mem 0x([0-9a-f]+)(?: 0x([0-9a-f]+))?)?')
RE_RVFI_CYC = re.compile(rb'@(\d+)\s*$')


def hx(v):
    return f'{int(v, 16):016x}'


def soc_region(a):
    if a >> 40:
        return 'va-alias'
    for name, base, ln in SOC_MAP:
        if base <= a < base + ln:
            return name
    return 'hole'


def va_class(a):
    if 0x80000000 <= a < 0xC0000000:
        return 'phys-alias'
    if a < 0x1000:
        return 'null'
    if a < (1 << 38):
        return 'user'
    if a >= 0xFFFFFFC000000000:
        return 'kernel'
    return 'noncanonical'


def pc_region(a):
    if a < 0x80000000:
        return 'rom' if 0x10000 <= a < 0x20000 else 'low'
    if a < 0x80200000:
        return 'firmware'
    if a < 0xC0000000:
        return 'payload-phys'
    if a >= 0xFFFFFFFF80000000:
        return 'kernel'
    if a >= 0xFFFFFFC000000000:
        return 'kernel-vm'
    return 'user'


def etype_of(e):
    best = None
    for k in ETYPES:
        if e.startswith(k) and (best is None or len(k) > len(best)):
            best = k
    return best


class Run:
    def __init__(self, tag, test, kind, log, meta):
        self.tag, self.test, self.kind, self.log = tag, test, kind, Path(log)
        self.meta = meta
        self.rows, self.census, self.kvs, self.uart = [], [], [], []
        self.seq = 0
        self.cycle = 0
        self.counts = {}
        self.threads = {}
        self.verdict = None

    def ev(self, cls, etype, exact=True, core=None, hart=None, addr=None, pc=None,
           aux=None, detail=None, raw=''):
        self.seq += 1
        self.rows.append((self.seq, self.cycle, int(exact), core, hart, cls, etype, addr, pc,
                          aux, json.dumps(detail) if detail else None, raw[:400]))


def parse_log(run):
    """Single pass over the model log."""
    hang = None       # open [hang] dump: [cycle, lines]
    ubuf = bytearray()   # UART line being assembled from "[uart] <char>" records
    ucyc = 0
    n_wb = n_boot = n_other = 0

    def uart_line(raw, cyc):
        t = raw.decode('utf-8', 'replace').strip()
        if t:
            m = RE_KTIME.match(t)
            run.uart.append((len(run.uart) + 1, cyc, float(m.group(1)) if m else None, t))

    def hang_close():
        nonlocal hang
        if not hang:
            return
        cyc, lines = hang
        d = {}
        for ln in lines:
            for part in ln.split(' | '):
                mk = RE_KV.search(part)
                label = (part[:mk.start()].strip() if mk else part.strip()) or 'top'
                d.setdefault(label, {}).update(dict(RE_KV.findall(part)))
        head = d.get('SB head', {})
        lu = d.get('LU req:', {})
        top = d.get('top', {})
        run.cycle = cyc
        # fu 6 / op 27 is WFI at the commit head: the hart is idle, not stuck
        idle = head.get('fu') == '6' and head.get('op') == '27'
        run.ev('hang', 'idle.wfi' if idle else f"hang.fu{head.get('fu', '?')}.op{head.get('op', '?')}",
               pc=hx(head['pc']) if 'pc' in head else None,
               addr=hx(lu['vaddr']) if 'vaddr' in lu else None,
               aux=f"since_ack={top.get('since_ack')} lsu_ready={top.get('lsu_ready')} "
                   f"lsu_cnt={d.get('LSU bypass', {}).get('cnt')}",
               detail=d, raw=lines[0])
        hang = None

    with run.log.open('rb') as f:
        for line in f:
            # fast paths: the two volume classes
            if line.startswith(b'[l1 dcache'):
                n_wb += 1
                if b'plain drop' not in line:
                    run.ev('wbuf', 'wbuf.drop', exact=False, raw=line.decode('utf-8', 'replace'))
                continue
            if line.startswith(b'[boot]'):
                n_boot += 1
                continue
            i = line.find(b'[l1 dcache wbuffer]')
            if i > 0:             # a raw UART character glued in front of a record
                n_wb += 1
                continue
            m = RE_STAMP.match(line)
            s = line.decode('utf-8', 'replace').rstrip('\n')
            if not s.startswith('[hang]'):
                hang_close()
            if m:                 # [cycle] %Warning / %Error
                run.cycle = int(m.group(1))
                body = s[m.end():]
                if 'Response Errored' in body:
                    kv = dict(RE_KV.findall(body))
                    ch = 'r' if 'R Response' in body else 'b'
                    if 'addr' in kv:
                        a = int(kv['addr'], 16)
                        reg = soc_region(a)
                        sub = reg if reg in ('va-alias', 'hole') else f'dev.{reg}'
                        run.ev('axi', f'axi.{ch}.{sub}', addr=hx(kv['addr']),
                               aux=f"resp={kv.get('resp')} id={kv.get('id')}", raw=s)
                    else:
                        run.ev('axi', f'axi.{ch}.untagged', raw=s)
                elif '%Error' in body or '%Fatal' in body:
                    mm = re.search(r'%(?:Error|Fatal): ([\w\.]+):(\d+): Assertion failed in (\S+): (.*)', body)
                    if mm:
                        c = RE_SCOPE_CORE.search(mm.group(3))
                        run.ev('assert', f'assert.{mm.group(1)}:{mm.group(2)}',
                               core=int(c.group(1)) if c else None,
                               aux=mm.group(3).rsplit('.', 1)[-1],
                               detail={'scope': mm.group(3), 'msg': mm.group(4)}, raw=s)
                    else:
                        run.ev('assert', 'assert.other', raw=s)
                else:
                    run.ev('warn', 'warn.other', raw=s)
                continue
            if s.startswith('[ptw-err]'):
                kv = dict(RE_KV.findall(s))
                run.cycle = int(kv.get('t', run.cycle))
                a = int(kv['vaddr'], 16)
                kind = 'fetch' if kv.get('instr') == '1' else 'data'
                run.ev('ptw', f'ptw.{kind}.{va_class(a)}', hart=int(kv.get('hart', 0)),
                       addr=hx(kv['vaddr']), aux=f"lvl={kv.get('lvl')} satp={kv.get('satp_ppn')}", raw=s)
            elif s.startswith('[mmu-ife]'):
                kv = dict(RE_KV.findall(s))
                run.cycle = int(kv.get('t', run.cycle))
                run.ev('ife', f"ife.priv{kv.get('priv')}.cause{kv.get('cause')}",
                       hart=int(kv.get('fetch_hart', 0)), addr=hx(kv['fetch_va']),
                       aux=f"itlb_hit={kv.get('itlb_hit')} ptw_err={kv.get('ptw_err')} "
                           f"ptw_act={kv.get('ptw_act')} walk_instr={kv.get('walk_instr')}", raw=s)
            elif s.startswith('[hang]'):
                if s.startswith('[hang] cyc='):
                    hang_close()
                    hang = [int(RE_KV.search(s).group(2)), [s[7:]]]
                elif hang:
                    hang[1].append(s[7:])
            elif s.startswith('[stall-census]'):
                kv = dict(RE_KV.findall(s))
                cyc = int(kv.get('cyc', run.cycle))
                run.cycle = cyc
                kind = s.split()[1]
                if ' mem: ' in s:
                    if run.census and run.census[-1][0] == cyc:
                        c = run.census[-1]
                        run.census[-1] = c[:5] + (int(kv.get('flush_cyc', 0)), int(kv.get('lu_replay', 0)),
                                                  int(kv.get('mem_viol', 0)), int(kv.get('ldbuf_full', 0)),
                                                  c[9])
                else:
                    hart = int(kv.get('hart', 0))
                    run.census.append((cyc, hart, kind, int(kv.get('ret', 0)), float(kv.get('ipc', 0)),
                                       None, None, None, None, s[:1500]))
                    t = run.threads.setdefault((None, hart), {})
                    t.update(retired=int(kv.get('ret', 0)), ipc=float(kv.get('ipc', 0)), last_cycle=cyc)
            elif s.startswith('[seq-gap]'):
                kv = dict(RE_KV.findall(s))
                run.cycle = int(kv.get('t', run.cycle))
                run.ev('seqgap', 'seqgap', addr=hx(kv['front']) if 'front' in kv else None,
                       pc=hx(kv['redpc']) if 'redpc' in kv else None, aux=f"src={kv.get('src')}", raw=s)
            elif s.startswith('[tlb]'):
                kv = dict(RE_KV.findall(s))
                mk = re.search(r' c=\d+ (\w+)', s)
                c = RE_SCOPE_CORE.search(s)
                run.ev('tlb', f"tlb.{mk.group(1) if mk else '?'}", exact=False,
                       core=int(c.group(1)) if c else None,
                       addr=kv.get('vpn') or kv.get('va'), aux=f"c={kv.get('c')}",
                       detail=kv, raw=s)
            elif s.startswith('[equiv]') or s.startswith('*** [mc_') or s.startswith('[lsq-ev-miss]'):
                sec = s.split(']')[0].strip('*[ ')
                name = s.split(']', 1)[1].strip()
                for k, v in RE_KV.findall(name):
                    run.kvs.append((sec, f"{name.split(':')[0].strip()[:60]}:{k}" if sec == 'equiv' else k, v))
                mg = re.search(r'core (\d+) max retirement gap (\d+) cycles \(limit \d+, wfi=(\d+)\)', s)
                if mg:
                    t = run.threads.setdefault((int(mg.group(1)), None), {})
                    t.update(max_gap=int(mg.group(2)), wfi=int(mg.group(3)))
                if 'mc_verdict' in s:
                    run.ev('verdict', 'verdict.mc', exact=False, aux=name[:120], raw=s)
            elif '*** SUCCESS ***' in s or '*** FAILED ***' in s:
                mv = re.search(r'\*\*\* (SUCCESS|FAILED) \*\*\* \(tohost = (\S+)\) after (\d+) cycles(.*)', s)
                if mv:
                    budget_out = 'budget' in mv.group(4)
                    run.verdict = ('wedged' if budget_out else
                                   ('pass' if mv.group(1) == 'SUCCESS' else f'fail(tohost={mv.group(2)})'))
                    run.cycle = int(mv.group(3))
                    run.ev('verdict', 'verdict.tohost', aux=run.verdict, raw=s)
            elif line.startswith(b'[uart] ') and b'uart_bytes=' not in line:
                ch = line[7:-1]
                if ch in (b'', bytes([13])):
                    if ubuf:
                        uart_line(bytes(ubuf), ucyc)
                        ubuf = bytearray()
                else:
                    if not ubuf:
                        ucyc = run.cycle
                    ubuf += ch
            elif s.startswith('[uart'):
                n_other += 1
            else:
                n_other += 1
        hang_close()
        if ubuf:
            uart_line(bytes(ubuf), ucyc)
    run.counts = {'wbuffer_dropped': n_wb, 'boot_lines': n_boot, 'unclassified_lines': n_other}


# ------------------------------- RVFI ------------------------------------
def rvfi_bisect(path, target):
    size = os.path.getsize(path)
    a, b = 0, size
    with open(path, 'rb') as f:
        while b - a > 1 << 15:
            mid = (a + b) // 2
            f.seek(mid)
            f.readline()
            stamp = None
            for _ in range(200):
                ln = f.readline()
                if not ln:
                    break
                m = RE_RVFI_CYC.search(ln)
                if m:
                    stamp = int(m.group(1))
                    break
            if stamp is None or stamp >= target:
                b = mid
            else:
                a = mid
    return a


def rvfi_read(path, lo, hi, cap, core):
    """Retired instructions stamped in [lo, hi] (at most cap rows)."""
    out = []
    try:
        off = rvfi_bisect(path, lo)
    except OSError:
        return out
    with open(path, 'rb') as f:
        f.seek(off)
        f.readline()
        cur = None
        for ln in f:
            m = RE_RVFI_HEAD.match(ln)
            if m:
                if cur and lo <= cur[0] <= hi:
                    out.append(tuple(cur))
                    if len(out) >= cap:
                        return out
                if m.group(4) is None:
                    cur = None
                    continue
                cyc = int(m.group(4))
                if cyc > hi:
                    return out
                cur = [cyc, core, int(m.group(1)), None, hx(m.group(2).decode()),
                       m.group(3).decode(), None, None, None, None]
            elif cur:
                t = RE_RVFI_TAIL.match(ln)
                if t:
                    cur[3] = int(t.group(1))
                    if t.group(2):
                        cur[6] = int(t.group(2))
                        cur[7] = hx(t.group(3).decode())
                    if t.group(4):
                        cur[8] = hx(t.group(4).decode())
                        cur[9] = hx(t.group(5).decode()) if t.group(5) else None
        if cur and lo <= cur[0] <= hi:
            out.append(tuple(cur))
    return out


def rvfi_files(run_out, test):
    for base in (run_out / test, run_out):
        fs = sorted(base.glob('trace_rvfi_hart_*.dasm'))
        if fs:
            return [(int(re.search(r'hart_(\d+)', p.name).group(1)), p) for p in fs]
    return []


def pick_anchors(db, run_id, per_type):
    """Events worth RVFI context: every assert/hang/verdict, and the first
    `per_type` plus the last of every other error type."""
    rows = db.execute("SELECT id, cycle, class, etype FROM event WHERE run_id=? AND cycle_exact=1 "
                      "AND class NOT IN ('tlb','warn') ORDER BY cycle", (run_id,)).fetchall()
    by = {}
    for r in rows:
        by.setdefault(r[3], []).append(r)
    out = []
    for lst in by.values():
        if lst[0][2] in ('assert', 'verdict') or lst[0][3].startswith('hang.'):
            out += lst[:64]
        else:
            out += lst[:per_type] + lst[-1:]
    return sorted(set(out), key=lambda r: r[1])


def ingest_run(db, tag, test, kind, log, out_dir, meta, args):
    st = log.stat()
    row = db.execute('SELECT id, log_bytes, log_mtime FROM run WHERE tag=? AND test=?', (tag, test)).fetchone()
    if row and row[1] == st.st_size and row[2] == st.st_mtime and not args.force:
        print(f'  = {tag}/{test}: unchanged')
        return
    if row:
        for t in ('event', 'census', 'uart', 'rvfi', 'pc_sample', 'kv', 'thread'):
            db.execute(f'DELETE FROM {t} WHERE run_id=?', (row[0],))
        db.execute('DELETE FROM run WHERE id=?', (row[0],))
    t0 = time.time()
    run = Run(tag, test, kind, log, meta)
    parse_log(run)
    rev = re.search(r'(rfix\d+[a-z]*|r\d+[a-z0-9]*)', tag)
    cur = db.execute(
        'INSERT INTO run(tag,test,kind,rev,int_tag,model_sha,elf,argv,budget,log_path,log_bytes,log_mtime,'
        'last_cycle,verdict,ingested_utc) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
        (tag, test, kind, rev.group(1) if rev else None, meta.get('intTag'), meta.get('modelSha256'),
         meta.get('elf'), json.dumps(meta.get('argv')), int(meta.get('budget') or 0), str(log),
         st.st_size, st.st_mtime, run.cycle, run.verdict,
         time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())))
    rid = cur.lastrowid
    db.executemany('INSERT INTO event(run_id,seq,cycle,cycle_exact,core,hart,class,etype,addr,pc,aux,detail,raw)'
                   ' VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)', [(rid,) + r for r in run.rows])
    db.executemany('INSERT INTO census VALUES(?,?,?,?,?,?,?,?,?,?,?)', [(rid,) + c for c in run.census])
    db.executemany('INSERT INTO kv VALUES(?,?,?,?)',
                   [(rid, s, k, v) for s, k, v in run.kvs] +
                   [(rid, 'count', k, str(v)) for k, v in run.counts.items()])
    # UART text comes from the model log (cycle-attributed); uart.txt only
    # decides the boot verdict
    uart_txt = out_dir / 'uart.txt'
    if uart_txt.is_file() and kind == 'witness':
        if not run.uart:
            for t in (l.strip() for l in uart_txt.read_text(errors='replace').splitlines()):
                if t:
                    m = RE_KTIME.match(t)
                    run.uart.append((len(run.uart) + 1, None, float(m.group(1)) if m else None, t))
        if any('G6LC_LINUX_SHELL' in u[3] for u in run.uart):
            run.verdict = 'shell'
        elif any('Kernel panic' in u[3] or 'Oops' in u[3] for u in run.uart):
            run.verdict = 'kernel-error'
        elif run.verdict is None:
            run.verdict = 'no-shell'
        db.execute('UPDATE run SET verdict=? WHERE id=?', (run.verdict, rid))
    db.executemany('INSERT INTO uart VALUES(?,?,?,?,?)', [(rid,) + u for u in run.uart])
    files = rvfi_files(out_dir, test)
    harts = sorted({h for (_, h) in run.threads if h is not None}) or [0]
    for (core, hart), t in sorted(run.threads.items(), key=lambda kv: str(kv[0])):
        db.execute('INSERT INTO thread VALUES(?,?,?,?,?,?,?,?)',
                   (rid, core, hart, t.get('retired'), t.get('ipc'), t.get('last_cycle'),
                    t.get('max_gap'), t.get('wfi')))
    db.execute('UPDATE run SET cores=?, harts=? WHERE id=?', (max(1, len(files)), len(harts), rid))
    # RVFI context around the anchors
    n_rv = 0
    if files and args.window:
        for (eid, cyc, cls, _et) in pick_anchors(db, rid, args.anchors):
            back = args.window
            if cls == 'hang':     # the last retirement is `since_ack` cycles back
                aux = db.execute('SELECT aux FROM event WHERE id=?', (eid,)).fetchone()[0] or ''
                ms = re.search(r'since_ack=(\d+)', aux)
                back += int(ms.group(1)) if ms else 2000
            for base_hart, p in files:
                rows = rvfi_read(p, max(0, cyc - back), cyc + args.window // 4, 400, base_hart)
                db.executemany('INSERT INTO rvfi VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                               [(rid, eid) + r for r in rows])
                n_rv += len(rows)
    # sampled PC profile
    n_pc = 0
    if files and args.profile_step and run.cycle > 4 * args.profile_step:
        for base_hart, p in files:
            c = 0
            while c < run.cycle:
                for r in rvfi_read(p, c, c + 4000, 48, base_hart):
                    db.execute('INSERT INTO pc_sample VALUES(?,?,?,?,?,?,?)',
                               (rid, r[0], r[1], r[2], r[3], r[4], pc_region(int(r[4], 16))))
                    n_pc += 1
                c += args.profile_step
    db.commit()
    print(f'  + {tag}/{test}: {len(run.rows)} events, {len(run.census)} census, {len(run.uart)} uart, '
          f'{n_rv} rvfi, {n_pc} pc samples, last_cycle={run.cycle}, verdict={run.verdict} '
          f'[{time.time() - t0:.0f}s]', flush=True)


def load_symbols(db, elf):
    p = Path(elf)
    image = p.name
    for part in p.parts:
        if part.startswith('build-'):
            image = f'{part}/{p.name}'
    if db.execute('SELECT 1 FROM symbol WHERE image=? LIMIT 1', (image,)).fetchone():
        return
    nm = sorted(glob.glob('/opt/testharness/toolchains/xpack-riscv-none-elf-gcc-*/bin/riscv-none-elf-nm'))
    if not nm or not p.is_file():
        return
    out = subprocess.run([nm[-1], '-n', '-S', '--defined-only', str(p)], capture_output=True, text=True).stdout
    rows = []
    for ln in out.splitlines():
        f = ln.split()
        if len(f) == 4 and f[2] in 'tTwW':
            rows.append((image, int(f[0], 16), int(f[1], 16), f[3]))
        elif len(f) == 3 and f[1] in 'tTwW':
            rows.append((image, int(f[0], 16), 0, f[2]))
    db.executemany('INSERT INTO symbol VALUES(?,?,?,?)', rows)
    db.commit()
    print(f'  symbols: {len(rows)} from {image}')


def discover(root, tag):
    """(test, kind, log, meta) for every model log of a run directory."""
    out = root / tag / 'output'
    found = []
    wit = out / 'run-hyp8.log'
    if wit.is_file():
        meta = {}
        if (out / 'witness.json').is_file():
            meta = json.loads((out / 'witness.json').read_text())
        found.append(('boot', 'witness', wit, meta))
        return out, found
    for name, kind in (('smokes-results.json', 'smoke'), ('probe-results.json', 'probe')):
        if (out / name).is_file():
            res = json.loads((out / name).read_text())
            for test, e in res.get('tests', {}).items():
                log = out / f'{test}.log'
                if log.is_file():
                    found.append((test, kind, log,
                                  {'intTag': res.get('intTag'), 'modelSha256': res.get('modelSha256'),
                                   'argv': e.get('argv'), 'elf': (e.get('argv') or [None])[-1]}))
    return out, found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=os.environ.get('HYP8_TRACEDB', 'hyp8-trace.sqlite'))
    ap.add_argument('--runs-root', default='/opt/testharness/runs')
    ap.add_argument('--window', type=int, default=int(os.environ.get('HYP8_TRACE_WINDOW', '300')),
                    help='RVFI cycles kept before an anchor (a quarter of it after)')
    ap.add_argument('--anchors', type=int, default=6,
                    help='first N events of each error type get RVFI context')
    ap.add_argument('--profile-step', type=int, default=5000000)
    ap.add_argument('--force', action='store_true')
    ap.add_argument('tags', nargs='*', default=os.environ.get('HYP8_TRACE_RUNS', '').split())
    args = ap.parse_args()
    root = Path(args.runs_root)
    Path(args.db).parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(args.db)
    db.executescript(SCHEMA)
    db.execute('DELETE FROM etype')
    db.executemany('INSERT INTO etype VALUES(?,?,?,?,?)',
                   [(k, k.split('.')[0], v[0], v[1], v[2]) for k, v in ETYPES.items()])
    tags = []
    for t in args.tags:
        tags += sorted(p.name for p in root.glob(t)) if any(c in t for c in '*?[') else [t]
    for tag in tags:
        out, found = discover(root, tag)
        if not found:
            print(f'  ! {tag}: no model log')
            continue
        for test, kind, log, meta in found:
            ingest_run(db, tag, test, kind, log, out, meta, args)
            if meta.get('elf') and kind == 'witness':
                load_symbols(db, meta['elf'])
    # register every observed error type under its longest known prefix
    for (e,) in db.execute('SELECT DISTINCT etype FROM event').fetchall():
        k = etype_of(e)
        if k and not db.execute('SELECT 1 FROM etype WHERE etype=?', (e,)).fetchone():
            v = ETYPES[k]
            db.execute('INSERT INTO etype VALUES(?,?,?,?,?)', (e, e.split('.')[0], v[0], v[1], v[2]))
    db.commit()
    db.close()
    th_out = os.environ.get('TH_OUT_DIR')
    if th_out and Path(th_out).resolve() != Path(args.db).parent.resolve():
        shutil.copy2(args.db, Path(th_out) / Path(args.db).name)
    print('db:', args.db, os.path.getsize(args.db), 'bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
