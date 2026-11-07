#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Generation-scoped binary tokens for the serialized native transfer profile."""
from collections import deque
from dataclasses import dataclass


@dataclass(eq=False)
class BinaryToken:
    signaled: bool = False
    failed: bool = False
    claimed: bool = False
    consumed: bool = False


class BinarySemaphores:
    def __init__(self, submissions):
        self.submissions = submissions
        self.tokens = {}
        self.created = set()

    def plan(self, context, waits, signals, device):
        if len(waits) != len(set(waits)) or len(signals) != len(set(signals)):
            raise ValueError('duplicate binary semaphore wait/signal')
        objects, consumed, produced, previous = {}, [], [], []
        for value in (*waits, *signals):
            handle, entry = self.submissions._object(context, value, 'VkSemaphore')
            if (id(context), handle) not in self.created:
                raise ValueError('semaphore was not admitted as native binary')
            if entry['parent'] != device:
                raise ValueError('semaphore operation crosses devices')
            objects[value] = (handle, entry)
        if (len({objects[value][0] for value in waits}) != len(waits) or
                len({objects[value][0] for value in signals}) != len(signals)):
            raise ValueError('aliased duplicate binary semaphore wait/signal')
        for value in waits:
            handle, _ = objects[value]
            key = id(context), handle
            token = next((t for t in self.tokens.get(key, ()) if not t.claimed), None)
            if token is None:
                raise ValueError('binary wait requires an already-submitted signal')
            consumed.append((key, token))
        for value in signals:
            handle, _ = objects[value]
            key = id(context), handle
            tail = self.tokens.get(key, ())
            if tail and not tail[-1].claimed and not any(
                    t is tail[-1] for _, t in consumed):
                raise ValueError('binary semaphore already has an unconsumed signal')
            if tail:
                previous.append(tail[-1])
            produced.append((key, BinaryToken()))
        return BinaryReservation(self, consumed, produced, previous, list(objects.values()))

    def clean(self, context):
        kind = self.submissions.execution.golden.KIND['VkSemaphore']
        for key in tuple(self.tokens):
            if key[0] == id(context) and context.frontend.resolve(key[1], kind)[0] != 'OK':
                del self.tokens[key]
        for key in tuple(self.created):
            if key[0] == id(context) and context.frontend.resolve(key[1], kind)[0] != 'OK':
                self.created.remove(key)

    def retire_context(self, context):
        for key in tuple(self.tokens):
            if key[0] == id(context):
                del self.tokens[key]
        self.created = {key for key in self.created if key[0] != id(context)}


class BinaryReservation:
    def __init__(self, manager, consumed, produced, previous, objects):
        self.manager, self.consumed, self.produced = manager, consumed, produced
        self.objects = objects
        self.previous = previous

    def commit(self):
        for _, token in self.consumed:
            token.claimed = True
        for key, token in self.produced:
            self.manager.tokens.setdefault(key, deque()).append(token)

    def ready(self):
        if (any(token.failed for _, token in self.consumed) or
                any(token.failed for token in self.previous)):
            raise ValueError('binary semaphore producer failed')
        inputs = {token for _, token in self.consumed}
        if any(not token.consumed and token not in inputs for token in self.previous):
            return False
        if not all(token.signaled for _, token in self.consumed):
            return False
        for key, token in self.consumed:
            queue = self.manager.tokens.get(key)
            if not queue or queue[0] is not token:
                raise ValueError('binary semaphore token order changed')
            queue.popleft()
            token.consumed = True
            if not queue:
                del self.manager.tokens[key]
        self.consumed.clear()
        return True

    def finish(self, success):
        # Failed consumers still release their reserved input tokens. Outputs
        # carry failure, never fabricated success, to already-admitted dependents.
        for key, token in self.consumed:
            queue = self.manager.tokens.get(key)
            if queue and token in queue:
                queue.remove(token)
                if not queue:
                    del self.manager.tokens[key]
        self.consumed.clear()
        for _, token in self.produced:
            token.signaled, token.failed = success, not success
