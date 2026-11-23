# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from g6lc_hotpath_ingest import digest, ingest, reverse_path


class ProvenanceTest(unittest.TestCase):
    def test_shared_callee_is_context_not_exclusive_task_work(self):
        with tempfile.TemporaryDirectory() as temp, sqlite3.connect(":memory:") as db:
            w = Path(temp)
            image = w / "model"
            image.write_bytes(b"fixture")
            sched = w / "schedule.json"
            sched.write_text(json.dumps(dict(schema="v3-sentinel-1", region="nba", tasks=[
                dict(id=i, lane=i, deps=[], waits=[]) for i in (1, 2)])))
            manifest = w / "binding.json"
            manifest.write_text(json.dumps(dict(elf_sha256=digest(image), bindings=[
                dict(task_id=i, symbol="leaf", evidence="fixture", snapshot_sha256=digest(sched))
                for i in (1, 2)])))
            db.executescript("""
                CREATE TABLE functions(addr INTEGER, name TEXT);
                INSERT INTO functions VALUES(1,'main'),(2,'dispatch'),(3,'leaf');
                CREATE TABLE calls(caller_addr INTEGER,target_addr INTEGER);
                INSERT INTO calls VALUES(1,2),(3,2);
                CREATE TABLE tail_jumps(caller_addr INTEGER,target_addr INTEGER);
                INSERT INTO tail_jumps VALUES(2,3);
            """)
            ingest(db, image, [sched], None, manifest)
            db.execute("INSERT INTO sample VALUES('instructions:u',4,3,100,1)")
            self.assertEqual(reverse_path(db, 3), ["main", "dispatch", "leaf"])
            self.assertEqual(db.execute("SELECT count(*) FROM task_context").fetchone(), (2,))
            self.assertEqual(db.execute("SELECT sum(weight) FROM sampled_function").fetchone(), (100,))
            self.assertEqual(db.execute("SELECT count(*) FROM region_context").fetchone(), (0,))


if __name__ == "__main__":
    unittest.main()
