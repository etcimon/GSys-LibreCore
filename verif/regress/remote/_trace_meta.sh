python3 - <<'PYEOF'
import sqlite3
c = sqlite3.connect("/opt/testharness/runs/hyp8-tracedb-ingest/output/hyp8-trace.sqlite")
print("=== run cols ===")
print([r[1] for r in c.execute("pragma table_info(run)")])
for r in c.execute("select * from run where id=6"):
    print(r)
print("=== kv sample run6 ===")
for r in c.execute("select section,key,value from kv where run_id=6 limit 25"):
    print(r)
PYEOF
