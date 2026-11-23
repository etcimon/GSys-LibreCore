cat > /tmp/trace_poll.py <<'PYEOF'
import sqlite3
c = sqlite3.connect("/opt/testharness/runs/hyp8-tracedb-ingest/output/hyp8-trace.sqlite")
print("--- run tags ---")
for r in c.execute("select id,tag,test,kind from run"): print("RUN", r)
print("--- pc type ---")
print(c.execute("select typeof(pc), count(*), min(cycle), max(cycle) from pc_sample").fetchone())
print("--- pc top run6 ---")
for r in c.execute("select pc,count(*) n from pc_sample where run_id=6 group by pc order by n desc limit 15"): print(str(r[0]), r[1])
PYEOF
python3 /tmp/trace_poll.py
