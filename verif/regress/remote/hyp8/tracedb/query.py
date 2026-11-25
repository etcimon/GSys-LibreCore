#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""hyp8 trace database: analytics over the SQLite file built by ingest.py.

  query.py [--db hyp8-trace.sqlite] REPORT [options]

Reports
  runs                      one line per ingested run
  classes  [-r TAG ...]     error types x runs (count, origin, rfix entry)
  origins  [-r TAG ...]     events by origin (wrong-path / stale-context / ...)
  timeline -r TAG [-b N]    events per N-cycle bucket by class, with IPC,
                            memory replays and the UART phase
  top      -r TAG -e PFX    most frequent addresses / PCs of an error type
  around   -r TAG -e PFX [-n K]   retired instructions before the first K
                            events of an error type (symbolized)
  asserts                   every model assertion, with its last instructions
  hangs    [-r TAG]         commit-gap dumps grouped by head instruction
  buckets  [-r TAG ...]     event_analysis counts by bucket and evidence
  primary  [-r TAG ...]     grouped primary-candidate events from event_analysis
  threads  [-r TAG]         per core / hart: retired, IPC, gap, events
  uart     -r TAG           boot phases: cycle, kernel time, text
  profile  -r TAG [-b N]    where the sampled PCs are (region x privilege)
  diff     A B              error types of two runs over their common cycles
  sql      "SELECT ..."     anything else (or `sql -f query.sql`)

