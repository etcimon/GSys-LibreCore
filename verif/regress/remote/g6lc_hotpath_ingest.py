# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Join static sentinel facts and sampled native IPs without equating their ID spaces."""
from collections import Counter, defaultdict, deque
import hashlib
import json
import re
import subprocess

from g6lc_sentinel_dataflow import dataflow_index
from g6lc_sentinel_index import schedule_input


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def ingest(db, elf, snapshots, perf, bindings):
    sha = digest(elf)
    db.executescript("""
        CREATE TABLE image(sha256 TEXT PRIMARY KEY, path TEXT);
        CREATE TABLE snapshot(hash TEXT PRIMARY KEY, path TEXT, kind TEXT, scope TEXT);
        CREATE TABLE region(hash TEXT, vertex INTEGER, info TEXT, PRIMARY KEY(hash,vertex));
        CREATE TABLE task(hash TEXT, id INTEGER, info TEXT, PRIMARY KEY(hash,id));
        CREATE TABLE binding(hash TEXT, vertex INTEGER, func_addr INTEGER, evidence TEXT,
                             PRIMARY KEY(hash,vertex,func_addr));
        CREATE TABLE task_binding(hash TEXT, task_id INTEGER, func_addr INTEGER, evidence TEXT,
                                  PRIMARY KEY(hash,task_id,func_addr));
        CREATE TABLE sample(event TEXT, addr INTEGER, func_addr INTEGER, period INTEGER, count INTEGER,
                            PRIMARY KEY(event, addr));
        CREATE TABLE coverage(event TEXT, status TEXT, period INTEGER, count INTEGER);
        CREATE VIEW sampled_function AS SELECT event,func_addr,sum(period) AS weight
          FROM sample GROUP BY event,func_addr;
        CREATE VIEW region_context AS SELECT b.hash,b.vertex,b.evidence,b.func_addr,s.event,s.weight
          AS containing_function_weight FROM binding b JOIN sampled_function s USING(func_addr);
        CREATE VIEW task_context AS SELECT b.hash,b.task_id,b.evidence,b.func_addr,s.event,s.weight
          AS containing_function_weight FROM task_binding b JOIN sampled_function s USING(func_addr);
    """)
    db.execute("INSERT INTO image VALUES(?,?)", (sha, str(elf)))
    for path in snapshots:
        raw = path.read_bytes()
        h = hashlib.sha256(raw).hexdigest()
        obj = json.loads(raw)
        kind = obj["schema"]
        if kind == "v3-sentinel-dfg-1":
            idx = dataflow_index(obj)
            scope = obj["module"] + ":" + obj["phase"]
            db.executemany("INSERT INTO region VALUES(?,?,?)", (
                (h, r["vertex"], json.dumps(r)) for r in idx["regions"]))
        else:
            schedule_input(obj)
            scope = obj["region"]
            db.executemany("INSERT INTO task VALUES(?,?,?)", (
                (h, t["id"], json.dumps(t)) for t in obj["tasks"]))
        db.execute("INSERT INTO snapshot VALUES(?,?,?,?)", (h, str(path), kind, scope))
    symbols = defaultdict(list)
    for addr, name in db.execute("SELECT addr,name FROM functions"):
        symbols[name].append(addr)
    if bindings:
        manifest = json.loads(bindings.read_text())
        if manifest["elf_sha256"] != sha:
            raise ValueError("source binding ELF digest mismatch")
        for b in manifest["bindings"]:
            if ("vertex" in b) == ("task_id" in b):
                raise ValueError("binding must name exactly one DFG vertex or schedule task")
            is_task = "task_id" in b
            h, v = b["snapshot_sha256"], b["task_id" if is_task else "vertex"]
            lookup = ("SELECT 1 FROM task WHERE hash=? AND id=?" if is_task else
                      "SELECT 1 FROM region WHERE hash=? AND vertex=?")
            if (not db.execute(lookup, (h, v)).fetchone()
                    or len(symbols[b["symbol"]]) != 1 or not b["evidence"].strip()):
                raise ValueError("unresolved or ambiguous source binding")
            insert = ("INSERT INTO task_binding" if is_task else "INSERT INTO binding")
            db.execute(insert + " VALUES(?,?,?,?)",
                       (h, v, symbols[b["symbol"]][0], b["evidence"]))
    if not perf:
        return {"elf_sha256": sha}
    notes = subprocess.check_output(["readelf", "-n", elf], text=True)
    bid = re.search(r"Build ID: ([0-9a-f]+)", notes)
    dsos = set()
    for line in subprocess.check_output(["perf", "buildid-list", "-i", perf], text=True).splitlines():
        parts = line.split(None, 1)
        if bid and len(parts) == 2 and parts[0] == bid[1]:
            dsos.add(parts[1])
    if not dsos:
        raise ValueError("missing or mismatched perf build ID; relink with -Wl,--build-id")
    weights, counts, cov, n = Counter(), Counter(), Counter(), Counter()
    cmd = ["perf", "script", "-i", perf, "--no-demangle", "-F", "event,period,ip,sym,symoff,dso"]
    addr_cache, owners = {}, {}
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True) as proc:
        for line in proc.stdout:
            if not line.strip() or line.startswith("#"):
                continue
            m = re.fullmatch(r"\s*(\d+)\s+(\S+):\s+\S+\s+(.*?)\s+\((.*)\)\s*", line)
            if not m:
                raise ValueError("unexpected perf script record: " + line[:160])
            wt, event, symoff, dso = m.groups()
            wt = int(wt)
            status = "other_dso"
            if dso in dsos:
                if symoff not in addr_cache:
                    sm = re.fullmatch(r"(.+?)(?:\+0x([0-9a-f]+))?", symoff)
                    addr = None
                    if sm and len(symbols.get(sm[1], ())) == 1:
                        start = symbols[sm[1]][0]
                        ip = start + int(sm[2] or "0", 16)
                        if db.execute("SELECT 1 FROM insns WHERE addr=? AND func_addr=?",
                                      (ip, start)).fetchone():
                            addr = ip
                            owners[ip] = start
                    addr_cache[symoff] = addr
                addr = addr_cache[symoff]
                status = "unresolved" if addr is None else "mapped"
                if addr is not None:
                    weights[event, addr] += wt
                    counts[event, addr] += 1
            cov[event, status] += wt
            n[event, status] += 1
        if proc.wait():
            raise ValueError("perf script failed")
    if not weights:
        raise ValueError("no sampled IP resolved to an instruction in this ELF")
    db.executemany("INSERT INTO sample VALUES(?,?,?,?,?)",
                   ((e, a, owners[a], w, counts[e, a]) for (e, a), w in weights.items()))
    db.executemany("INSERT INTO coverage VALUES(?,?,?,?)",
                   ((*k, w, n[k]) for k, w in cov.items()))
    tops = []
    for event in sorted({k[0] for k in cov}):
        total = sum(w for (e, _), w in cov.items() if e == event)
        for faddr, name, weight in db.execute("""
            SELECT addr,name,weight FROM sampled_function JOIN functions ON func_addr=addr
            WHERE event=? ORDER BY weight DESC,addr LIMIT 10""", (event,)):
            path = reverse_path(db, faddr)
            fraction = weight / total
            tops.append(dict(event=event, symbol=name, self_pct=100*fraction, static_path=path,
                             # If only this symbol's self work changed, not its callees:
                             half_self_event_reduction_pct=50*fraction))
    regions = [dict(snapshot=h, vertex=v, symbol=sym, event=e, containing_function_period=w,
                    evidence=src) for h,v,sym,e,w,src in db.execute("""
        SELECT hash,vertex,name,event,containing_function_weight,evidence FROM region_context
        JOIN functions ON func_addr=addr ORDER BY event,containing_function_weight DESC,hash,vertex""")]
    return dict(elf_sha256=sha, build_id=bid[1], top=tops, region_context=regions,
                coverage=[dict(event=e,status=s,period=w,count=n[e,s]) for (e,s),w in cov.items()])


def reverse_path(db, leaf):
    """One shortest direct-call/tail-jump path, NOT a sampled call stack."""
    queue, child = deque([leaf]), {leaf: None}
    while queue:
        cur = queue.popleft()
        name, = db.execute("SELECT name FROM functions WHERE addr=?", (cur,)).fetchone()
        if name == "main" or "eval_stepEv" in name or "__Vthread__" in name:
            result = []
            while cur is not None:
                result.append(db.execute("SELECT name FROM functions WHERE addr=?", (cur,)).fetchone()[0])
                cur = child[cur]
            return result
        for parent, in db.execute("""SELECT caller_addr FROM calls WHERE target_addr=?
                UNION SELECT caller_addr FROM tail_jumps WHERE target_addr=?""", (cur, cur)):
            if parent not in child:
                child[parent] = cur
                queue.append(parent)
    return None
