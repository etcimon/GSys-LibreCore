#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native transfer work; no Vulkan submission or conformance admission."""
from collections import deque
from dataclasses import dataclass, field

from vn_borrowed_memory import MemoryOwner
from vn_compute import Compute, ShaderRuntime
from vn_graphics_fetch import Fetch, FetchRuntime
from vn_graphics_pshade import FragmentShade, FragmentShadeRuntime
from vn_graphics_raster import Raster, RasterRuntime, RasterShade, RasterShadeRuntime
from vn_graphics_shade import Shade, ShadeRuntime
from vn_graphics_drawexec import DrawExec, DrawExecRuntime
from vn_graphics_writeback import Writeback, WritebackRuntime
from vn_event_replay import EventSignal, EventWait, EventSignalRuntime, EventWaitRuntime
from vn_query_replay import (QueryBegin, QueryBeginRuntime, QueryCopy,
                             QueryCopyRuntime, QueryEnd, QueryEndRuntime,
                             QueryReset, QueryResetRuntime, QueryStamp,
                             QueryStampRuntime)
from vn_conditional_replay import (CondBegin, CondBeginRuntime, CondEnd,
                                   CondEndRuntime)


@dataclass(frozen=True)
class Transfer:
    kind: str
    destination: MemoryOwner
    offset: int
    size: int
    source: object = None
    source_offset: int = 0
    data: bytes = b''
    # conditional-rendering-gated ops (vkCmdClearAttachments rows)
    # evaluate the predicate once at their stream position
    conditional: bool = False


@dataclass(eq=False)
class TransferJob:
    context: object
    operations: tuple
    pins: list
    size: int
    state: str = 'queued'
    operation: int = 0
    position: int = 0
    error: str = ''
    retire: object = None
    complete: object = None
    prepare: object = None
    lane: object = None
    runtimes: dict = field(default_factory=dict)
    compute_stats: dict = field(default_factory=dict)
    fetch_stats: dict = field(default_factory=dict)
    shade_stats: dict = field(default_factory=dict)
    fshade_stats: dict = field(default_factory=dict)
    raster_stats: dict = field(default_factory=dict)
    rastershade_stats: dict = field(default_factory=dict)
    writeback_stats: dict = field(default_factory=dict)
    drawexec_stats: dict = field(default_factory=dict)
    event_stats: dict = field(default_factory=dict)
    query_stats: dict = field(default_factory=dict)
    cond_stats: dict = field(default_factory=dict)
    # per-operation conditional-rendering decisions for gated
    # Transfer ops (the predicate is sampled once per command's ops)
    gates: dict = field(default_factory=dict)
    turn_bytes: int = 0


