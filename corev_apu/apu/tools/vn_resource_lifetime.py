#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Serialized native-backend resource lifetime, not guest wire dispatch.

Backing resources are device-global. Context destruction removes access but
does not unref backing; explicit resource unref invalidates every attachment.
Tokens are host capabilities, never guest-supplied IDs or Vulkan handles.
"""
from dataclasses import dataclass

from vn_dma_resources import DmaLease, ResourceDma


@dataclass(frozen=True)
class ContextRef:
    context: int
    generation: int


@dataclass(frozen=True)
class AttachmentRef:
    context: ContextRef
    backing: DmaLease
    read: bool
    write: bool


class ResourceState:
    """Compose global DMA backing with independently revocable context access.

    Callers serialize operations and drain work before teardown. This is not
    an asynchronous work-retirement or aperture/page allocator implementation.
    Pass ApertureState.guest_ram to share its store without copying memory.
    """

    def __init__(self, memory):
        self._dma = ResourceDma(memory)
        self._resources = {}
        self._contexts = {}
        self._generation = 0

    def create_context(self, context):
        if type(context) is not int or not 0 < context <= 0xFFFFFFFF:
            raise ValueError('invalid resource context')
        if context in self._contexts:
            raise KeyError('resource context already exists')
        self._generation += 1
        token = ContextRef(context, self._generation)
        self._contexts[context] = (token, {})
        return token

    def _context(self, token):
        if not isinstance(token, ContextRef):
            raise KeyError('invalid context capability')
        current = self._contexts.get(token.context)
        if current is None or current[0] is not token:
            raise KeyError('stale context capability')
        return current[1]

    def register_resource(self, resource, regions):
        # Owner zero is device-global, not the context that creates a blob.
        backing = self._dma.register(0, resource, regions)
        self._resources[resource] = backing
        return backing

    def _resource(self, backing):
        if (not isinstance(backing, DmaLease) or
                self._resources.get(backing.resource) is not backing):
            raise KeyError('stale backing capability')

    def attach(self, context, backing, *, read=True, write=False):
        attachments = self._context(context)
        self._resource(backing)
        if type(read) is not bool or type(write) is not bool or not (read or write):
            raise ValueError('attachment requires boolean access permissions')
        if backing.resource in attachments:
            raise KeyError('resource already attached')
        token = AttachmentRef(context, backing, read, write)
        attachments[backing.resource] = token
        return token

    def _attachment(self, token):
        if not isinstance(token, AttachmentRef):
            raise KeyError('invalid attachment capability')
        attachments = self._context(token.context)
        self._resource(token.backing)
        if attachments.get(token.backing.resource) is not token:
            raise KeyError('stale attachment capability')
        return attachments

    def detach(self, token):
        del self._attachment(token)[token.backing.resource]

    def destroy_context(self, context):
        attachments = self._context(context)
        count = len(attachments)
        del self._contexts[context.context]
        return count

    def unref_resource(self, backing):
        self._resource(backing)
        # Validate/revoke before dropping references, so a rejected revoke
        # cannot leave contexts half detached.
        self._dma.revoke(backing)
        for _, attachments in self._contexts.values():
            attachments.pop(backing.resource, None)
        del self._resources[backing.resource]

    def read(self, attachment, address, size):
        self._attachment(attachment)
        if not attachment.read:
            raise PermissionError('attachment does not permit reads')
        return self._dma.read(attachment.backing, address, size)

    def write(self, attachment, address, data):
        self._attachment(attachment)
        if not attachment.write:
            raise PermissionError('attachment does not permit writes')
        self._dma.write(attachment.backing, address, data)
