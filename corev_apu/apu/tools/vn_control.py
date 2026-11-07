#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native virtio-gpu lifecycle dispatch, not a complete GPU backend.

Numeric command/header definitions follow the local vgctl protocol. Backing
registration is trusted host setup until blob/control allocation is integrated.
The caller serializes commands, drains work before teardown and owns DMA of
request/reply buffers. No guest descriptor is dereferenced here.
"""
import struct


CTX_CREATE = 0x0200
CTX_DESTROY = 0x0201
CTX_ATTACH = 0x0202
CTX_DETACH = 0x0203
RESOURCE_UNREF = 0x0102
RESP_NODATA = 0x1100
ERR_UNSPEC = 0x1200
ERR_OOM = 0x1201
ERR_RESOURCE = 0x1203
ERR_CONTEXT = 0x1204
ERR_PARAMETER = 0x1205
FLAG_FENCE = 1
CAPSET_VENUS = 4
HEADER = struct.Struct('<IIQII')
WORD = struct.Struct('<I')


class ControlDispatcher:
    """Wire IDs resolve to current host capabilities, never to stale tokens."""

    def __init__(self, resources, *, max_contexts=256, max_request=4096):
        if type(max_contexts) is not int or max_contexts <= 0:
            raise ValueError('invalid context budget')
        if type(max_request) is not int or max_request < 96:
            raise ValueError('invalid control request budget')
        self.resources = resources
        self.max_contexts = max_contexts
        self.max_request = max_request
        self._contexts = {}
        self._backings = {}
        self._attachments = {}

    def register_resource(self, resource, regions):
        """Trusted host setup only; wire commands cannot grant guest memory."""
        backing = self.resources.register_resource(resource, regions)
        self._backings[resource] = backing
        return backing

    def attachment(self, context, resource):
        """Resolve access for a serialized executor; ResourceState revalidates."""
        return self._attachments[(context, resource)]

    def reply_size(self, request, response_capacity):
        """Maximum response bytes for this packet, before any mutation."""
        return HEADER.size

    def reset(self):
        for backing in tuple(self._backings.values()):
            self.resources.unref_resource(backing)
        for context in tuple(self._contexts.values()):
            self.resources.destroy_context(context)
        self._backings.clear()
        self._contexts.clear()
        self._attachments.clear()

    def dispatch(self, request, *, response_capacity=HEADER.size):
        # A reply that cannot be published must not acknowledge a state change.
        if type(response_capacity) is not int or response_capacity < HEADER.size:
            raise ValueError('control reply buffer is shorter than its header')
        view = memoryview(request).cast('B')
        if len(view) < HEADER.size:
            raise ValueError('control request has no complete header')
        if len(view) > self.max_request:
            header = HEADER.unpack_from(view)
            return self._reply(header, ERR_PARAMETER)
        data = view.tobytes()
        header = HEADER.unpack_from(data)
        command = header[0]
        lengths = {CTX_CREATE: 96, CTX_DESTROY: 24, CTX_ATTACH: 32,
                   CTX_DETACH: 32, RESOURCE_UNREF: 32}
        if command not in lengths:
            result = ERR_UNSPEC
        elif len(data) < lengths[command]:
            result = ERR_PARAMETER
        else:
            result = self._execute(command, header[3], data)
        return self._reply(header, result)

    @staticmethod
    def _reply(header, result):
        _, flags, fence, context, ring = header
        # Match vgctl response-header construction, including on errors.
        return HEADER.pack(result, flags & FLAG_FENCE, fence, context, ring)

    def _execute(self, command, context, data):
        if command == CTX_CREATE:
            name_length, context_init = struct.unpack_from('<II', data, 24)
            if context == 0 or name_length > 64 or context_init & 0xFF != CAPSET_VENUS:
                return ERR_PARAMETER
            if context in self._contexts:
                return ERR_CONTEXT
            if len(self._contexts) >= self.max_contexts:
                return ERR_OOM
            self._contexts[context] = self.resources.create_context(context)
            return RESP_NODATA
        if command == CTX_DESTROY:
            token = self._contexts.get(context)
            if token is not None:
                self.resources.destroy_context(token)
                self._attachments = {key: value for key, value in self._attachments.items()
                                     if key[0] != context}
                del self._contexts[context]
            return RESP_NODATA
        resource = WORD.unpack_from(data, 24)[0]
        backing = self._backings.get(resource)
        if backing is None:
            return ERR_RESOURCE
        if command == RESOURCE_UNREF:
            self.resources.unref_resource(backing)
            self._attachments = {key: value for key, value in self._attachments.items()
                                 if key[1] != resource}
            del self._backings[resource]
            return RESP_NODATA
        token = self._contexts.get(context)
        if token is None:
            return ERR_CONTEXT
        key = (context, resource)
        if command == CTX_ATTACH:
            if key not in self._attachments:
                self._attachments[key] = self.resources.attach(token, backing, write=True)
        elif key in self._attachments:
            self.resources.detach(self._attachments[key])
            del self._attachments[key]
        return RESP_NODATA
