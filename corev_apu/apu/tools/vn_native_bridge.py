#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Experimental native backend for the existing local G6LC bridge IPC.

No TCP, Vulkan capset or stock-renderer/CTS-readiness claim. One client owns
one serialized session. Transfer and diagnostic compute need separate opt-ins.
Only the socket inode created here is removed.
"""
import argparse
from collections import deque
import os
from pathlib import Path
import re
import select
import socket
import struct
import sys
import time

from vn_native_device import NativeDevice


class FrameChannel:
    def __init__(self, connection, *, timeout=10, max_frame=65536):
        if timeout <= 0 or max_frame < 16:
            raise ValueError('invalid IPC limits')
        self.connection = connection
        self.timeout, self.max_frame = timeout, max_frame
        self.connection.settimeout(timeout)

    def _read(self, size, deadline):
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('bridge receive deadline exceeded')
            self.connection.settimeout(remaining)
            chunk = self.connection.recv(size - len(data))
            if not chunk:
                raise EOFError('bridge client disconnected')
            data.extend(chunk)
        return bytes(data)

    def receive(self, deadline=None):
        deadline = deadline if deadline is not None else time.monotonic() + self.timeout
        length = struct.unpack('<I', self._read(4, deadline))[0]
        if not 4 <= length <= self.max_frame:
            raise ValueError('invalid bridge frame length')
        data = self._read(length, deadline)
        kind, flags, sequence = struct.unpack_from('<BBH', data)
        if flags:
            raise ValueError('unsupported bridge frame flags')
        return kind, sequence, data[4:]

    def send(self, kind, sequence, payload):
        if len(payload) + 4 > self.max_frame:
            raise ValueError('bridge output exceeds frame budget')
        self.connection.settimeout(self.timeout)
        self.connection.sendall(struct.pack('<IBBH', 4 + len(payload), kind, 0, sequence) +
                                payload)


class BridgePeer:
    def __init__(self, channel):
        self.channel = channel
        self.pending = deque()
        self.sequence = 0

    def exchange(self, kind, payload, expected, size):
        self.sequence = self.sequence % 65535 + 1
        sequence = self.sequence
        self.channel.send(kind, sequence, payload)
        deadline = time.monotonic() + self.channel.timeout
        while True:
            frame = self.channel.receive(deadline)
            incoming, reply_sequence, data = frame
            if incoming in (1, 2):
                if len(self.pending) >= 64:
                    raise ValueError('too many MMIO frames during DMA')
                self.pending.append(frame)
                continue
            if incoming != expected or reply_sequence != sequence:
                raise ValueError('mismatched or stale DMA response')
            if not data or data[0]:
                raise OSError('peer reported a DMA fault')
            if len(data) != size + 1:
                raise ValueError('invalid DMA response size')
            return data[1:]

    def next_mmio(self):
        return self.pending.popleft() if self.pending else self.channel.receive()


class RemoteMemory:
    size_bytes = 1 << 64

    def __init__(self, peer):
        self.peer = peer

    def _check_range(self, address, size):
        if (type(address) is not int or type(size) is not int or
                address < 0 or size < 0 or address + size > self.size_bytes):
            raise ValueError('invalid remote DMA range')

    def read(self, address, size):
        self._check_range(address, size)
        result = bytearray()
        while size:
            count = min(4096, size)
            result.extend(self.peer.exchange(0x11, struct.pack('<QI', address, count),
                                             0x91, count))
            address, size = address + count, size - count
        return bytes(result)

    def write(self, address, data):
        data = memoryview(data).tobytes()
        self._check_range(address, len(data))
        for offset in range(0, len(data), 4096):
            part = data[offset:offset + 4096]
            strobes = bytearray([255] * ((len(part) + 7) // 8))
            if len(part) % 8:
                strobes[-1] = (1 << (len(part) % 8)) - 1
            payload = struct.pack('<QI', address + offset, len(part)) + part + strobes
            self.peer.exchange(0x12, payload, 0x92, 0)


def serve_connection(connection, geometry, *, timeout=10, legacy_used=False,
                     transfer_submit=False, compute_submit=False):
    channel = FrameChannel(connection, timeout=timeout)
    peer = BridgePeer(channel)
    device = NativeDevice(RemoteMemory(peer), legacy_used=legacy_used,
                          transfer_submit=transfer_submit, compute_submit=compute_submit, **geometry)
    last_irq = False
    try:
        while True:
            # Only wait/poll at frame boundaries. A partial MMIO frame retains
            # its original full receive deadline; DMA never reenters MMIO.
            ready = peer.pending or not device.ring_polling or select.select(
                [connection], [], [], 0.001)[0]
            if ready:
                try:
                    kind, sequence, data = peer.next_mmio()
                except EOFError:
                    return
                if kind not in (1, 2):
                    raise ValueError('expected MMIO bridge request')
                expected = 4 if kind == 1 else 9
                if len(data) != expected:
                    raise ValueError('invalid MMIO frame size')
                offset = struct.unpack_from('<I', data)[0]
                try:
                    if kind == 1:
                        response = struct.pack('<IB', device.read32(offset), 0)
                    else:
                        _, value, strobe = struct.unpack('<IIB', data)
                        device.write32(offset, value, strobe)
                        response = b'\0'
                except (ValueError, OSError):
                    response = struct.pack('<IB', 0, 1) if kind == 1 else b'\1'
                channel.send(kind | 0x80, sequence, response)
            device.poll_rings()
            if device.irq != last_irq:
                channel.send(0x13, 0, bytes([int(device.irq)]))
                last_irq = device.irq
    except EOFError:
        return
    finally:
        # Retire mapping pins without publishing head/status on a dead peer.
        device.execution.reset()


def geometry_from_map(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        match = re.fullmatch(r'#define (\w+) 0x([0-9A-Fa-f]+)ULL', line.strip())
        if match:
            values[match[1]] = int(match[2], 16)
    names = {'dma_base': 'VN_DMA_BASE', 'dma_bytes': 'VN_DMA_BYTES',
             'shm_base': 'VN_SHM_BASE', 'shm_bytes': 'VN_SHM_BYTES',
             'shm_guest_bytes': 'VN_SHM_GUEST_BYTES', 'queue_depth': 'VN_QUEUE_DEPTH',
             'shm_id': 'VN_SHM_ID'}
    return {key: values[value] for key, value in names.items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sock', required=True)
    parser.add_argument('--map', required=True, help='generated venus_map.h/bridge_map.h')
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--rtl-used-length', action='store_true')
    parser.add_argument('--transfer-submit', action='store_true',
                        help='opt-in host transfer queue submission; zero Vulkan capsets')
    parser.add_argument('--compute-submit', action='store_true',
                        help='diagnostic host compute; requires --transfer-submit; zero capsets')
    args = parser.parse_args()
    if args.compute_submit and not args.transfer_submit:
        parser.error('--compute-submit requires --transfer-submit')
    geometry = geometry_from_map(args.map)
    path = Path(args.sock)
    if args.timeout <= 0 or not path.parent.is_dir() or os.path.lexists(path):
        raise ValueError('socket path must be new; timeout must be positive')
    identity = None
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        try:
            listener.bind(str(path))
            stat = path.lstat()
            identity = (stat.st_dev, stat.st_ino)
            listener.listen(1)
            listener.settimeout(args.timeout)
            label = ('COMPUTE-DEBUG' if args.compute_submit else
                     'TRANSFER-DEBUG' if args.transfer_submit else 'CONTROL-ONLY')
            print(label + ' NATIVE BACKEND READY Vulkan-capsets=0', flush=True)
            connection, _ = listener.accept()
            with connection:
                serve_connection(connection, geometry, timeout=args.timeout,
                                 legacy_used=args.rtl_used_length,
                                 transfer_submit=args.transfer_submit,
                                 compute_submit=args.compute_submit)
        finally:
            if identity is not None and os.path.lexists(path):
                stat = path.lstat()
                if (stat.st_dev, stat.st_ino) == identity:
                    path.unlink()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, EOFError) as error:
        print('NATIVE BACKEND INCOMPLETE: ' + str(error), file=sys.stderr)
        sys.exit(4)