Under the testharness proxy: HYP8_TRACEDB and HYP8_TRACE_QUERY (the argument
string), output to stdout and TH_OUT_DIR/query.txt.
"""
import argparse
import json
import os
import shlex
import sqlite3
import sys


def table(rows, head):
    rows = [[('' if v is None else str(v)) for v in r] for r in rows]
    w = [max(len(h), *(len(r[i]) for r in rows)) if rows else len(h) for i, h in enumerate(head)]
    out = ['  '.join(h.ljust(w[i]) for i, h in enumerate(head)),
           '  '.join('-' * w[i] for i in range(len(head)))]
    out += ['  '.join(c.ljust(w[i]) for i, c in enumerate(r)) for r in rows]
    return '\n'.join(out)


class Q:
    def __init__(self, path):
        self.db = sqlite3.connect(path)
        self._sym = None

    def run_ids(self, tags):
        if not tags:
            return [r[0] for r in self.db.execute('SELECT id FROM run ORDER BY rev, tag, test')]
        ids = []
        for t in tags:
            tag, _, test = t.partition('/')
            q = 'SELECT id FROM run WHERE (tag=? OR tag LIKE ? OR rev=?)' + (' AND test=?' if test else '')
            a = [tag, f'%{tag}%', tag] + ([test] if test else [])
            ids += [r[0] for r in self.db.execute(q + ' ORDER BY tag, test', a)]
        if not ids:
            sys.exit(f'no run matches {tags}')
        return list(dict.fromkeys(ids))

    def name(self, rid):
        tag, test, kind = self.db.execute('SELECT tag, test, kind FROM run WHERE id=?', (rid,)).fetchone()
        short = tag.replace('hyp8-osbi-scalar-', '').replace('hyp8-', '')
        return short if kind == 'witness' else f'{short}/{test}'

    def kind(self, rid):
        r = self.db.execute('SELECT kind FROM run WHERE id=?', (rid,)).fetchone()
        return r[0] if r else ''

    def sym(self, pc, rid=None):
        """firmware symbol+offset of a hex PC (OpenSBI symbols apply to witness boots only)."""
        if pc is None:
            return ''
        if rid is not None and self.kind(rid) != 'witness':
            return ''
        a = int(pc, 16)
        if not 0x80000000 <= a < 0x80200000:
            return ''
        r = self.db.execute('SELECT name, addr FROM symbol WHERE addr<=? ORDER BY addr DESC LIMIT 1',
                            (a,)).fetchone()
        return f'{r[0]}+0x{a - r[1]:x}' if r else ''

    # ------------------------------------------------------------------
    def runs(self, a):
        rows = self.db.execute(
            "SELECT r.rev, r.tag, r.test, r.kind, r.verdict, r.last_cycle, r.cores, r.harts, "
            "(SELECT COUNT(*) FROM event e WHERE e.run_id=r.id AND e.class NOT IN ('verdict','tlb','wbuf')), "
            "(SELECT COUNT(*) FROM event e WHERE e.run_id=r.id AND e.class='assert'), "
            "ROUND(r.log_bytes/1048576.0,1) FROM run r ORDER BY r.rev, r.tag, r.test").fetchall()
        return table(rows, ['rev', 'tag', 'test', 'kind', 'verdict', 'last_cycle', 'cores', 'harts',
                            'events', 'asserts', 'log_MiB'])

    def classes(self, a):
        ids = self.run_ids(a.run)
        ets = self.db.execute(
            f"SELECT e.etype, COUNT(*) FROM event e WHERE e.run_id IN ({','.join('?' * len(ids))}) "
            "AND e.class NOT IN ('verdict','tlb') GROUP BY e.etype ORDER BY e.class, 2 DESC", ids).fetchall()
        rows = []
        for et, _ in ets:
            meta = self.db.execute('SELECT origin, rfix FROM etype WHERE etype=?', (et,)).fetchone() or ('', '')
            cnt = [self.db.execute('SELECT COUNT(*) FROM event WHERE run_id=? AND etype=?', (i, et)).fetchone()[0]
                   for i in ids]
            rows.append([et, meta[0], meta[1]] + [c or '' for c in cnt])
        return table(rows, ['etype', 'origin', 'rfix'] + [self.name(i) for i in ids])

    def origins(self, a):
        ids = self.run_ids(a.run)
        rows = []
        for (o,) in self.db.execute('SELECT DISTINCT origin FROM etype ORDER BY 1'):
            cnt = [self.db.execute(
                "SELECT COUNT(*) FROM event e JOIN etype t ON t.etype=e.etype WHERE e.run_id=? AND t.origin=?",
                (i, o)).fetchone()[0] for i in ids]
            if any(cnt):
                rows.append([o] + [c or '' for c in cnt])
        return table(rows, ['origin'] + [self.name(i) for i in ids])

    def timeline(self, a):
        rid = self.run_ids(a.run)[0]
        b = a.bucket
        cls = [r[0] for r in self.db.execute(
            "SELECT DISTINCT class FROM event WHERE run_id=? AND class NOT IN ('verdict','tlb','wbuf') "
            "ORDER BY 1", (rid,))]
        last = self.db.execute('SELECT last_cycle FROM run WHERE id=?', (rid,)).fetchone()[0] or 0
        rows = []
        prev = (0, 0, 0)
        for k in range(0, last // b + 1):
            lo, hi = k * b, (k + 1) * b
            cnt = [self.db.execute('SELECT COUNT(*) FROM event WHERE run_id=? AND class=? AND cycle>=? AND cycle<?',
                                   (rid, c, lo, hi)).fetchone()[0] for c in cls]
            cen = self.db.execute('SELECT ret, mem_viol, lu_replay FROM census WHERE run_id=? AND cycle<=? '
                                  'AND mem_viol IS NOT NULL ORDER BY cycle DESC LIMIT 1', (rid, hi)).fetchone()
            ipc = viol = ''
            if cen:
                ipc = f'{(cen[0] - prev[0]) / b:.3f}'
                viol = cen[1] - prev[1]
                prev = cen
            u = self.db.execute('SELECT text FROM uart WHERE run_id=? AND cycle>=? AND cycle<? '
                                'ORDER BY line_no DESC LIMIT 1', (rid, lo, hi)).fetchone()
            rows.append([f'{lo // 1000000}M'] + [c or '' for c in cnt] + [ipc, viol, (u[0][:56] if u else '')])
        return table(rows, ['from'] + cls + ['ipc', 'mem_viol', 'last uart line'])

    def top(self, a):
        rid = self.run_ids(a.run)[0]
        out = []
        for col in ('addr', 'pc', 'aux'):
            rows = self.db.execute(
                f"SELECT {col}, COUNT(*), MIN(cycle), MAX(cycle), GROUP_CONCAT(DISTINCT etype) FROM event "
                f"WHERE run_id=? AND etype LIKE ? AND {col} IS NOT NULL GROUP BY {col} ORDER BY 2 DESC LIMIT ?",
                (rid, a.etype + '%', a.n)).fetchall()
            if rows:
                rows = [list(r) + [self.sym(r[0], rid) if col != 'aux' else ''] for r in rows]
                out.append(table(rows, [col, 'count', 'first_cycle', 'last_cycle', 'etypes', 'symbol']))
        return '\n\n'.join(out) or 'no events'

    def _context(self, rid, eid, k):
        rows = self.db.execute(
            'SELECT cycle, hart, priv, pc, insn, rd, rd_val, mem_addr, mem_val FROM rvfi '
            'WHERE run_id=? AND anchor=? ORDER BY cycle, rowid', (rid, eid)).fetchall()
        ev_cyc = self.db.execute('SELECT cycle FROM event WHERE id=?', (eid,)).fetchone()[0]
        before = [r for r in rows if r[0] <= ev_cyc][-k:]
        after = [r for r in rows if r[0] > ev_cyc][:max(2, k // 4)]
        fmt = []
        for r in before + [None] + after:
            if r is None:
                fmt.append(['', '', '', '>>> event', '', '', '', ''])
                continue
            fmt.append([r[0], r[1], r[2], r[3], r[4], f'x{r[5]}={r[6]}' if r[5] is not None else '',
                        (f'{r[7]}' + (f' <- {r[8]}' if r[8] else '')) if r[7] else '', self.sym(r[3], rid)])
        return table(fmt, ['cycle', 'hart', 'priv', 'pc', 'insn', 'rd', 'mem', 'symbol'])

    def around(self, a):
        rid = self.run_ids(a.run)[0]
        evs = self.db.execute(
            'SELECT id, cycle, etype, addr, pc, aux, raw FROM event WHERE run_id=? AND etype LIKE ? '
            'AND id IN (SELECT DISTINCT anchor FROM rvfi WHERE run_id=?) ORDER BY cycle LIMIT ?',
            (rid, a.etype + '%', rid, a.n)).fetchall()
        out = []
        for eid, cyc, et, addr, pc, aux, raw in evs:
            out.append(f'### {self.name(rid)} {et} @ {cyc} addr={addr} pc={pc} {aux or ""}\n    {raw[:200]}')
            out.append(self._context(rid, eid, a.k))
        return '\n'.join(out) or 'no anchored events (ingest keeps RVFI for the first of each type)'

    def asserts(self, a):
        out = []
        for rid, eid, cyc, et, core, aux, det in self.db.execute(
                "SELECT run_id, id, cycle, etype, core, aux, detail FROM event WHERE class='assert' "
                "ORDER BY run_id, cycle"):
            d = json.loads(det) if det else {}
            out.append(f'### {self.name(rid)} @ {cyc} core={core} {et} [{aux}]\n    {d.get("msg", "")[:220]}')
            out.append(self._context(rid, eid, a.k))
        return '\n'.join(out) or 'no assertions'

    def _has_analysis(self):
        r = self.db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='event_analysis'"
        ).fetchone()
        return r is not None

    def hangs(self, a):
        ids = self.run_ids(a.run)
        if self._has_analysis():
            rows = self.db.execute(
                f"SELECT e.run_id, COALESCE(a.bucket,''), COALESCE(a.evidence,''), e.etype, e.pc, "
                f"COUNT(*), MIN(e.cycle), MAX(e.cycle), MAX(a.since_ack), MAX(a.series_max_ack), e.detail "
                f"FROM event e LEFT JOIN event_analysis a ON a.event_id=e.id "
                f"WHERE e.class='hang' AND e.run_id IN ({','.join('?' * len(ids))}) "
                "GROUP BY e.run_id, a.bucket, a.evidence, e.etype, e.pc "
                "ORDER BY CASE a.bucket WHEN 'primary-candidate' THEN 0 ELSE 1 END, "
                "MAX(a.series_max_ack) DESC, e.run_id, 7", ids).fetchall()
            fmt = []
            for rid, bkt, ev, et, pc, n, c0, c1, max_ack, smax, det in rows:
                d = json.loads(det) if det else {}
                lu, lsu = d.get('LU req:', {}), {**d.get('LSU bypass', {}), **d.get('LU', {})}
                fmt.append([self.name(rid), bkt, ev, et, pc, self.sym(pc, rid), n, c0, c1, max_ack, smax,
                            f"lu_state={lsu.get('state', '')} lsu_cnt={lsu.get('cnt', '')} "
                            f"ld_va={lu.get('vaddr', '')} dtlb_hit={lu.get('dtlb_hit', '')}"])
            return table(fmt, ['run', 'bucket', 'evidence', 'head', 'head_pc', 'symbol', 'dumps',
                               'first', 'last', 'max_ack', 'series_max', 'lsu'])
        rows = self.db.execute(
            f"SELECT e.run_id, e.etype, e.pc, e.addr, COUNT(*), MIN(e.cycle), MAX(e.cycle), e.aux, e.detail "
            f"FROM event e WHERE e.class='hang' AND e.run_id IN ({','.join('?' * len(ids))}) "
            "GROUP BY e.run_id, e.etype, e.pc ORDER BY e.run_id, 6", ids).fetchall()
        fmt = []
        for rid, et, pc, addr, n, c0, c1, aux, det in rows:
            d = json.loads(det) if det else {}
            lu, lsu = d.get('LU req:', {}), {**d.get('LSU bypass', {}), **d.get('LU', {})}
            fmt.append([self.name(rid), et, pc, self.sym(pc, rid), n, c0, c1, aux,
                        f"lu_state={lsu.get('state', '')} lsu_cnt={lsu.get('cnt', '')} "
                        f"ld_va={lu.get('vaddr', '')} dtlb_hit={lu.get('dtlb_hit', '')}"])
        return table(fmt, ['run', 'head', 'head_pc', 'symbol', 'dumps', 'first', 'last', 'gap', 'lsu'])

    def buckets(self, a):
        if not self._has_analysis():
            return 'event_analysis table not present (re-run ingest.py)'
        ids = self.run_ids(a.run)
        rows = self.db.execute(
            f"SELECT a.bucket, a.evidence, COUNT(*), COUNT(DISTINCT a.run_id), "
            f"MAX(a.since_ack), MAX(a.series_max_ack) "
            f"FROM event_analysis a WHERE a.run_id IN ({','.join('?' * len(ids))}) "
            "GROUP BY a.bucket, a.evidence ORDER BY 3 DESC", ids).fetchall()
        return table(rows, ['bucket', 'evidence', 'count', 'runs', 'max_ack', 'max_series_ack'])

    def primary(self, a):
        if not self._has_analysis():
            return 'event_analysis table not present (re-run ingest.py)'
        ids = self.run_ids(a.run)
        rows = self.db.execute(
            f"SELECT e.run_id, a.evidence, e.class, e.etype, e.core, e.hart, e.pc, "
            f"COUNT(*), MIN(e.cycle), MAX(e.cycle), MAX(a.since_ack), MAX(a.series_max_ack), "
            f"MAX(a.series_span), MIN(a.note) "
            f"FROM event_analysis a JOIN event e ON e.id=a.event_id "
            f"WHERE a.bucket='primary-candidate' AND e.run_id IN ({','.join('?' * len(ids))}) "
            "GROUP BY e.run_id, a.evidence, e.class, e.etype, e.core, e.hart, e.pc "
            "ORDER BY CASE a.evidence WHEN 'model-assert' THEN 0 WHEN 'hang-persistent' THEN 1 ELSE 2 END, "
            "MAX(a.series_max_ack) DESC, COUNT(*) DESC", ids).fetchall()
        fmt = []
        for rid, ev, cls, et, core, hart, pc, n, c0, c1, mack, smax, span, note in rows:
            fmt.append([self.name(rid), ev, cls, et, core, hart, pc, self.sym(pc, rid),
                        n, c0, c1, mack, smax, span, (note or '')[:60]])
        return table(fmt, ['run', 'evidence', 'class', 'etype', 'core', 'hart', 'pc', 'symbol',
                           'n', 'first_cyc', 'last_cyc', 'max_ack', 'smax_ack', 'span', 'note'])

    def threads(self, a):
        ids = self.run_ids(a.run)
        rows = []
        for rid in ids:
            for core, hart, ret, ipc, lc, gap, wfi in self.db.execute(
                    'SELECT core, hart, retired, ipc, last_cycle, max_gap, wfi FROM thread WHERE run_id=? '
                    'ORDER BY core IS NULL, core, hart', (rid,)):
                ev = self.db.execute(
                    "SELECT COUNT(*) FROM event WHERE run_id=? AND class NOT IN ('verdict','tlb','wbuf') AND "
                    + ('core=?' if hart is None else 'hart=?'), (rid, core if hart is None else hart)).fetchone()[0]
                rows.append([self.name(rid), core, hart, ret, ipc, lc, gap, wfi, ev])
        return table(rows, ['run', 'core', 'hart', 'retired', 'ipc', 'last_cycle', 'max_gap', 'wfi', 'events'])

    def uart(self, a):
        rid = self.run_ids(a.run)[0]
        rows = self.db.execute('SELECT line_no, cycle, ktime, text FROM uart WHERE run_id=? ORDER BY line_no',
                               (rid,)).fetchall()
        keep, last = [], None
        for r in rows:           # one line per second of kernel time, plus every marker
            sec = int(r[2]) if r[2] is not None else None
            if sec != last or r[2] is None or 'G6LC' in r[3] or 'Run /init' in r[3]:
                keep.append([r[0], r[1], r[2], r[3][:110]])
                last = sec
        return table(keep[-a.n * 8:] if a.n else keep, ['line', 'cycle', 'ktime', 'text'])

    def profile(self, a):
        rid = self.run_ids(a.run)[0]
        b = a.bucket
        regs = [r[0] for r in self.db.execute('SELECT DISTINCT region FROM pc_sample WHERE run_id=? ORDER BY 1',
                                              (rid,))]
        rows = []
        for (k,) in self.db.execute('SELECT DISTINCT cycle/? FROM pc_sample WHERE run_id=? ORDER BY 1', (b, rid)):
            cnt = [self.db.execute('SELECT COUNT(*) FROM pc_sample WHERE run_id=? AND cycle/?=? AND region=?',
                                   (rid, b, k, r)).fetchone()[0] for r in regs]
            pr = self.db.execute('SELECT GROUP_CONCAT(p) FROM (SELECT priv || \':\' || COUNT(*) AS p FROM '
                                 'pc_sample WHERE run_id=? AND cycle/?=? GROUP BY priv)', (rid, b, k)).fetchone()[0]
            hot = self.db.execute('SELECT pc, COUNT(*) FROM pc_sample WHERE run_id=? AND cycle/?=? '
                                  'GROUP BY substr(pc,1,13) ORDER BY 2 DESC LIMIT 1', (rid, b, k)).fetchone()
            rows.append([f'{k * b // 1000000}M'] + [c or '' for c in cnt] + [pr, hot[0] if hot else ''])
        return table(rows, ['from'] + regs + ['priv:n', 'hottest'])

    def diff(self, a):
        ia, ib = self.run_ids([a.args[0]])[0], self.run_ids([a.args[1]])[0]
        lim = min(self.db.execute('SELECT last_cycle FROM run WHERE id=?', (i,)).fetchone()[0] for i in (ia, ib))
        ets = [r[0] for r in self.db.execute(
            "SELECT DISTINCT etype FROM event WHERE run_id IN (?,?) AND class NOT IN ('verdict','tlb') ORDER BY 1",
            (ia, ib))]
        rows = []
        for et in ets:
            ca, cb = (self.db.execute('SELECT COUNT(*) FROM event WHERE run_id=? AND etype=? AND cycle<=?',
                                      (i, et, lim)).fetchone()[0] for i in (ia, ib))
            rf = self.db.execute('SELECT rfix FROM etype WHERE etype=?', (et,)).fetchone()
            rows.append([et, ca, cb, cb - ca, rf[0] if rf else ''])
        return f'common cycles: 0..{lim}\n' + table(rows, ['etype', self.name(ia), self.name(ib), 'delta', 'rfix'])

    def sql(self, a):
        stmt = open(a.file).read() if a.file else ' '.join(a.args)
        if not stmt.strip():
            sys.exit('sql requires a query string or -f/--file PATH')
        cur = self.db.execute(stmt)
        if cur.description is None:
            return 'ok'
        return table(cur.fetchall(), [d[0] for d in cur.description])


def main():
    argv = sys.argv[1:] or shlex.split(os.environ.get('HYP8_TRACE_QUERY', 'runs'))
    ap = argparse.ArgumentParser()
    ap.add_argument('--db', default=os.environ.get('HYP8_TRACEDB', 'hyp8-trace.sqlite'))
    ap.add_argument('report')
    ap.add_argument('-r', '--run', action='append', default=[])
    ap.add_argument('-e', '--etype', default='')
    ap.add_argument('-f', '--file', default='', help='SQL file for `sql` report')
    ap.add_argument('-b', '--bucket', type=int, default=100000000)
    ap.add_argument('-n', type=int, default=6)
    ap.add_argument('-k', type=int, default=24, help='instructions of context')
    ap.add_argument('args', nargs='*')
    a = ap.parse_args(argv)
    q = Q(a.db)
    if not hasattr(q, a.report) or a.report.startswith('_'):
        sys.exit(__doc__)
    text = getattr(q, a.report)(a)
    print(text)
    out = os.environ.get('TH_OUT_DIR')
    if out:
        with open(os.path.join(out, 'query.txt'), 'a') as f:
            f.write(f'## {" ".join(argv)}\n{text}\n\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
