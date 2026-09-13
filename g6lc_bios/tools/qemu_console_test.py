#!/usr/bin/env python3
# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import argparse
import json
import re
import socket
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from ppm2png import read_ppm, write_png


def canonical(text):
    return re.sub(r"(.)\1+", r"\1", text)


class Monitor:
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(10)
        self.socket.connect(str(path))
        self.stream = self.socket.makefile("rwb")
        if "QMP" not in json.loads(self.stream.readline()):
            raise RuntimeError("missing QMP greeting")
        self.sequence = 0
        self.call("qmp_capabilities")

    def call(self, command, **arguments):
        self.sequence += 1
        self.stream.write((json.dumps({"execute": command, "arguments": arguments, "id": self.sequence}) + "\n").encode())
        self.stream.flush()
        while True:
            line = self.stream.readline()
            if not line:
                raise RuntimeError("QMP disconnected")
            reply = json.loads(line)
            if reply.get("id") == self.sequence:
                if "error" in reply:
                    raise RuntimeError(reply["error"])
                return reply.get("return")

    def key(self, code):
        keys = [{"type": "qcode", "data": key} for key in code.split("+")]
        self.call("send-key", keys=keys, **{"hold-time": 40})
        time.sleep(0.09)

    def type(self, text):
        punctuation = {" ": "spc", "/": "slash", ".": "dot", "-": "minus", ":": "shift+semicolon", "_": "shift+minus"}
        for ch in text:
            if ch not in punctuation and not (ch.isascii() and ch.isalnum()):
                raise ValueError(f"unsupported test keystroke: {ch!r}")
            self.key(punctuation.get(ch, ch.lower()))
        self.key("ret")

    def capture(self, output):
        self.call("screendump", filename=str(output.with_suffix(".ppm")))
        w, h, pixels = read_ppm(output.with_suffix(".ppm"))
        if not any(pixels):
            raise RuntimeError("blank scanout")
        write_png(output.with_suffix(".png"), w, h, pixels)
        print(f"capture {output.name}: {w}x{h}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--disk", action="append", default=[])
    parser.add_argument("--command", action="append", default=[])
    parser.add_argument("--expect", action="append", default=[])
    parser.add_argument("--diagnose-keys", action="store_true")
    args = parser.parse_args()
    if args.expect and len(args.expect) != len(args.command):
        parser.error("one --expect is required per --command")
    if not args.elf.is_file() or any(not Path(disk).is_file() for disk in args.disk):
        raise RuntimeError("ELF or disk missing")
    args.out.mkdir(parents=True, exist_ok=True)
    raw = bytearray()
    with tempfile.TemporaryDirectory(prefix="g6b-console-") as scratch:
        qmp_path, serial_path = Path(scratch) / "qmp", Path(scratch) / "serial"
        argv = [args.qemu, "-S", "-machine", "virt", "-cpu", "rv64", "-m", "1024", "-smp", "2", "-display", "none", "-monitor", "none", "-global", "virtio-mmio.force-legacy=false", "-qmp", f"unix:{qmp_path},server=on,wait=off", "-serial", f"unix:{serial_path},server=on,wait=off", "-device", "virtio-gpu-device", "-device", "virtio-keyboard-device", "-kernel", str(args.elf.resolve())]
        for i, disk in enumerate(args.disk):
            argv += ["-drive", f"file={Path(disk).resolve()},format=raw,if=none,id=disk{i},readonly=on", "-device", f"virtio-blk-device,drive=disk{i}"]
        (args.out / "argv.json").write_text(json.dumps(argv, indent=2))
        with (args.out / "qemu.log").open("wb") as log:
            proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
            serial = None
            monitor = None
            reader = None
            try:
                deadline = time.monotonic() + 20
                while not qmp_path.exists() or not serial_path.exists():
                    if proc.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError("QEMU did not open its control sockets")
                    time.sleep(0.05)
                monitor = Monitor(qmp_path)
                serial = socket.socket(socket.AF_UNIX)
                serial.connect(str(serial_path))
                def drain():
                    while True:
                        try:
                            data = serial.recv(65536)
                        except OSError:
                            return
                        if not data:
                            return
                        if len(raw) + len(data) > 4 * 1024 * 1024:
                            return
                        raw.extend(data)
                reader = threading.Thread(target=drain, daemon=True)
                reader.start()
                monitor.call("cont")
                def wait(marker, start=0, follow=None):
                    deadline = time.monotonic() + 180
                    while True:
                        text = canonical(raw[start:].decode("latin1"))
                        at = text.find(canonical(marker))
                        if at >= 0 and (follow is None or canonical(follow) in text[at + len(canonical(marker)):]):
                            return
                        if proc.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError(f"missing guest marker sequence: {marker}, {follow}")
                        time.sleep(0.1)
                wait("AUTOBOOT-READY")
                wait("VIRTIO-PAINT")
                time.sleep(0.5)
                monitor.capture((args.out / "picker").resolve())
                if args.diagnose_keys:
                    start = len(raw)
                    serial.sendall(b"Keys\n")
                    time.sleep(1)
                    monitor.key("down")
                    time.sleep(0.5)
                    monitor.capture((args.out / "picker-after-keys").resolve())
                    print(raw[start:].decode("latin1"), flush=True)
                start = len(raw)
                monitor.key("esc")
                wait("AUTOBOOT-CANCEL", start, "VIRTIO-PAINT")
                monitor.capture((args.out / "prompt").resolve())
                for i, command in enumerate(args.command):
                    start = len(raw)
                    monitor.type(command)
                    wait(args.expect[i] if args.expect else "CLI-CMD", start, "VIRTIO-PAINT")
                    time.sleep(0.3)
                    if "CLI-CMD?" in canonical(raw[start:].decode("latin1")):
                        raise RuntimeError(f"guest did not implement command: {command}")
                    monitor.capture((args.out / f"command-{i}").resolve())
                text = canonical(raw.decode("latin1"))
                if re.search(r"^TRAP-[0-9a-fA-F]", text, re.MULTILINE):
                    raise RuntimeError("guest trap")
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                if serial:
                    serial.close()
                if reader:
                    reader.join(timeout=2)
                if monitor:
                    monitor.stream.close()
                    monitor.socket.close()
                (args.out / "serial.raw.log").write_bytes(raw)
                (args.out / "serial.log").write_text(canonical(raw.decode("latin1")), encoding="utf-8")


if __name__ == "__main__":
    main()
