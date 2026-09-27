#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Concurrent lane runner for remote qualification work.

Reads a lane list (JSON, or a tiny line-oriented YAML subset) and launches
each lane's local command concurrently, bounded by a remote thread budget.
Each lane's command is a full local invocation — typically a helper script
that drives ``testharness_proxy.py`` (which stages, runs and pulls artifacts
itself). A lane fails or passes without aborting the others; a lane whose
``after`` dependencies did not all succeed is skipped, not failed.

Lane file (JSON list, or ``{"lanes": [...]}``)::

    [
      {"tag": "my-run-r1", "threads": 1,
       "command": ["bash", "run-osbi.sh", "tag", "build", "int2"]},
      {"tag": "dep-run", "threads": 4, "after": ["my-run-r1"],
       "command": ["python3", "do.py"]}
    ]

YAML subset accepted when the file is not JSON::

    - tag: my-run-r1
      threads: 1
      after: [other-tag]
      command: bash run-osbi.sh tag build int2

``command`` in YAML is split with shlex. In JSON it is a list.

Usage:
    python3 run_queue.py lanes.json --budget 11 --remote-nproc 12 \
        --out /path/to/queue-out
"""

import argparse
import concurrent.futures
import json
import os
import re
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

STATUS_PENDING = 'pending'
STATUS_RUNNING = 'running'
STATUS_PASSED = 'passed'
STATUS_FAILED = 'failed'
STATUS_SKIPPED = 'skipped'


def parse_lane_file(text):
    """Parse a lane file. JSON first; otherwise the YAML subset above."""
    stripped = text.strip()
    if stripped.startswith(('[', '{')):
        doc = json.loads(stripped)
        lanes = doc['lanes'] if isinstance(doc, dict) else doc
        return [_normalise_lane(l, i) for i, l in enumerate(lanes)]
    lanes = []
    cur = None
    for raw in stripped.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^\s*-\s*(.*)$', line)
        if m:
            if cur is not None:
                lanes.append(cur)
            cur = {}
            line = m.group(1)
            if not line:
                continue
        if cur is None:
            raise ValueError('lane file line outside any lane: %r' % raw)
        key, sep, value = line.partition(':')
        if not sep:
            raise ValueError('lane file line is not key: value — %r' % raw)
        key, value = key.strip(), value.strip()
        if value.startswith('[') and value.endswith(']'):
            value = [v.strip() for v in value[1:-1].split(',') if v.strip()]
        elif value.startswith(('"', "'")):
            value = value.strip('"\'')
        cur[key] = value
    if cur is not None:
        lanes.append(cur)
    return [_normalise_lane(l, i) for i, l in enumerate(lanes)]


def _normalise_lane(lane, index):
    if not isinstance(lane, dict):
        raise ValueError(f'lane {index} is not a mapping')
    tag = lane.get('tag')
    if not tag:
        raise ValueError(f'lane {index} has no tag')
    command = lane.get('command')
    if isinstance(command, str):
        command = shlex.split(command)
    if not isinstance(command, list) or not command or not all(
            isinstance(c, str) for c in command):
        raise ValueError(f'lane {tag}: command must be an argv list or a string')
    threads = int(lane.get('threads', 1))
    if threads < 1:
        raise ValueError(f'lane {tag}: threads must be >= 1')
    after = lane.get('after', [])
    if isinstance(after, str):
        after = [after]
    return {'tag': tag, 'command': command, 'threads': threads,
            'after': list(after)}


class LaneScheduler:
    """Thread-budgeted lane scheduler.

    Pure state machine — no I/O. ``tick()`` returns the list of lanes to
    start now; the caller reports completion via ``finish()``. Lanes whose
    ``after`` set did not all pass are skipped (marked, never started).
    """

    def __init__(self, lanes, budget):
        if budget < 1:
            raise ValueError('budget must be >= 1')
        self.budget = budget
        self.lanes = {}
        for lane in lanes:
            if lane['tag'] in self.lanes:
                raise ValueError(f"duplicate lane tag {lane['tag']}")
            self.lanes[lane['tag']] = dict(lane, status=STATUS_PENDING,
                                           start=None, end=None, wall=None,
                                           rc=None)
        for lane in lanes:
            for dep in lane['after']:
                if dep not in self.lanes:
                    raise ValueError(f"lane {lane['tag']} depends on unknown "
                                     f"tag {dep}")
                if dep == lane['tag']:
                    raise ValueError(f"lane {lane['tag']} depends on itself")
        self._check_cycles()

    def _check_cycles(self):
        visiting, done = set(), set()

        def visit(tag):
            if tag in done:
                return
            if tag in visiting:
                raise ValueError(f'dependency cycle at lane {tag}')
            visiting.add(tag)
            for dep in self.lanes[tag]['after']:
                visit(dep)
            visiting.discard(tag)
            done.add(tag)

        for tag in self.lanes:
            visit(tag)

    def _used(self):
        return sum(l['threads'] for l in self.lanes.values()
                   if l['status'] == STATUS_RUNNING)

    def _deps_state(self, lane):
        states = [self.lanes[d]['status'] for d in lane['after']]
        if any(s in (STATUS_FAILED, STATUS_SKIPPED) for s in states):
            return STATUS_SKIPPED
        if all(s == STATUS_PASSED for s in states):
            return STATUS_PASSED
        return STATUS_PENDING

    def _finalise_skips(self):
        """Mark pending lanes whose deps can never all pass."""
        changed = True
        while changed:
            changed = False
            for lane in self.lanes.values():
                if lane['status'] != STATUS_PENDING:
                    continue
                if self._deps_state(lane) == STATUS_SKIPPED:
                    lane['status'] = STATUS_SKIPPED
                    changed = True

    def tick(self):
        """Skip dead lanes, then return pending lanes that fit the budget,
        in file order."""
        self._finalise_skips()
        start = []
        used = self._used()
        for lane in self.lanes.values():
            if lane['status'] != STATUS_PENDING:
                continue
            if self._deps_state(lane) != STATUS_PASSED:
                continue
            if used + lane['threads'] > self.budget:
                continue
            lane['status'] = STATUS_RUNNING
            lane['start'] = time.time()
            used += lane['threads']
            start.append(lane)
        return start

    def finish(self, tag, rc):
        lane = self.lanes[tag]
        lane['status'] = STATUS_PASSED if rc == 0 else STATUS_FAILED
        lane['rc'] = rc
        lane['end'] = time.time()
        lane['wall'] = lane['end'] - (lane['start'] or lane['end'])

    def done(self):
        return all(l['status'] in (STATUS_PASSED, STATUS_FAILED, STATUS_SKIPPED)
                   for l in self.lanes.values())

    def summary(self):
        return {'budget': self.budget,
                'lanes': [{'tag': l['tag'], 'status': l['status'],
                           'threads': l['threads'], 'rc': l['rc'],
                           'start': l['start'], 'end': l['end'],
                           'wall': l['wall'], 'after': l['after'],
                           'command': l['command']}
                          for l in self.lanes.values()]}


def run_queue(lanes, budget, runner, log=print):
    """Run lanes to completion. ``runner(lane)`` must return the command rc
    (blocking). Returns the scheduler summary dict."""
    sched = LaneScheduler(lanes, budget)
    lock = threading.Lock()
    gate = threading.Condition(lock)
    live = {}

    def drive(lane):
        rc = 1
        try:
            rc = runner(lane)
        except Exception as error:  # runner must not kill the queue
            log(f"[queue] lane {lane['tag']} runner raised: {error}")
        with gate:
            sched.finish(lane['tag'], rc)
            gate.notify_all()
        log(f"[queue] lane {lane['tag']} finished rc={rc} "
            f"wall={sched.lanes[lane['tag']]['wall']:.1f}s")

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(lanes) or 1) \
            as pool:
        while not sched.done():
            for lane in sched.tick():
                log(f"[queue] lane {lane['tag']} start "
                    f"(threads={lane['threads']})")
                live[lane['tag']] = pool.submit(drive, lane)
            live = {t: f for t, f in live.items() if not f.done()}
            with gate:
                if not sched.done() and not live:
                    # Budget deadlock: pending lanes exceed the budget
                    pending = [l['tag'] for l in sched.lanes.values()
                               if l['status'] == STATUS_PENDING]
                    for tag in pending:
                        sched.lanes[tag]['status'] = STATUS_SKIPPED
                    log(f"[queue] lanes exceed budget, skipped: {pending}")
                if not sched.done():
                    gate.wait(timeout=60)
        for fut in live.values():
            fut.result()
    return sched.summary()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('lanes', help='lane file (JSON list or YAML subset)')
    ap.add_argument('--budget', type=int, default=None,
                    help='max concurrent remote threads (default: '
                         '--remote-nproc minus 1)')
    ap.add_argument('--remote-nproc', type=int,
                    default=len(os.sched_getaffinity(0)) if hasattr(
                        os, 'sched_getaffinity') else (os.cpu_count() or 2),
                    help='remote host CPU count used for the default budget')
    ap.add_argument('--out', default=None,
                    help='directory for queue.log/queue.json (default: cwd)')
    ap.add_argument('--dry-run', action='store_true',
                    help='plan only: validate lanes and budget, print the '
                         'schedule, run nothing')
    args = ap.parse_args(argv)

    lanes = parse_lane_file(Path(args.lanes).read_text())
    budget = args.budget if args.budget is not None \
        else max(1, args.remote_nproc - 1)
    out = Path(args.out or '.').resolve()
    out.mkdir(parents=True, exist_ok=True)
    log_path = out / 'queue.log'
    log_fh = log_path.open('a')

    def log(msg):
        line = f"[{time.strftime('%H:%M:%S')}] {msg}"
        print(line, flush=True)
        log_fh.write(line + '\n')
        log_fh.flush()

    if args.dry_run:
        sched = LaneScheduler(lanes, budget)
        print(json.dumps(sched.summary(), indent=2))
        return 0

    log(f"queue start: {len(lanes)} lane(s), budget={budget} "
        f"(remote-nproc={args.remote_nproc})")

    def runner(lane):
        log(f"[queue] {lane['tag']}$ " + ' '.join(
            shlex.quote(c) for c in lane['command']))
        return subprocess.run(lane['command'], check=False).returncode

    summary = run_queue(lanes, budget, runner, log)
    (out / 'queue.json').write_text(json.dumps(summary, indent=2))
    worst = 1 if any(l['status'] != STATUS_PASSED for l in summary['lanes']) \
        else 0
    log(f"queue done: " + ', '.join(
        f"{l['tag']}={l['status']}" for l in summary['lanes']))
    log_fh.close()
    return worst


if __name__ == '__main__':
    sys.exit(main())
