#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Blob ownership and bounded native linear-execution control operations."""
import struct

from vn_deferred import DeferredReply
from vn_stream_task import StreamTask
from vn_control import (ControlDispatcher, HEADER, CTX_DESTROY, CTX_ATTACH, CTX_DETACH,
                        RESOURCE_UNREF, RESP_NODATA, ERR_PARAMETER, ERR_RESOURCE,
                        ERR_CONTEXT, ERR_UNSPEC, ERR_OOM)


CREATE_BLOB = 0x010C
MAP_BLOB = 0x0208
UNMAP_BLOB = 0x0209
RESP_MAP_INFO = 0x1106
SUBMIT_3D = 0x0207


class BlobController(ControlDispatcher):
    def __init__(self, resources, blobs, *, execution=None, **kwargs):
        super().__init__(resources, **kwargs)
        self.blobs = blobs
        self._blob_members = set()
        self.execution = execution

    def reply_size(self, request, response_capacity):
        if (40 <= len(request) <= self.max_request and response_capacity >= 32 and
                HEADER.unpack_from(request)[0] == MAP_BLOB):
            return 32
        return HEADER.size

    def dispatch(self, request, *, response_capacity=HEADER.size):
        if type(response_capacity) is not int or response_capacity < HEADER.size:
            raise ValueError('control reply buffer is shorter than its header')
        view = memoryview(request).cast('B')
        if len(view) < HEADER.size:
            raise ValueError('control request has no complete header')
        if len(view) > self.max_request:
            return self._reply(HEADER.unpack_from(view), ERR_PARAMETER)
        data = view.tobytes()
        header = HEADER.unpack_from(data)
        command, _, _, context, _ = header
        if command == SUBMIT_3D and self.execution is not None:
            if len(data) < 32:
                return self._reply(header, ERR_PARAMETER)
            size = struct.unpack_from('<I', data, 24)[0]
            if size % 4 or size > len(data) - 32:
                return self._reply(header, ERR_PARAMETER)
            if context not in self._contexts:
                return self._reply(header, ERR_CONTEXT)
            try:
                result = self.execution.execute(context, data[32:32 + size])
            except MemoryError:
                return self._reply(header, ERR_OOM)
            except (ValueError, KeyError):
                return self._reply(header, ERR_UNSPEC)
            if isinstance(result, StreamTask):
                return DeferredReply(result, lambda task: self._reply(
                    header, RESP_NODATA if task.state == 'done' else
                    ERR_CONTEXT if task.state == 'cancelled' else
                    ERR_OOM if isinstance(task.error, MemoryError) else ERR_UNSPEC))
            return self._reply(header, RESP_NODATA)
        sizes = {CREATE_BLOB: 56, MAP_BLOB: 40, UNMAP_BLOB: 32}
        if command in sizes:
            if len(data) < sizes[command]:
                return self._reply(header, ERR_PARAMETER)
            if command == MAP_BLOB and response_capacity < 32:
                return self._reply(header, ERR_PARAMETER)
            resource = struct.unpack_from('<I', data, 24)[0]
            try:
                if command == CREATE_BLOB:
                    resource, memory, flags, entries, blob_id, size = struct.unpack_from(
                        '<IIIIQQ', data, 24)
                    if memory != 2 or flags != 1 or entries:
                        return self._reply(header, ERR_PARAMETER)
                    if resource in self._backings:
                        return self._reply(header, ERR_RESOURCE)
                    if blob_id:
                        if self.execution is None:
                            return self._reply(header, ERR_UNSPEC)
                        if context not in self._contexts:
                            return self._reply(header, ERR_CONTEXT)
                        self.blobs.create_alias(resource, size,
                                                self.execution.memory(context, blob_id))
                    else:
                        self.blobs.create(resource, size)
                elif command == MAP_BLOB:
                    offset = struct.unpack_from('<Q', data, 32)[0]
                    self.blobs.map(resource, offset)
                    return self._reply(header, RESP_MAP_INFO) + struct.pack('<II', 3, 0)
                else:
                    self.blobs.unmap(resource)
            except KeyError:
                return self._reply(header, ERR_RESOURCE)
            except ValueError:
                return self._reply(header, ERR_PARAMETER)
            except MemoryError:
                return self._reply(header, ERR_OOM)
            except BlockingIOError:
                return self._reply(header, ERR_UNSPEC)
            return self._reply(header, RESP_NODATA)
        if command in (RESOURCE_UNREF, CTX_ATTACH, CTX_DETACH) and len(data) >= 32:
            resource = struct.unpack_from('<I', data, 24)[0]
            if resource in self.blobs.blobs:
                if command == RESOURCE_UNREF:
                    try:
                        self.blobs.unref(resource)
                    except BlockingIOError:
                        return self._reply(header, ERR_UNSPEC)
                    self._blob_members = {key for key in self._blob_members
                                          if key[1] != resource}
                elif context not in self._contexts:
                    return self._reply(header, ERR_CONTEXT)
                elif command == CTX_ATTACH:
                    self._blob_members.add((context, resource))
                else:
                    self._blob_members.discard((context, resource))
                return self._reply(header, RESP_NODATA)
        reply = super().dispatch(data, response_capacity=response_capacity)
        if command == CTX_DESTROY:
            self._blob_members = {key for key in self._blob_members if key[0] != context}
            if self.execution is not None:
                self.execution.retire_context(context)
        return reply

    def register_resource(self, resource, regions):
        if resource in self.blobs.blobs:
            raise KeyError('resource ID already belongs to a blob')
        return super().register_resource(resource, regions)

    def reset(self):
        if self.execution is not None:
            self.execution.prepare_reset()
        if any(blob.pins for blob in self.blobs.blobs.values()):
            raise BlockingIOError('reset requires blob pins to drain')
        for resource in tuple(self.blobs.blobs):
            self.blobs.unref(resource)
        if self.execution is not None:
            self.execution.reset()
        self._blob_members.clear()
        super().reset()
