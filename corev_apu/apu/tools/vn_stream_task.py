#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Explicit bounded stream continuations; parked work never replays a prefix."""
from dataclasses import dataclass, replace
import struct

from vn_rings import RingBlocked
from vn_stream_group import StreamGroup, dependency_graph


@dataclass
class StreamFrame:
    words: tuple
    depth: int = 0
    position: int = 0
    reply_position: object = None
    entered: bool = False
    charged: bool = False
    view: object = None


class StreamTask:
    def __init__(self, execution, current, parent, data):
        if len(data) % 4 or len(data) > execution.max_bytes:
            raise ValueError('continuation exceeds byte/alignment bounds')
        self.execution, self.current, self.parent = execution, current, parent
        self.size = len(data)
        self.initial_reply, self.reply_version = current.reply, parent.reply_version
        self.remaining_bytes = execution.max_bytes - len(data)
        self.remaining_commands = execution.max_commands
        self.frames = [StreamFrame(struct.unpack('<%dI' % (len(data) // 4), data))]
        self.pins = []
        self.state, self.error = 'ready', None

    @property
    def terminal(self):
        return self.state in ('done', 'cancelled', 'faulted')

    def _close(self):
        self.frames.clear()
        for _, pin in reversed(self.pins):
            pin.__exit__(None, None, None)
        self.pins.clear()
        self.execution.tasks.pop(id(self), None)

    def cancel(self):
        if not self.terminal:
            self.state = 'cancelled'
            self._close()

    def live(self):
        parent = self.parent
        if (parent.retired or parent.faulted or
                self.current.frontend is not parent.frontend or
                self.execution.contexts.get(parent.frontend.ctx) is not parent):
            return False
        ring = self.current.active_ring
        return ring is None or self.execution.rings.live(ring)

    def advance(self, budget, *, quantum=256):
        if self.terminal:
            return
        if not self.live():
            self.cancel()
            return
        if len(budget) == 2:
            budget.append(self.execution.max_bytes)
        self.state = 'ready'
        attempts = 0
        blocked = set()
        try:
            while self.frames and attempts < quantum and budget[0]:
                top = self.frames[-1]
                group = top if isinstance(top, StreamGroup) else None
                if group is not None:
                    if group.done:
                        self.current.reply = group.reply
                        self.frames.pop()
                        continue
                    index = group.pick(blocked)
                    if index is None:
                        self.state = 'waiting'
                        return
                    frame = group.frames[index]
                    if frame.view is None:
                        frame.view = replace(self.current, reply=group.reply)
                else:
                    frame = top
                    frame.view = self.current
                view = frame.view
                if not frame.entered:
                    if frame.reply_position is not None and view.reply is not None:
                        position = frame.reply_position
                        if position % 4 or position > view.reply[2]:
                            raise ValueError('nested reply position exceeds stream')
                        view.reply = (*view.reply[:3], position)
                    frame.entered = True
                if frame.position == len(frame.words):
                    if group is not None:
                        group.finish(index)
                    else:
                        self.frames.pop()
                    continue
                record = self.execution.decoder.run(frame.words[frame.position:])
                length = record['words']
                if record['fault'] or not 0 < length <= len(frame.words) - frame.position:
                    raise ValueError('invalid continuation command')
                if length * 4 > budget[1]:
                    return
                if not frame.charged:
                    if not self.remaining_commands:
                        raise ValueError('continuation command budget exhausted')
                    self.remaining_commands -= 1
                    frame.charged = True
                budget[0] -= 1
                budget[1] -= length * 4
                attempts += 1
                words = frame.words[frame.position:frame.position + length]
                name = self.execution.names[record['type']]
                if name == 'vkExecuteCommandStreamsMESA':
                    children = self._children(frame, words, budget)
                    if children is None:
                        return  # Another task used this turn's nested-read allowance.
                    frame.position += length
                    frame.charged = False
                    self.frames.append(children)
                    continue
                try:
                    self.execution._command(view, name, words, record, budget, frame.depth)
                except RingBlocked:
                    if group is not None:
                        blocked.add((group, index))
                        group.park(index)
                        continue
                    self.state = 'waiting'
                    return
                if self.terminal:
                    return
                frame.position += length
                frame.charged = False
            # Empty trailing frames do not require another scheduling quantum.
            self._finish_frames()
            if self.frames and not self.remaining_commands:
                top = self.frames[-1]
                candidates = ([top.frames[index] for index in top.ready]
                              if isinstance(top, StreamGroup) else [top])
                if any(not frame.charged and frame.position < len(frame.words)
                       for frame in candidates):
                    raise ValueError('continuation command budget exhausted')
            if not self.frames:
                self.state = 'done'
                self.execution.publish_reply_cursor(self)
                self._close()
        except BaseException as error:
            self.error, self.state = error, 'faulted'
            self._close()
            raise

    def _finish_frames(self):
        while self.frames:
            top = self.frames[-1]
            if isinstance(top, StreamGroup):
                for index in tuple(top.ready):
                    frame = top.frames[index]
                    if frame.entered and frame.position == len(frame.words):
                        top.finish(index)
                if not top.done:
                    return
                self.current.reply = top.reply
            elif top.position != len(top.words):
                return
            self.frames.pop()

    def _children(self, frame, words, budget):
        def u64(index):
            return words[index] | words[index + 1] << 32

        if frame.depth:
            raise ValueError('nested command-stream depth exceeded')
        count = words[2]
        if count > self.execution.max_commands:
            raise ValueError('nested frame budget exhausted')
        positions_count = u64(5 + 5 * count)
        positions = 7 + 5 * count
        if positions_count not in (0, count):
            raise ValueError('reply-position count does not match streams')
        dependencies = positions + 2 * positions_count
        edge_count = words[dependencies]
        if edge_count != u64(dependencies + 1) or edge_count > self.execution.max_commands * 4:
            raise ValueError('invalid command-stream dependency count or budget')
        edges = [(words[dependencies + 3 + index * 2],
                  words[dependencies + 4 + index * 2]) for index in range(edge_count)]
        graph = dependency_graph(count, edges, max_edges=self.execution.max_commands * 4)
        sources, total = [], 0
        for index in range(count):
            start = 5 + 5 * index
            mapping = self.execution.blobs.mapping(words[start])
            offset, size = u64(start + 1), u64(start + 3)
            self.execution.blobs._live(mapping, offset, size)
            if size % 4 or offset % 4:
                raise ValueError('unaligned nested stream')
            total += size
            sources.append((mapping, offset, size,
                            u64(positions + 2 * index) if positions_count else None))
        if total > self.remaining_bytes:
            raise ValueError('nested sources exceed continuation byte budget')
        if total > budget[2]:
            return None
        budget[2] -= total
        self.remaining_bytes -= total
        children = []
        for mapping, offset, size, position in sources:
            if not any(owned is mapping for owned, _ in self.pins):
                pin = self.execution.blobs.pin(mapping)
                pin.__enter__()
                self.pins.append((mapping, pin))
            data = self.execution.blobs.read(mapping, offset, size)
            children.append(StreamFrame(struct.unpack('<%dI' % (size // 4), data),
                                        frame.depth + 1, reply_position=position))
        return StreamGroup(children, graph, self.current.reply)
