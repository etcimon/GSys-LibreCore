#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded source-before-destination dependencies for native stream groups."""
from collections import deque


def dependency_graph(count, edges, *, max_edges):
    if len(edges) > max_edges:
        raise ValueError('command-stream edge budget exhausted')
    successors = [set() for _ in range(count)]
    incoming = [0] * count
    for source, destination in edges:
        if not (0 <= source < count and 0 <= destination < count) or source == destination:
            raise ValueError('invalid command-stream dependency index')
        if destination not in successors[source]:
            successors[source].add(destination)
            incoming[destination] += 1
    remaining = incoming.copy()
    ready = deque(index for index, degree in enumerate(remaining) if not degree)
    visited = 0
    while ready:
        source = ready.popleft()
        visited += 1
        for destination in sorted(successors[source]):
            remaining[destination] -= 1
            if not remaining[destination]:
                ready.append(destination)
    if visited != count:
        raise ValueError('cyclic command-stream dependency graph')
    return successors, incoming


class StreamGroup:
    def __init__(self, frames, graph, reply):
        self.frames = frames
        self.successors, self.incoming = graph
        self.ready = deque(index for index, degree in enumerate(self.incoming) if not degree)
        self.completed = 0
        self.reply = reply

    @property
    def done(self):
        return self.completed == len(self.frames)

    def pick(self, blocked):
        return next((index for index in self.ready if (self, index) not in blocked), None)

    def park(self, index):
        self.ready.remove(index)
        self.ready.append(index)

    def finish(self, index):
        self.ready.remove(index)
        self.completed += 1
        self.reply = self.frames[index].view.reply
        for destination in sorted(self.successors[index]):
            self.incoming[destination] -= 1
            if not self.incoming[destination]:
                self.ready.append(destination)
