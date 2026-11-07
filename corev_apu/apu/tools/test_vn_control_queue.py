# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Authorized request/control/reply integration on synchronous sparse memory."""
import struct
import unittest

import vn_control as control
from vn_control_queue import ControlBuffer, ControlQueue
from vn_dma import DmaRegion, GuestDma
from vn_memory import ApertureState
from vn_resource_lifetime import ResourceState


class ControlQueueTests(unittest.TestCase):
    def setUp(self):
        self.memory = ApertureState(16384, 8192)
        self.state = ResourceState(self.memory.guest_ram)
        self.dispatcher = control.ControlDispatcher(self.state)
        self.dispatcher.register_resource(7, [DmaRegion(0, 8, True, True)])
        self.dma = GuestDma(self.memory.guest_ram)
        self.dma.policy.grant(128, 512, read=True)
        self.dma.policy.grant(1024, 64, read=False, write=True)
        self.queue = ControlQueue(self.dispatcher, self.dma)

    def packet(self, command, body=b''):
        return control.HEADER.pack(command, 1, 0x123456789ABCDEF0, 1, 3) + body

    def create(self):
        return self.packet(control.CTX_CREATE, struct.pack('<II64s', 0, 4, b''))

    def submit(self, packet, buffers=None):
        self.memory.guest_ram.write(128, packet)
        if buffers is None:
            buffers = [ControlBuffer(128, len(packet)), ControlBuffer(1024, 64, True)]
        return self.queue.process(buffers)

    def assert_not_created(self):
        reply = self.dispatcher.dispatch(self.create())
        self.assertEqual(control.HEADER.unpack(reply)[0], control.RESP_NODATA)

    def test_scatter_gather_header_and_used_accounting(self):
        self.memory.guest_ram.write(1024, b'Z' * 64)
        completion = self.submit(self.create(), [
            ControlBuffer(128, 7), ControlBuffer(135, 89),
            ControlBuffer(1024, 5, True), ControlBuffer(1029, 19, True)])
        self.assertEqual((completion.request_bytes, completion.reply_bytes,
                          completion.used_bytes), (96, 24, 120))
        self.assertEqual(control.HEADER.unpack(self.memory.guest_ram.read(1024, 24)),
                         (control.RESP_NODATA, 1, 0x123456789ABCDEF0, 1, 3))
        self.assertEqual(self.memory.guest_ram.read(1048, 40), b'Z' * 40)

    def test_late_reply_permission_failure_precedes_context_mutation(self):
        self.memory.guest_ram.write(1024, b'Z' * 64)
        before = self.memory.guest_ram.read(1024, 64)
        with self.assertRaises(PermissionError):
            self.submit(self.create(), [ControlBuffer(128, 96),
                                       ControlBuffer(1024, 5, True),
                                       ControlBuffer(2048, 19, True)])
        self.assertEqual(self.memory.guest_ram.read(1024, 64), before)
        self.assert_not_created()

    def test_late_request_permission_failure_has_no_reply(self):
        self.dma.policy.revoke(128, 512)
        self.dma.policy.grant(128, 24, read=True)
        self.memory.guest_ram.write(1024, b'Z' * 64)
        with self.assertRaises(PermissionError):
            self.submit(self.create())
        self.assertEqual(self.memory.guest_ram.read(1024, 64), b'Z' * 64)
        self.assert_not_created()

    def test_small_response_capacity_precedes_context_mutation(self):
        with self.assertRaises(ValueError):
            self.submit(self.create(), [ControlBuffer(128, 96),
                                       ControlBuffer(1024, 23, True)])
        self.assert_not_created()

    def test_invalid_descriptor_shapes_and_budgets(self):
        invalid = (ControlBuffer(-1, 1), ControlBuffer(1 << 64, 0),
                   ControlBuffer(128, -1), ControlBuffer(128, 1, 1),
                   ControlBuffer(16380, 8))
        for buffer in invalid:
            with self.assertRaises(ValueError):
                self.queue.process([buffer])
        with self.assertRaises(ValueError):
            self.queue.process([ControlBuffer(128, 0)] * 17)
        with self.assertRaises(TypeError):
            self.queue.process([{}])
        self.assert_not_created()

    def test_default_deny_and_invalid_queue_configuration(self):
        denied = ControlQueue(self.dispatcher, GuestDma(self.memory.guest_ram))
        self.memory.guest_ram.write(128, self.create())
        with self.assertRaises(PermissionError):
            denied.process([ControlBuffer(128, 96), ControlBuffer(1024, 24, True)])
        with self.assertRaises(TypeError):
            ControlQueue(self.dispatcher, self.memory.guest_ram)
        with self.assertRaises(ValueError):
            ControlQueue(self.dispatcher, self.dma, max_descriptors=0)
        self.assert_not_created()

    def test_packet_budget_is_checked_before_read_or_dispatch(self):
        with self.assertRaises(ValueError):
            self.queue.process([ControlBuffer(128, 4097),
                                ControlBuffer(1024, 24, True)])
        self.assert_not_created()

    def test_unref_through_queue_revokes_executor_access(self):
        self.submit(self.create())
        body = struct.pack('<II', 7, 0)
        self.submit(self.packet(control.CTX_ATTACH, body))
        access = self.dispatcher.attachment(1, 7)
        self.state.write(access, 0, b'abcd')
        self.submit(self.packet(control.RESOURCE_UNREF, body))
        with self.assertRaises(KeyError):
            self.state.read(access, 0, 4)
        self.assertEqual(control.HEADER.unpack(self.memory.guest_ram.read(1024, 24))[0],
                         control.RESP_NODATA)
