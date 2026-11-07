# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Bounded native control protocol checks; not RTL/CTS qualification."""
import struct
import unittest
from unittest.mock import patch

import vn_control as control
from vn_dma import DmaRegion
from vn_memory import ApertureState
from vn_resource_lifetime import ResourceState


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.memory = ApertureState(16384, 8192)
        self.state = ResourceState(self.memory.guest_ram)
        self.control = control.ControlDispatcher(self.state, max_contexts=2)
        self.control.register_resource(7, [DmaRegion(0, 8, True, True)])

    def packet(self, command, context=1, body=b'', flags=0, fence=0, ring=0):
        return control.HEADER.pack(command, flags, fence, context, ring) + body

    def create(self, context=1, name_length=0, context_init=4):
        return self.packet(control.CTX_CREATE, context,
                           struct.pack('<II64s', name_length, context_init, b'native'))

    def resource(self, command, context=1, resource=7):
        return self.packet(command, context, struct.pack('<II', resource, 0))

    def result(self, packet, **kwargs):
        reply = self.control.dispatch(packet, **kwargs)
        self.assertEqual(len(reply), control.HEADER.size)
        return control.HEADER.unpack(reply)[0]

    def test_header_roundtrip_and_unknown_command(self):
        packet = self.packet(0xFFFFFFFF, context=0x87654321, flags=0xFFFFFFFF,
                             fence=0xFEDCBA9876543210, ring=0xAABBCCDD)
        self.assertEqual(control.HEADER.unpack(self.control.dispatch(packet)),
                         (control.ERR_UNSPEC, 1, 0xFEDCBA9876543210,
                          0x87654321, 0xAABBCCDD))
        # Unimplemented blob/submit commands must not be acknowledged as working.
        for command in (0x010C, 0x0207, 0x0208):
            self.assertEqual(self.result(self.packet(command)), control.ERR_UNSPEC)

    def test_shared_resource_survives_context_teardown(self):
        for context in (1, 2):
            self.assertEqual(self.result(self.create(context)), control.RESP_NODATA)
            self.assertEqual(self.result(self.resource(control.CTX_ATTACH, context)),
                             control.RESP_NODATA)
        first = self.control.attachment(1, 7)
        second = self.control.attachment(2, 7)
        self.state.write(first, 0, b'abcd')
        self.assertEqual(self.result(self.packet(control.CTX_DESTROY)), control.RESP_NODATA)
        with self.assertRaises(KeyError):
            self.state.read(first, 0, 1)
        self.assertEqual(self.state.read(second, 0, 4), b'abcd')
        self.assertEqual(self.result(self.resource(control.RESOURCE_UNREF, 0)),
                         control.RESP_NODATA)
        with self.assertRaises(KeyError):
            self.state.read(second, 0, 1)
        with self.assertRaises(KeyError):
            self.control.attachment(2, 7)

    def test_attach_detach_are_idempotent_without_freeing_backing(self):
        self.result(self.create())
        for _ in range(2):
            self.assertEqual(self.result(self.resource(control.CTX_ATTACH)),
                             control.RESP_NODATA)
        old = self.control.attachment(1, 7)
        for _ in range(2):
            self.assertEqual(self.result(self.resource(control.CTX_DETACH)),
                             control.RESP_NODATA)
        with self.assertRaises(KeyError):
            self.state.read(old, 0, 1)
        self.assertEqual(self.result(self.resource(control.CTX_ATTACH)), control.RESP_NODATA)

    def test_error_mapping_and_reused_wire_ids(self):
        self.assertEqual(self.result(self.resource(control.CTX_ATTACH)), control.ERR_CONTEXT)
        self.result(self.create())
        self.assertEqual(self.result(self.create()), control.ERR_CONTEXT)
        self.assertEqual(self.result(self.resource(control.CTX_ATTACH, resource=8)),
                         control.ERR_RESOURCE)
        self.result(self.resource(control.CTX_ATTACH))
        old = self.control.attachment(1, 7)
        self.result(self.packet(control.CTX_DESTROY))
        self.result(self.create())
        self.result(self.resource(control.CTX_ATTACH))
        with self.assertRaises(KeyError):
            self.state.read(old, 0, 1)
        self.result(self.resource(control.RESOURCE_UNREF))
        self.assertEqual(self.result(self.resource(control.RESOURCE_UNREF)), control.ERR_RESOURCE)

    def test_every_truncated_command_has_no_side_effect(self):
        packets = (self.create(), self.packet(control.CTX_DESTROY),
                   self.resource(control.CTX_ATTACH), self.resource(control.CTX_DETACH),
                   self.resource(control.RESOURCE_UNREF))
        for packet in packets:
            for length in range(control.HEADER.size, len(packet)):
                self.assertEqual(self.result(packet[:length]), control.ERR_PARAMETER)
        self.assertEqual(self.result(self.create()), control.RESP_NODATA)
        self.assertEqual(self.result(self.resource(control.CTX_ATTACH)), control.RESP_NODATA)

    def test_invalid_context_create_and_budgets(self):
        for packet in (self.create(0), self.create(name_length=65), self.create(context_init=5)):
            self.assertEqual(self.result(packet), control.ERR_PARAMETER)
        self.assertEqual(self.result(self.create(context_init=0x10004)), control.RESP_NODATA)
        self.result(self.create(2))
        self.assertEqual(self.result(self.create(3)), control.ERR_OOM)
        self.result(self.packet(control.CTX_DESTROY, context=2))
        self.assertEqual(self.result(self.create(3)), control.RESP_NODATA)
        self.assertEqual(self.result(self.create(4) + bytes(4096)), control.ERR_PARAMETER)

    def test_short_reply_capacity_rejects_before_context_creation(self):
        for capacity in (0, 23, True):
            with self.assertRaises(ValueError):
                self.control.dispatch(self.create(), response_capacity=capacity)
        self.assertEqual(self.result(self.create()), control.RESP_NODATA)
        for length in range(control.HEADER.size):
            with self.assertRaises(ValueError):
                self.control.dispatch(self.create()[:length])

    def test_invalid_host_budgets_and_internal_errors_are_not_hidden(self):
        for kwargs in ({'max_contexts': 0}, {'max_request': 95}, {'max_request': True}):
            with self.assertRaises(ValueError):
                control.ControlDispatcher(self.state, **kwargs)
        with patch.object(self.state, 'create_context', side_effect=RuntimeError('backend fault')):
            with self.assertRaisesRegex(RuntimeError, 'backend fault'):
                self.control.dispatch(self.create())
