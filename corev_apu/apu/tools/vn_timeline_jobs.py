#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded timeline value reservations for native diagnostic queue jobs."""
from collections import deque
from dataclasses import dataclass


@dataclass(eq=False)
class TimelineSignal:
    value: int
    done: bool = False
    failed: bool = False


class TimelineJobs:
    def __init__(self, timelines):
        self.timelines = timelines
        self.pending, self.failed = {}, set()

    def plan(self, context, waits, signals, device):
        manager = self.timelines
        objects, inputs, outputs, previous = {}, [], [], []
        for role, pairs in (('wait', waits), ('signal', signals)):
            seen = set()
            for value, target in pairs:
                key = manager._object(context, value, device)
                if key in seen:
                    raise ValueError('duplicate queued timeline ' + role)
                seen.add(key)
                if type(target) is not int or not 0 <= target < 1 << 64:
                    raise ValueError('queued timeline value exceeds u64')
                objects[key[1]] = manager.submissions._object(context, value, 'VkSemaphore')[1]
                if role == 'wait':
                    inputs.append((key, target))
                    continue
                pending = self.pending.get(key, ())
                floor = max(manager.values[key], pending[-1].value if pending else 0)
                floor = max(floor, max((target for wait_key, target in inputs
                                         if wait_key == key), default=0))
                if target <= floor:
                    raise ValueError('queued timeline signal does not increase reserved values')
                if pending:
                    previous.append(pending[-1])
                outputs.append((key, TimelineSignal(target)))
        return TimelineReservation(self, inputs, outputs, previous, list(objects.items()))

    def host_signal(self, key, value):
        pending = self.pending.get(key, ())
        if pending and value >= pending[0].value:
            raise ValueError('host signal would overtake a reserved queue signal')

    def discard(self, context):
        for key in tuple(self.pending):
            if key[0] == id(context):
                del self.pending[key]
        self.failed = {key for key in self.failed if key[0] != id(context)}


class TimelineReservation:
    def __init__(self, jobs, inputs, outputs, previous, objects):
        self.jobs, self.inputs, self.outputs = jobs, inputs, outputs
        self.previous, self.objects = previous, objects

    def commit(self):
        for key, signal in self.outputs:
            self.jobs.pending.setdefault(key, deque()).append(signal)

    def ready(self):
        if any(signal.failed for signal in self.previous):
            raise ValueError('earlier queued timeline signal failed')
        for key, target in self.inputs:
            if key not in self.jobs.timelines.values:
                raise KeyError('queued timeline generation disappeared')
            if self.jobs.timelines.values[key] < target:
                if key in self.jobs.failed:
                    raise ValueError('queued timeline producer failed')
                return False
        return all(signal.done for signal in self.previous)

    def finish(self, success):
        for key, signal in self.outputs:
            queue = self.jobs.pending.get(key)
            if success:
                if not queue or queue[0] is not signal:
                    raise ValueError('queued timeline signal order changed')
                if signal.value <= self.jobs.timelines.values[key]:
                    raise ValueError('queued timeline counter would move backwards')
                self.jobs.timelines.values[key] = signal.value
            else:
                self.jobs.failed.add(key)
            signal.done, signal.failed = success, not success
            if queue and signal in queue:
                queue.remove(signal)
                if not queue:
                    del self.jobs.pending[key]