class TransferExecutor:
    """Bounded round-robin across contexts and explicit diagnostic queue lanes.

    Internal jobs retain context-wide FIFO; explicit lanes preserve queue FIFO.
    Enqueue validates the complete job and acquires all generation leases before
    publishing it. Transfer errors retain already-written prefixes, never replay
    them, and release every lease. Wire fences are deliberately not owned here.
    """

    def __init__(self, execution, *, max_jobs=128, max_operations=256,
                 max_bytes=16 * 1024 * 1024, chunk_bytes=4096, poll_bytes=65536,
                 poll_operations=16):
        limits = (max_jobs, max_operations, max_bytes, chunk_bytes,
                  poll_bytes, poll_operations)
        if any(type(n) is not int or n <= 0 for n in limits):
            raise ValueError('invalid transfer budget')
        if chunk_bytes % 4 or poll_bytes % 4:
            raise ValueError('unaligned transfer chunk budget')
        self.execution = execution
        self.max_jobs, self.max_operations, self.max_bytes = limits[:3]
        self.chunk_bytes, self.poll_bytes, self.poll_operations = limits[3:]
        self.queues = {}
        self.lane_cursors = {}
        # id(context) -> {(id(entry), query): generated-fragment count}
        # for occlusion queries opened by QueryBegin ops
        self.occlusion = {}
        # for pipeline-statistics queries: (bits, [counters]) per
        # (pool,index), accumulated from DrawExec stage counters
        self.statistics = {}
        # id(context) -> (predicate_addr, inverted) for an open
        # conditional-rendering region; draw ops re-read the word
        self.cond = {}
        self.cursor = self.reserved_bytes = self.pending = 0

    @property
    def active(self):
        return bool(self.pending)

    def _live(self, context):
        return (self.execution.contexts.get(context.frontend.ctx) is context and
                not context.retired and not context.faulted and
                not getattr(context, 'gpu_lost', False))

    def _extent(self, context, owner, offset, size):
        if (not isinstance(owner, MemoryOwner) or owner.execution is not self.execution or
                owner.context is not context):
            raise KeyError('transfer memory belongs to another execution context')
        entry = owner._live()
        if owner.deferred_free is not None:
            raise KeyError('transfer memory has been freed')
        if (type(offset) is not int or type(size) is not int or offset < 0 or
                size < 0 or offset > entry['size'] or size > entry['size'] - offset):
            raise ValueError('transfer exceeds allocated memory')
        base = owner.base
        if base is None:
            raise ValueError('transfer memory is unbacked')
        self.execution.state.aperture._check_range(base + offset, size)
        return base + offset

    def enqueue(self, context, operations):
        if not self._live(context):
            raise KeyError('transfer context is unavailable')
        if (not isinstance(operations, (tuple, list)) or
                len(operations) > self.max_operations or
                self.pending >= self.max_jobs):
            raise MemoryError('transfer job/operation budget exhausted')
        operations, owners, size, runtimes = tuple(operations), {}, 0, {}
        for index, op in enumerate(operations):
            if isinstance(op, (Compute, Fetch, Shade, FragmentShade, Raster,
                               RasterShade, Writeback, DrawExec,
                               EventSignal, EventWait, QueryBegin, QueryEnd,
                               QueryReset, QueryStamp, QueryCopy,
                               CondBegin, CondEnd)):
                runtime = (ShaderRuntime if isinstance(op, Compute)
                           else FetchRuntime if isinstance(op, Fetch)
                           else ShadeRuntime if isinstance(op, Shade)
                           else FragmentShadeRuntime
                           if isinstance(op, FragmentShade)
                           else RasterShadeRuntime
                           if isinstance(op, RasterShade)
                           else DrawExecRuntime if isinstance(op, DrawExec)
                           else WritebackRuntime if isinstance(op, Writeback)
                           else EventSignalRuntime if isinstance(op, EventSignal)
                           else EventWaitRuntime if isinstance(op, EventWait)
                           else QueryBeginRuntime if isinstance(op, QueryBegin)
                           else QueryEndRuntime if isinstance(op, QueryEnd)
                           else CondBeginRuntime if isinstance(op, CondBegin)
                           else CondEndRuntime if isinstance(op, CondEnd)
                           else QueryCopyRuntime if isinstance(op, QueryCopy)
                           else QueryResetRuntime if isinstance(op, QueryReset)
                           else QueryStampRuntime if isinstance(op, QueryStamp)
                           else RasterRuntime)(self, context, op)
                runtimes[index] = runtime
                owners.update(runtime.owners)
                size += op.size
                if size > self.max_bytes - self.reserved_bytes:
                    raise MemoryError('aggregate compute/transfer byte budget exhausted')
                continue
            if not isinstance(op, Transfer) or op.kind not in (
                    'fill', 'update', 'copy', 'barrier', 'pattern'):
                raise ValueError('unsupported transfer operation')
            destination = self._extent(context, op.destination, op.offset, op.size)
            owners[id(op.destination)] = op.destination
            if type(op.data) is not bytes:
                raise ValueError('transfer payload must be immutable bytes')
            if op.kind == 'barrier':
                if op.size or op.data or op.source is not None or op.source_offset:
                    raise ValueError('barrier operation cannot contain byte work')
            elif op.kind == 'pattern':
                if (op.source is not None or op.source_offset or
                        len(op.data) not in (1, 2, 4, 8, 16) or not op.size or
                        op.size % len(op.data) or op.offset % len(op.data)):
                    raise ValueError('invalid bounded texel pattern')
            elif op.kind == 'copy':
                source = self._extent(context, op.source, op.source_offset, op.size)
                if op.data or (op.size and source < destination + op.size and
                               destination < source + op.size):
                    raise ValueError('copy overlaps or contains an unexpected payload')
                owners[id(op.source)] = op.source
            elif (op.source is not None or op.source_offset or op.offset % 4 or
                  op.size % 4 or
                  (op.kind == 'fill' and len(op.data) != 4) or
                  (op.kind == 'update' and
                   (len(op.data) != op.size or not 0 < op.size <= 65536))):
                raise ValueError('invalid fill/update transfer')
            size += op.size
            if size > self.max_bytes - self.reserved_bytes:
                raise MemoryError('aggregate transfer byte budget exhausted')
        pins = []
        try:
            for owner in owners.values():
                owner.pin_work()
                pins.append(owner)
            job = TransferJob(context, operations, pins, size)
            job.runtimes = runtimes
            key = id(context)
            self.queues.setdefault(key, deque()).append(job)
        except BaseException:
            for owner in reversed(pins):
                owner.unpin_work()
            raise
        self.pending += 1
        self.reserved_bytes += size
        return job

    def _finish(self, job, state, error=''):
        job.state, job.error = state, str(error)[:512]
        job.runtimes.clear()
        job.prepare = None
        self.pending -= 1
        self.reserved_bytes -= job.size
        retire, job.retire = job.retire, None
        try:
            if retire is not None:
                retire()
        except (ValueError, KeyError, MemoryError, OSError) as failure:
            job.state, job.error = 'faulted', str(failure)[:512]
        for owner in reversed(job.pins):
            try:
                owner.unpin_work()
            except (ValueError, KeyError, MemoryError, OSError) as failure:
                job.state, job.error = 'faulted', str(failure)[:512]
        job.pins.clear()
        complete, job.complete = job.complete, None
        try:
            if complete is not None:
                complete()
        except (ValueError, KeyError, MemoryError, OSError) as failure:
            job.state, job.error = 'faulted', str(failure)[:512]

    def cancel_context(self, context, *, lost=False):
        queue = self.queues.pop(id(context), ())
        self.lane_cursors.pop(id(context), None)
        self.occlusion.pop(id(context), None)
        self.statistics.pop(id(context), None)
        self.cond.pop(id(context), None)
        for job in queue:
            self._finish(job, 'faulted' if lost else 'cancelled',
                         'native GPU context lost' if lost else '')

    def _turn(self, job, budget):
        if job.operation == len(job.operations):
            return 0
        op = job.operations[job.operation]
        if isinstance(op, (Compute, Fetch, Shade, FragmentShade, Raster,
                           RasterShade, Writeback, DrawExec,
                           EventSignal, EventWait, QueryBegin, QueryEnd,
                           QueryReset, QueryStamp, QueryCopy,
                           CondBegin, CondEnd)):
            runtime = job.runtimes[job.operation]
            try:
                used = runtime.advance(budget)
            finally:
                job.turn_bytes = (runtime.memory.used if isinstance(op, Compute)
                                  else runtime.last_turn)
            if job.state != 'running':
                return used
            if runtime.done:
                # occlusion queries count every fragment the bounded
                # raster stages generate while open; there is no
                # depth/stencil test in the profile, so all covered
                # samples pass. Accumulation is per-context and per
                # (pool,index) so concurrent opens each observe the
                # same stream-ordered fragment stream.
                produced = (runtime.fragments if isinstance(op, Raster)
                            else runtime.raster.fragments
                            if isinstance(op, (RasterShade, DrawExec)) and
                            runtime.raster is not None else 0)
                if produced:
                    open_queries = self.occlusion.get(id(job.context))
                    if open_queries:
                        for key in open_queries:
                            open_queries[key] += produced
                if isinstance(op, DrawExec):
                    # pipeline-statistics queries accumulate the
                    # counters the admitted draw stages actually
                    # produced; a conditional-gated draw contributes
                    # zeros because no stage work ran
                    open_stats = self.statistics.get(id(job.context))
                    if open_stats:
                        vertices = runtime.shade.fetch.records_done
                        contributions = {
                            0: vertices,    # INPUT_ASSEMBLY_VERTICES
                            1: (runtime.raster.triangles
                                if runtime.raster else 0),
                            2: vertices,    # VERTEX_SHADER_INVOCATIONS
                            7: (runtime.fs.total if runtime.fs else 0),
                        }
                        for bits, acc in open_stats.values():
                            for i, bit in enumerate(bits):
                                acc[i] += contributions[bit]
                if isinstance(op, Compute):
                    job.compute_stats[job.operation] = dict(
                        steps=runtime.steps, robust=runtime.model.robust)
                elif isinstance(op, Fetch):
                    job.fetch_stats[job.operation] = dict(
                        records=runtime.records_done, robust=runtime.robust,
                        steps=runtime.steps)
                elif isinstance(op, Shade):
                    job.shade_stats[job.operation] = dict(
                        records=runtime.fetch.records_done, steps=runtime.steps,
                        batches=runtime.batches, robust=runtime.robust,
                        vary=len(runtime.vary))
                elif isinstance(op, DrawExec):
                    job.drawexec_stats[job.operation] = dict(
                        records=(runtime.wb.written if runtime.wb else 0),
                        dropped=(runtime.wb.dropped if runtime.wb else 0),
                        fragments=(runtime.raster.fragments
                                   if runtime.raster else 0),
                        triangles=(runtime.raster.triangles
                                   if runtime.raster else 0),
                        vary=len(runtime.shade.vary),
                        batches=(runtime.fs.batches if runtime.fs else 0),
                        color=len(runtime.fs.color) if runtime.fs else 0)
                elif isinstance(op, EventSignal):
                    job.event_stats[job.operation] = dict(
                        signaled=op.signaled)
                elif isinstance(op, EventWait):
                    job.event_stats[job.operation] = dict(
                        events=len(op.entries))
                elif isinstance(op, QueryBegin):
                    job.query_stats[job.operation] = dict(begun=op.index)
                elif isinstance(op, QueryEnd):
                    job.query_stats[job.operation] = dict(
                        ended=op.index,
                        samples=op.entry['qslots'][op.index])
                elif isinstance(op, CondBegin):
                    job.cond_stats[job.operation] = dict(
                        begun=1, inverted=op.inverted)
                elif isinstance(op, CondEnd):
                    job.cond_stats[job.operation] = dict(ended=1)
                elif isinstance(op, QueryReset):
                    job.query_stats[job.operation] = dict(
                        reset=op.spans[0][2])
                elif isinstance(op, QueryStamp):
                    job.query_stats[job.operation] = dict(
                        stamped=op.slots[0][1])
                elif isinstance(op, QueryCopy):
                    job.query_stats[job.operation] = dict(
                        copied=op.count, bytes=op.size)
                elif isinstance(op, Writeback):
                    job.writeback_stats[job.operation] = dict(
                        records=runtime.written, dropped=runtime.dropped,
                        steps=runtime.steps)
                elif isinstance(op, RasterShade):
                    job.rastershade_stats[job.operation] = dict(
                        records=runtime.raster.fragments,
                        triangles=runtime.raster.triangles,
                        culled=runtime.raster.culled,
                        degenerate=runtime.raster.degenerate,
                        tests=runtime.raster.tests,
                        steps=runtime.fs.steps if runtime.fs else 0,
                        batches=runtime.fs.batches if runtime.fs else 0,
                        robust=(runtime.raster.robust +
                                (runtime.fs.robust if runtime.fs else 0)),
                        color=len(runtime.fs.color) if runtime.fs else 0)
                elif isinstance(op, FragmentShade):
                    job.fshade_stats[job.operation] = dict(
                        records=runtime.total, steps=runtime.steps,
                        batches=runtime.batches, robust=runtime.robust,
                        color=len(runtime.color))
                else:
                    job.raster_stats[job.operation] = dict(
                        records=runtime.fragments, steps=runtime.steps,
                        triangles=runtime.triangles, culled=runtime.culled,
                        degenerate=runtime.degenerate, tests=runtime.tests,
                        robust=runtime.robust)
                del job.runtimes[job.operation]
                job.operation += 1
            return used
        if op.conditional:
            # vkCmdClearAttachments rows are gated by conditional
            # rendering; the predicate is sampled once per operation
            # (all rows of one command evaluate identically because no
            # other command's ops interleave inside the region)
            gate = self.cond.get(id(job.context))
            if gate is not None:
                decision = job.gates.get(job.operation)
                if decision is None:
                    addr, inverted = gate
                    word = int.from_bytes(
                        self.execution.state.aperture.read(addr, 4),
                        'little')
                    decision = job.gates[job.operation] = \
                        not ((word != 0) ^ bool(inverted))
                if decision:
                    job.position = op.size
        count = min(op.size - job.position, self.chunk_bytes, budget)
        if op.kind == 'fill':
            # A byte copy can leave less than one fill word in the shared budget.
            count &= ~3
        if count:
            job.turn_bytes = count
            destination = op.destination.base + op.offset + job.position
            memory = self.execution.state.aperture
            if op.kind == 'copy':
                data = memory.read(op.source.base + op.source_offset + job.position, count)
            elif op.kind == 'update':
                data = op.data[job.position:job.position + count]
            elif op.kind == 'pattern':
                phase = job.position % len(op.data)
                data = (op.data * ((phase + count + len(op.data) - 1) //
                                   len(op.data)))[phase:phase + count]
            else:
                data = op.data * (count // 4)
            if not self._live(job.context) or job.state != 'running':
                return 0
            memory.write(destination, data)
            job.position += count
        if job.position == op.size:
            job.operation += 1
            job.position = 0
        return count

    def _select(self, key, queue):
        heads, seen = [], set()
        for job in queue:
            if job.lane is None:
                if not heads and job is queue[0]:
                    heads.append(job)
                break  # Internal transfer jobs preserve context-wide ordering.
            if job.lane not in seen:
                heads.append(job)
                seen.add(job.lane)
        start = self.lane_cursors.get(key, 0) % len(heads) if heads else 0
        for index in range(len(heads)):
            job = heads[(start + index) % len(heads)]
            self.lane_cursors[key] = start + index + 1
            try:
                if job.prepare is not None:
                    if not job.prepare():
                        job.state = 'waiting'
                        continue
                    job.prepare = None
                return job, None
            except (ValueError, KeyError, MemoryError, OSError) as error:
                return job, error
        return None, None

    def poll(self):
        keys = tuple(self.queues)
        if not keys:
            return 0
        start = self.cursor % len(keys)
        keys = keys[start:] + keys[:start]
        budget, completed = self.poll_bytes, 0
        for index, key in enumerate(keys[:self.poll_operations]):
            self.cursor = start + index + 1
            queue = self.queues.get(key)
            if not queue:
                continue
            if not self._live(queue[0].context):
                context = queue[0].context
                self.cancel_context(context, lost=(getattr(context, 'gpu_lost', False) and
                                                   not context.retired and not context.faulted))
                continue
            job, failure = self._select(key, queue)
            if job is None:
                continue
            if self.queues.get(key) is not queue:
                continue
            job.turn_bytes = 0
            try:
                if failure is not None:
                    raise failure
                job.state = 'running'
                budget -= self._turn(job, budget)
                if self.queues.get(key) is not queue:
                    continue
                if job.operation == len(job.operations):
                    queue.remove(job)
                    self._finish(job, 'done')
                    completed += 1
            except (ValueError, KeyError, MemoryError, OSError) as error:
                budget = max(0, budget - job.turn_bytes)
                if self.queues.get(key) is not queue:
                    continue
                queue.remove(job)
                self._finish(job, 'faulted', error)
            if not queue:
                del self.queues[key]
                self.lane_cursors.pop(key, None)
            if not budget:
                break
        return completed
