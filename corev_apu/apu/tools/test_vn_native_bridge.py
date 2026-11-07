# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Real local-IPC subprocess tests using the existing RTL bridge client."""
import importlib.util
import io
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

from native_test_wire import NativeWire
from vn_blob_control import CREATE_BLOB, MAP_BLOB, UNMAP_BLOB, RESP_MAP_INFO, SUBMIT_3D
from vn_control import (HEADER, CTX_CREATE, CTX_DESTROY, RESOURCE_UNREF, RESP_NODATA,
                        ERR_RESOURCE, ERR_CONTEXT)
from vn_native_bridge import FrameChannel, geometry_from_map


HERE = Path(__file__).parent
ROOT = HERE.parents[2]
CLIENT = HERE / 'bridge_client_fixture.py'
MAP = HERE / 'venus_map.h'
if not CLIENT.exists():
    CLIENT = ROOT / 'verif/tb/apu/bridge/bridge_selftest.py'
if not MAP.exists():
    MAP = ROOT / 'software/apu-venus-probe/venus_map.h'
spec = importlib.util.spec_from_file_location('g6lc_native_test_client', CLIENT)
bridge_client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge_client)


class FragmentSocket:
    def __init__(self, data):
        self.data = io.BytesIO(data)
        self.sent = b''

    def settimeout(self, timeout):
        pass

    def recv(self, count):
        return self.data.read(min(count, 2))

    def sendall(self, data):
        self.sent += data


class FrameTests(unittest.TestCase):
    def test_fragmented_and_coalesced_frames(self):
        frame = struct.pack('<IBBH', 8, 1, 0, 17) + struct.pack('<I', 4)
        channel = FrameChannel(FragmentSocket(frame + frame))
        self.assertEqual(channel.receive(), (1, 17, struct.pack('<I', 4)))
        self.assertEqual(channel.receive(), (1, 17, struct.pack('<I', 4)))
        channel.send(0x82, 4, b'\0')
        self.assertEqual(channel.connection.sent, struct.pack('<IBBH', 5, 0x82, 0, 4) + b'\0')

    def test_invalid_frame_size_flags_and_truncation(self):
        for data in (struct.pack('<I', 3), struct.pack('<I', 65537),
                     struct.pack('<IBBH', 4, 1, 1, 0)):
            with self.assertRaises(ValueError):
                FrameChannel(FragmentSocket(data)).receive()
        with self.assertRaises(EOFError):
            FrameChannel(FragmentSocket(b'\1')).receive()


