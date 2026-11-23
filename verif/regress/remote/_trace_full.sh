python3 - <<'PYEOF'
import sqlite3
c = sqlite3.connect("/opt/testharness/runs/hyp8-tracedb-ingest/output/hyp8-trace.sqlite")
print("=== event cols ===")
print([r[1] for r in c.execute("pragma table_info(event)")])
print("=== census cols/sample ===")
print([r[1] for r in c.execute("pragma table_info(census)")])
print(c.execute("select * from census where run_id=6 limit 3").fetchall())
print("=== etype ===")
for r in c.execute("select * from etype limit 40"): print(r)
PYEOF