class NativeBridgeTests(unittest.TestCase):
    def setUp(self):
        cleanup_owner = getattr(self, 'cleanup_owner', self)
        self.temp = tempfile.TemporaryDirectory(prefix='g6lc-native-')
        cleanup_owner.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 's'
        self.process = subprocess.Popen(
            [sys.executable, '-B', str(HERE / 'vn_native_bridge.py'), '--sock', str(self.path),
             '--map', str(MAP), '--timeout', '5'] +
            (['--transfer-submit'] if getattr(self, 'transfer_submit', False) else []) +
            (['--compute-submit'] if getattr(self, 'compute_submit', False) else []),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.client = bridge_client.Client(bridge_client.Mem())
        cleanup_owner.addCleanup(self.stop)
        with selectors.DefaultSelector() as ready:
            ready.register(self.process.stdout, selectors.EVENT_READ)
            self.assertTrue(ready.select(3), 'native CLI did not become ready')
        label = ('COMPUTE-DEBUG' if getattr(self, 'compute_submit', False) else
                 'TRANSFER-DEBUG' if getattr(self, 'transfer_submit', False) else 'CONTROL-ONLY')
        ready_line = self.process.stdout.readline()
        self.assertIn(label + ' NATIVE BACKEND READY', ready_line)
        self.assertIn('Vulkan-capsets=0', ready_line)
        self.client.connect(str(self.path), tmo=3)
        original = self.client.pump
        self.client.pump = lambda dur=0: original(min(dur, 0.003))
        self.mem = self.client.mem
        self.config = geometry_from_map(MAP)
        self.desc = self.config['dma_base'] + 0x80000
        self.avail = self.desc + 0x1000
        self.used = self.desc + 0x2000
        self.request = self.desc + 0x4000
        self.response = self.desc + 0x5000
        self.index = 0
        self.configure()

    def stop(self):
        try:
            if self.client.s:
                self.client.s.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
                self.fail('native CLI failed to close after client disconnect')
            if self.process.returncode:
                self.fail('native CLI failed: ' + self.process.stderr.read())
        finally:
            self.process.stdout.close()
            self.process.stderr.close()

    def configure(self):
        c = self.client
        c.mmio_wr(0x70, 1)
        c.mmio_wr(0x70, 3)
        for selector in (0, 1):
            c.mmio_wr(0x14, selector)
            features = c.mmio_rd(0x10)
            c.mmio_wr(0x24, selector)
            c.mmio_wr(0x20, features)
        c.mmio_wr(0x70, 11)
        self.configure_queue()
        c.mmio_wr(0x70, 15)

    def configure_queue(self):
        c = self.client
        for register, value in ((0x30, 0), (0x38, 4), (0x80, self.desc),
                                (0x84, self.desc >> 32), (0x90, self.avail),
                                (0x94, self.avail >> 32), (0xA0, self.used),
                                (0xA4, self.used >> 32), (0x44, 1)):
            c.mmio_wr(register, value & 0xFFFFFFFF)

    def packet(self, command, body=b''):
        return HEADER.pack(command, 1, 0x123456789ABCDEF0, 1, 0) + body

    def submit(self, command, body=b''):
        payload = self.packet(command, body)
        self.mem.w(self.request, payload)
        self.mem.w(self.desc, struct.pack('<QIHH', self.request, len(payload), 1, 1))
        self.mem.w(self.desc + 16, struct.pack('<QIHH', self.response, 64, 2, 0))
        self.mem.w16(self.avail + 4 + 2 * (self.index % 4), 0)
        self.index += 1
        self.mem.w16(self.avail + 2, self.index)
        self.client.mmio_wr(0x50, 0)
        self.assertEqual(self.mem.r16(self.used + 2), self.index)
        self.assertEqual(self.client.mmio_rd(0x60), 1)
        self.client.mmio_wr(0x64, 1)
        return HEADER.unpack(self.mem.r(self.response, 24))[0]

    def enqueue(self, command, body=b'', *, head=0, alternate=False):
        request = self.request + (0x2000 if alternate else 0)
        response = self.response + (0x2000 if alternate else 0)
        payload = self.packet(command, body)
        self.mem.w(request, payload)
        self.mem.w(response, b'Z' * 64)
        self.mem.w(self.desc + 16 * head,
                   struct.pack('<QIHH', request, len(payload), 1, head + 1))
        self.mem.w(self.desc + 16 * (head + 1),
                   struct.pack('<QIHH', response, 64, 2, 0))
        self.mem.w16(self.avail + 4 + 2 * (self.index % 4), head)
        self.index += 1
        self.mem.w16(self.avail + 2, self.index)
        self.client.mmio_wr(0x50, 0)
        return response

    def wait_used(self, target):
        deadline = time.monotonic() + 3
        while self.mem.r16(self.used + 2) != target and time.monotonic() < deadline:
            self.client.pump(0.003)
        self.assertEqual(self.mem.r16(self.used + 2), target)

    def test_linear_wait_defers_reply_and_used_until_later_control_signal(self):
        wire = NativeWire()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'wait')),
                         RESP_NODATA)
        previous = self.index
        wait = wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        response = self.enqueue(SUBMIT_3D, struct.pack('<II', len(wait), 0) + wait)
        self.client.pump(0.003)
        self.assertEqual(self.mem.r16(self.used + 2), previous)
        self.assertEqual(self.mem.r(response, 64), b'Z' * 64)
        signal = wire.command('vkSubmitVirtqueueSeqnoMESA', ring=0, seqno=10)
        alternate = self.enqueue(SUBMIT_3D, struct.pack('<II', len(signal), 0) + signal,
                                 head=2, alternate=True)
        self.wait_used(self.index)
        self.assertEqual(HEADER.unpack(self.mem.r(response, 24))[0], RESP_NODATA)
        self.assertEqual(HEADER.unpack(self.mem.r(alternate, 24))[0], RESP_NODATA)
        self.assertEqual(self.mem.r32(self.used + 4 + 8 * (previous % 4)), 2)
        self.assertEqual(self.mem.r32(self.used + 4 + 8 * ((previous + 1) % 4)), 0)
        self.assertEqual(self.client.mmio_rd(0x10C), 0)

    def test_dependent_nested_streams_use_source_objects_and_separate_replies(self):
        wire = NativeWire()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'deps')),
                         RESP_NODATA)
        for resource, offset in ((7, 0), (9, 8192)):
            self.assertEqual(self.submit(
                CREATE_BLOB, struct.pack('<IIIIQQ', resource, 2, 1, 0, 0, 4096)), RESP_NODATA)
            self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', resource, 0, offset)),
                             RESP_MAP_INFO)
        destination = wire.command(
            'vkEnumeratePhysicalDevices', instance=wire.INSTANCE, pPhysicalDeviceCount=1,
            pPhysicalDevices=[wire.PHYSICAL])
        source = wire.command('vkCreateInstance', pInstance=wire.INSTANCE)
        base = self.config['shm_base']
        self.mem.w(base + 8192, destination)
        self.mem.w(base + 9216, source)
        command = wire.reply(7) + wire.command(
            'vkExecuteCommandStreamsMESA', streamCount=2,
            pStreams=[{'_ty': None, 'resourceId': 9, 'offset': offset, 'size': len(data)}
                      for offset, data in ((0, destination), (1024, source))],
            pReplyPositions=[0, 128], dependencyCount=1,
            pDependencies=[wire.structure('VkCommandStreamDependencyMESA',
                                           srcCommandStream=1, dstCommandStream=0)], flags=0)
        self.assertEqual(self.submit(SUBMIT_3D, struct.pack('<II', len(command), 0) + command),
                         RESP_NODATA)
        self.assertEqual(struct.unpack('<Q', self.mem.r(base + 144, 8))[0], wire.INSTANCE)
        self.assertIn(struct.pack('<Q', wire.PHYSICAL), self.mem.r(base, 64))
        self.assertEqual(self.submit(CTX_DESTROY), RESP_NODATA)
        self.assertEqual(self.client.mmio_rd(0x10C), 0)

    def test_context_destroy_cancels_pending_linear_control_before_id_reuse(self):
        wire = NativeWire()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'cancel')),
                         RESP_NODATA)
        wait = wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        response = self.enqueue(SUBMIT_3D, struct.pack('<II', len(wait), 0) + wait)
        self.enqueue(CTX_DESTROY, head=2, alternate=True)
        self.wait_used(self.index)
        self.assertEqual(HEADER.unpack(self.mem.r(response, 24))[0], ERR_CONTEXT)
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'reuse')),
                         RESP_NODATA)
        self.assertEqual(self.client.mmio_rd(0x10C), 0)

    def test_pending_nested_control_releases_source_on_device_or_queue_reset(self):
        wire = NativeWire()
        for full_reset in (False, True):
            with self.subTest(full_reset=full_reset):
                if full_reset:
                    self.client.mmio_wr(0x70, 0)
                    self.mem.w16(self.avail + 2, 0)
                    self.mem.w16(self.used + 2, 0)
                    self.index = 0
                    self.configure()
                self.assertEqual(self.submit(
                    CTX_CREATE, struct.pack('<II64s', 0, 4, b'nested-reset')), RESP_NODATA)
                self.assertEqual(self.submit(
                    CREATE_BLOB, struct.pack('<IIIIQQ', 9, 2, 1, 0, 0, 4096)), RESP_NODATA)
                self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 9, 0, 8192)),
                                 RESP_MAP_INFO)
                child = wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
                self.mem.w(self.config['shm_base'] + 8192, child)
                command = wire.command(
                    'vkExecuteCommandStreamsMESA', streamCount=1,
                    pStreams=[{'_ty': None, 'resourceId': 9, 'offset': 0, 'size': len(child)}],
                    pReplyPositions=None, dependencyCount=0, pDependencies=[], flags=0)
                before = self.index
                response = self.enqueue(SUBMIT_3D, struct.pack('<II', len(command), 0) + command)
                self.client.pump(0.003)
                self.assertEqual(self.mem.r16(self.used + 2), before)
                self.client.mmio_wr(0x70 if full_reset else 0xC0, 0 if full_reset else 1)
                self.assertEqual(self.mem.r(response, 64), b'Z' * 64)
                self.mem.w16(self.avail + 2, 0)
                self.mem.w16(self.used + 2, 0)
                self.index = 0
                if full_reset:
                    self.configure()
                    self.assertEqual(self.submit(
                        CTX_CREATE, struct.pack('<II64s', 0, 4, b'fresh')), RESP_NODATA)
                    self.assertEqual(self.submit(
                        CREATE_BLOB, struct.pack('<IIIIQQ', 9, 2, 1, 0, 0, 4096)), RESP_NODATA)
                else:
                    self.configure_queue()
                    self.assertEqual(self.submit(UNMAP_BLOB, struct.pack('<II', 9, 0)),
                                     RESP_NODATA)

    def test_real_client_context_blob_relocation_unmap_and_unref(self):
        self.assertEqual(self.client.mmio_rd(0), 0x74726976)
        self.assertEqual(self.client.mmio_rd(0x10C), 0)
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'native')),
                         RESP_NODATA)
        self.assertEqual(self.submit(CREATE_BLOB, struct.pack('<IIIIQQ', 7, 2, 1, 0, 0, 4096)),
                         RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 7, 0, 0)), RESP_MAP_INFO)
        self.mem.w(self.config['shm_base'], b'Native DMA')
        self.assertEqual(self.submit(UNMAP_BLOB, struct.pack('<II', 7, 0)), RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 7, 0, 4096)), RESP_MAP_INFO)
        self.assertEqual(self.mem.r(self.config['shm_base'] + 4096, 10), b'Native DMA')
        self.assertEqual(self.submit(CTX_DESTROY), RESP_NODATA)
        self.assertEqual(self.submit(RESOURCE_UNREF, struct.pack('<II', 7, 0)), RESP_NODATA)
        self.assertGreater(self.client.n_dma_rd, 0)
        self.assertGreater(self.client.n_dma_wr, 0)
        self.assertGreater(self.client.irq_edges, 0)

    def test_mmio_queued_while_dma_response_is_pending(self):
        original = self.client._on_frame
        inserted = []

        def callback(kind, sequence, data):
            if kind == 0x11 and not inserted:
                inserted.append(True)
                self.client.send(1, 60000, struct.pack('<I', 0))
            original(kind, sequence, data)

        self.client._on_frame = callback
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'')),
                         RESP_NODATA)
        deadline = time.monotonic() + 2
        while 60000 not in self.client.pending and time.monotonic() < deadline:
            self.client.pump(0.01)
        kind, data = self.client.pending.pop(60000)
        self.assertEqual((kind, struct.unpack('<IB', data)), (0x81, (0x74726976, 0)))

    def test_real_linear_venus_and_memory_backed_blob_lifetime(self):
        wire = NativeWire()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'linear')),
                         RESP_NODATA)
        self.assertEqual(self.submit(CREATE_BLOB, struct.pack('<IIIIQQ', 7, 2, 1, 0, 0, 4096)),
                         RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 7, 0, 0)), RESP_MAP_INFO)

        def execute(payload):
            self.assertEqual(self.submit(SUBMIT_3D, struct.pack('<II', len(payload), 0) + payload),
                             RESP_NODATA)

        execute(wire.boot())
        base = self.config['shm_base']
        self.assertEqual(struct.unpack('<Q', self.mem.r(base + 16, 8))[0], wire.INSTANCE)
        alias = struct.pack('<IIIIQQ', 8, 2, 1, 0, wire.MEMORY, 8192)
        self.assertEqual(self.submit(CREATE_BLOB, alias), RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 8, 0, 8192)), RESP_MAP_INFO)
        self.mem.w(base + 8192, b'mem-backed')
        self.assertEqual(self.submit(UNMAP_BLOB, struct.pack('<II', 8, 0)), RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 8, 0, 16384)), RESP_MAP_INFO)
        self.assertEqual(self.mem.r(base + 16384, 10), b'mem-backed')
        execute(wire.free())
        alias2 = struct.pack('<IIIIQQ', 9, 2, 1, 0, wire.MEMORY, 8192)
        self.assertEqual(self.submit(CREATE_BLOB, alias2), ERR_RESOURCE)
        self.assertEqual(self.submit(RESOURCE_UNREF, struct.pack('<II', 8, 0)), RESP_NODATA)
        self.assertEqual(self.submit(CREATE_BLOB, alias), ERR_RESOURCE)
        # Reusing the wire memory ID creates a new generation. Destroying its
        # context must not reclaim the exported backing before resource unref.
        execute(wire.allocate())
        self.assertEqual(self.submit(CREATE_BLOB, alias), RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 8, 0, 8192)), RESP_MAP_INFO)
        self.mem.w(base + 8192, b'old-context')
        self.assertEqual(self.submit(CTX_DESTROY), RESP_NODATA)
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'reused')),
                         RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 8, 0, 24576)), RESP_MAP_INFO)
        self.assertEqual(self.mem.r(base + 24576, 11), b'old-context')
        self.assertEqual(self.submit(RESOURCE_UNREF, struct.pack('<II', 8, 0)), RESP_NODATA)
        self.assertEqual(self.client.mmio_rd(0x10C), 0)

    def test_peer_dma_fault_sets_needs_reset_without_used_publication(self):
        original = self.client._on_frame

        def callback(kind, sequence, data):
            if kind == 0x11:
                self.client.send(0x91, sequence, b'\1')
            else:
                original(kind, sequence, data)

        self.client._on_frame = callback
        self.mem.w16(self.avail + 2, 1)
        self.client.mmio_wr(0x50, 0)
        self.assertTrue(self.client.mmio_rd(0x70) & 64)
        self.assertEqual(self.client.mmio_rd(0x60), 2)
        self.assertEqual(self.mem.r16(self.used + 2), 0)
        self.client.mmio_wr(0x70, 0)
        self.assertEqual(self.client.mmio_rd(0x70), 0)

    def test_ring_polls_without_mmio_and_context_destroy_cancels_wait(self):
        wire = NativeWire()
        boot = wire.boot()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'rings')),
                         RESP_NODATA)
        for resource, offset in ((7, 0), (8, 4096)):
            self.assertEqual(self.submit(
                CREATE_BLOB, struct.pack('<IIIIQQ', resource, 2, 1, 0, 0, 4096)), RESP_NODATA)
            self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', resource, 0, offset)),
                             RESP_MAP_INFO)
        command = wire.create_ring(idleTimeout=1000000000)
        self.assertEqual(self.submit(SUBMIT_3D, struct.pack('<II', len(command), 0) + command),
                         RESP_NODATA)
        base = self.config['shm_base']
        wait = wire.command('vkWaitVirtqueueSeqnoMESA', seqno=10)
        self.mem.w(base + 4096 + 192, boot + wait)
        self.mem.w32(base + 4096 + 64, len(boot + wait))
        deadline = time.monotonic() + 3
        # No MMIO is sent here. Pump only handles unsolicited peer DMA frames.
        while self.mem.r32(base + 4096) != len(boot) and time.monotonic() < deadline:
            self.client.pump(0.003)
        self.assertEqual(self.mem.r32(base + 4096), len(boot))
        self.assertEqual(struct.unpack('<Q', self.mem.r(base + 16, 8))[0], wire.INSTANCE)
        self.assertEqual(self.submit(CTX_DESTROY), RESP_NODATA)
        frozen = self.mem.r(base + 4096, 4096)
        self.client.pump(0.02)
        self.assertEqual(self.mem.r(base + 4096, 4096), frozen)
        self.assertEqual(self.submit(RESOURCE_UNREF, struct.pack('<II', 8, 0)), RESP_NODATA)
        self.assertEqual(self.client.mmio_rd(0x10C), 0)

    def test_full_device_reset_drains_its_ring_pins(self):
        wire = NativeWire()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'reset')),
                         RESP_NODATA)
        self.assertEqual(self.submit(
            CREATE_BLOB, struct.pack('<IIIIQQ', 8, 2, 1, 0, 0, 4096)), RESP_NODATA)
        self.assertEqual(self.submit(MAP_BLOB, struct.pack('<IIQ', 8, 0, 4096)), RESP_MAP_INFO)
        command = wire.create_ring(idleTimeout=1000000000)
        self.assertEqual(self.submit(SUBMIT_3D, struct.pack('<II', len(command), 0) + command),
                         RESP_NODATA)
        self.client.mmio_wr(0x70, 0)
        self.assertEqual(self.client.mmio_rd(0x70), 0)
        self.mem.w16(self.avail + 2, 0)
        self.mem.w16(self.used + 2, 0)
        self.index = 0
        self.configure()
        self.assertEqual(self.submit(CTX_CREATE, struct.pack('<II64s', 0, 4, b'fresh')),
                         RESP_NODATA)
        self.assertEqual(self.submit(
            CREATE_BLOB, struct.pack('<IIIIQQ', 8, 2, 1, 0, 0, 4096)), RESP_NODATA)

    def test_preexisting_socket_path_is_not_removed(self):
        sentinel = Path(self.temp.name) / 'owned'
        sentinel.write_text('preserve')
        result = subprocess.run(
            [sys.executable, '-B', str(HERE / 'vn_native_bridge.py'), '--sock', str(sentinel),
             '--map', str(MAP)], capture_output=True, text=True, timeout=3)
        self.assertEqual(result.returncode, 4)
        self.assertEqual(sentinel.read_text(), 'preserve')
