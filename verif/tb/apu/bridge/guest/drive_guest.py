#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# drive_guest — boot a stock Ubuntu riscv64 cloud image on the g6lc
# QEMU machine against the verilated LibreCore APU bridge server and
# run the Venus acceptance programs in the guest.
#
#   drive_guest.py [--out DIR] [--venusoff] [--boot-only] [--timeout S]
#
# Paths (all overridable by env):
#   CVA6_REPO_DIR   repo root          (default: derived from __file__)
#   G6LC_QEMU       qemu binary        (default: $ROOT/g6lc_qemu/qemu/build/qemu-system-riscv64)
#   G6LC_QLIB       qemu -L dir        (default: $QEMU/../qemu-bundle/usr/local/share/qemu)
#   GUEST_CACHE     image/kernel/work  (default: $ROOT/.cache/apu-guest)
#   APU_BRIDGE_OUT  bridge obj dirs    (default: $GUEST_CACHE/bridge)
#   G6LC_SOCKDIR    unix-socket dir    (default: /tmp/g6lc-apu-sock —
#                                        DrvFs cannot bind unix sockets)
#   G6LC_SKIP_APT   skip apt install   (image must already carry the pkgs)
#
# The driver prints GUEST-PASS / GUEST-FAIL last and exits accordingly.
import argparse
import os
import re
import socket
import subprocess
import sys
import time

GUEST_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("CVA6_REPO_DIR") or os.path.abspath(
    os.path.join(GUEST_DIR, "..", "..", "..", "..", ".."))
QEMU = os.environ.get(
    "G6LC_QEMU",
    f"{ROOT}/g6lc_qemu/qemu/build/qemu-system-riscv64")
QLIB = os.environ.get(
    "G6LC_QLIB",
    f"{ROOT}/g6lc_qemu/qemu/build/qemu-bundle/usr/local/share/qemu")
CACHE = os.environ.get("GUEST_CACHE", f"{ROOT}/.cache/apu-guest")
BRIDGE_OUT = os.environ.get("APU_BRIDGE_OUT", f"{CACHE}/bridge")

IMG = f"{CACHE}/ubuntu-24.04.5-preinstalled-server-riscv64.img"
CIDATA = f"{CACHE}/cidata.img"
KERNEL = f"{CACHE}/vmlinuz"
SWAP = f"{CACHE}/swap.raw"
SOCKDIR = os.environ.get("G6LC_SOCKDIR", "/tmp/g6lc-apu-sock")
SOCK = f"{SOCKDIR}/rtl.sock"
CONSOLE = f"{SOCKDIR}/console.sock"
MON = f"{SOCKDIR}/monitor.sock"


class Serial:
    def __init__(self, path, log):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(200):
            try:
                self.sock.connect(path)
                break
            except OSError:
                time.sleep(0.25)
        else:
            raise RuntimeError("console socket never appeared")
        self.sock.settimeout(0.5)
        self.buf = b""
        self.log = log

    def _pump(self):
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return False
        if not data:
            return False
        self.buf += data
        self.log.write(data)
        self.log.flush()
        sys.stdout.write(data.decode("utf-8", "replace"))
        sys.stdout.flush()
        return True

    def send(self, s):
        self.sock.sendall(s.encode())

    def expect(self, pattern, timeout):
        rx = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        end = time.time() + timeout
        while time.time() < end:
            m = rx.search(self.buf)
            if m:
                return m
            self._pump()
        return None

    def run(self, cmd, timeout=120):
        """Run cmd, wait for 'G6LC_DONE_<rc>' marker; return rc."""
        tag = f"G6LC_DONE_{int(time.time()*1000) % 1000000}"
        self.buf = b""
        self.send(f"{cmd}; echo {tag}_$?\n")
        m = self.expect(rf"{tag}_(\d+)", timeout)
        if not m:
            return None
        return int(m.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--venusoff", action="store_true")
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--out", default=CACHE)
    ap.add_argument("--boot-only", action="store_true")
    args = ap.parse_args()

    mode = "venusoff" if args.venusoff else "venus"
    os.makedirs(args.out, exist_ok=True)
    serial_log = open(f"{args.out}/serial-{mode}.log", "wb")
    objdir = "obj_venusoff" if args.venusoff else "obj_venus"
    server_bin = f"{BRIDGE_OUT}/{objdir}/apu_bridge"
    if not os.path.exists(server_bin):
        print(f"FATAL: bridge server {server_bin} missing — run "
              f"APU_BRIDGE_OUT={BRIDGE_OUT} verif/tb/apu/bridge/build-bridge.sh")
        return 2
    for f in (IMG, CIDATA, KERNEL, SWAP):
        if not os.path.exists(f):
            print(f"FATAL: {f} missing — run run-guest.sh (provisioning)")
            return 2
    server_log = open(f"{args.out}/server-run-{mode}.log", "wb")

    for p in (SOCK, CONSOLE, MON):
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass

    t0 = time.time()
    os.makedirs(SOCKDIR, exist_ok=True)
    server = subprocess.Popen([server_bin, "--stats", "--sock", SOCK],
                              stdout=server_log, stderr=server_log)
    for _ in range(200):
        if os.path.exists(SOCK):
            break
        if server.poll() is not None:
            print("FATAL: bridge server exited early")
            return 2
        time.sleep(0.25)

    env = dict(os.environ, G6LC_APU_RTL_SOCK=SOCK)
    qemu_cmd = [
        QEMU, "-L", QLIB,
        "-machine", "g6lc-g6lc64_stream8",
        "-cpu", "g6lc-g6lc64_stream8",
        "-m", "512",
        "-smp", "2",
        "-bios", "default",
        "-kernel", KERNEL,
        # No -initrd: the g6lc machine hardcodes dram_size=256 MiB and
        # loads the kernel above the 32 MiB aperture hole, so a 75 MiB
        # initrd cannot fit before the DTB ("No enough memory to place
        # DTB after kernel/initrd").  virtio_blk/virtio_mmio/ext4 are
        # built-in (config-7.0.0-31: =y), so the rootfs mounts direct.
        "-append", "root=PARTUUID=362560d2-8002-4ede-a939-37232b94afa1 "
                    "rw console=ttyS0 "
                    "systemd.unit=multi-user.target "
                    "systemd.mask=systemd-resolved.service "
                    "systemd.mask=systemd-networkd-wait-online.service "
                    # 224 MiB usable RAM post-aperture: keep cloud-init
                    # (sets the ubuntu password) but shed the heavy
                    # nonessential units that OOM the boot.
                    "systemd.mask=apport.service "
                    "systemd.mask=ModemManager.service "
                    "systemd.mask=snapd.service "
                    "systemd.mask=snapd.seeded.service "
                    "systemd.mask=snapd.socket "
                    "systemd.mask=lxd-installer.socket "
                    "systemd.mask=unattended-upgrades.service "
                    "systemd.mask=e2scrub_all.service "
                    "systemd.mask=e2scrub_reap.service "
                    "systemd.mask=man-db.timer "
                    "systemd.mask=apt-daily.timer "
                    "systemd.mask=apt-daily-upgrade.timer "
                    "systemd.mask=motd-news.timer "
                    "systemd.mask=ua-timer.timer "
                    "systemd.mask=ua-auto-attach.service "
                    "systemd.mask=dpkg-db-backup.service "
                    "systemd.mask=logrotate.service "
                    "systemd.mask=sysstat.service "
                    "systemd.mask=wpa_supplicant.service",
        "-drive", f"file={IMG},format=raw,if=none,id=hd0,cache=unsafe",
        "-device", "virtio-blk-device,drive=hd0",
        "-drive", f"file={CIDATA},format=raw,if=none,id=cd0,readonly=on",
        "-device", "virtio-blk-device,drive=cd0",
        "-drive", f"file={SWAP},format=raw,if=none,id=sw0,cache=writeback",
        "-device", "virtio-blk-device,drive=sw0",
        "-netdev", "user,id=n0",
        "-device", "virtio-net-device,netdev=n0",
        "-device", "virtio-rng-device",
        "-display", "none",
        "-serial", f"unix:{CONSOLE},server,nowait",
        "-monitor", f"unix:{MON},server,nowait",
    ]
    qemu_log = open(f"{args.out}/qemu-stderr-{mode}.log", "wb")
    qemu = subprocess.Popen(qemu_cmd, env=env, stdout=qemu_log, stderr=qemu_log)

    fail = False
    try:
        con = Serial(CONSOLE, serial_log)
        print(f"[drive] console connected at +{time.time()-t0:.1f}s", flush=True)

        # wait for login prompt or shell
        m = con.expect(r"login:|\$ $|# ", args.timeout)
        if not m:
            print("[drive] TIMEOUT waiting for login", flush=True)
            return 3
        print(f"[drive] login prompt at +{time.time()-t0:.1f}s", flush=True)

        con.send("ubuntu\n")
        m = con.expect(r"Password:", 60)
        if m:
            con.send("ubuntu\n")
        m = con.expect(r"ubuntu@g6lc", 120)
        if not m:
            print("[drive] login failed", flush=True)
            return 4
        print(f"[drive] logged in at +{time.time()-t0:.1f}s", flush=True)
        print(f"BOOT_WALL_SECONDS={time.time()-t0:.1f}", flush=True)

        con.send("sudo -i\n")
        con.expect(r"root@g6lc", 30)

        # systemd-resolved is masked (crash-loops under TCG); give the
        # guest a direct nameserver on the user-mode net.
        con.run("rm -f /etc/resolv.conf && "
                "printf 'nameserver 10.0.2.3\\n' > /etc/resolv.conf && "
                "ip -o -4 addr show scope global | awk '{print $2,$4}'",
                timeout=60)
        con.run("ping -c1 -W10 10.0.2.3 && ping -c1 -W10 ports.ubuntu.com",
                timeout=90)

        # 256 MiB DRAM OOMs during apt — a dedicated virtio-blk swap
        # device (whole disk, no fs indirection).  Find it by size:
        # 768 MiB == 1572864 512B sectors.
        con.run("for d in /sys/block/vd*; do "
                "  if [ \"$(cat $d/size)\" = 1572864 ]; then "
                "    mkswap /dev/${d##*/} && swapon /dev/${d##*/}; "
                "  fi; done; free -m", timeout=300)

        # grow the rootfs into the expanded image + drop stale swapfile
        con.run("rootdev=$(findmnt -n -o SOURCE /); "
                "rootdisk=/dev/$(basename $(readlink -f /sys/class/block/${rootdev##*/}/..)); "
                "growpart $rootdisk ${rootdev##*[a-z]} && resize2fs $rootdev; "
                "swapoff /swapfile 2>/dev/null; rm -f /swapfile; apt-get clean; df -h /",
                timeout=300)

        if args.boot_only:
            print("GUEST-PASS (boot-only)", flush=True)
            return 0

        t_apt0 = time.time()
        if os.environ.get("G6LC_SKIP_APT"):
            print("[drive] G6LC_SKIP_APT: skipping apt update/install",
                  flush=True)
        else:
            rc = con.run("apt-get update -o Acquire::Retries=3", timeout=1800)
            print(f"[drive] apt update rc={rc} (+{time.time()-t_apt0:.0f}s)",
                  flush=True)
            rc = con.run("DEBIAN_FRONTEND=noninteractive apt-get install -y "
                         "mesa-vulkan-drivers vulkan-tools", timeout=2400)
            print(f"[drive] apt install rc={rc} (+{time.time()-t_apt0:.0f}s total)",
                  flush=True)
        print(f"APT_WALL_SECONDS={time.time()-t_apt0:.1f}", flush=True)

        con.run("dmesg | grep -i -E 'virtio|gpu' | tail -40", timeout=60)
        con.run("ls -la /dev/dri/ 2>&1; "
                "cat /sys/class/drm/renderD*/device/uevent 2>/dev/null",
                timeout=30)
        con.run("dpkg -l | grep -E 'mesa|vulkan|linux-image'", timeout=60)

        t_vk = time.time()
        con.run("vulkaninfo --summary 2>&1 | tee /root/vulkaninfo-summary.txt | tail -60",
                timeout=300)
        print(f"VULKANINFO_WALL_SECONDS={time.time()-t_vk:.1f}", flush=True)

        # pull cidata files into rootfs — find the seed by fs label;
        # virtio-blk enumeration order varies between runs
        con.run("mkdir -p /mnt/cidata && "
                "cdev=$(blkid -t LABEL=CIDATA -o device | head -1); "
                "for d in $cdev /dev/vda /dev/vdb /dev/vda1 /dev/vdb1; do "
                "  [ -n \"$d\" ] && mount -o ro $d /mnt/cidata 2>/dev/null && break; "
                "done; "
                "cp /mnt/cidata/vkcompute.c /mnt/cidata/vkdescarr.c "
                "/mnt/cidata/vkmem.c "
                "/mnt/cidata/bufcopy.spv /mnt/cidata/descarr.spv "
                "/mnt/cidata/expected.json /root/ && ls -la /root/",
                timeout=60)

        if args.venusoff:
            # control: no Venus GPU may appear — llvmpipe only.
            rc = con.run("vulkaninfo --summary 2>&1 | grep -c -i venus",
                         timeout=300)
            ok = (rc == 1)  # grep -c exits 1 when the count is 0
            print(f"[drive] venusoff: venus device absent -> "
                  f"{'PASS' if ok else 'FAIL'}", flush=True)
            fail |= not ok
        else:
            if os.environ.get("G6LC_SKIP_APT"):
                print("[drive] G6LC_SKIP_APT: skipping apt install2",
                      flush=True)
            else:
                rc = con.run("DEBIAN_FRONTEND=noninteractive apt-get install -y "
                             "build-essential libvulkan-dev", timeout=1800)
                print(f"[drive] apt install2 rc={rc}", flush=True)

            rc = con.run("cd /root && gcc -O2 -o vkcompute vkcompute.c -lvulkan "
                         "&& ./vkcompute bufcopy.spv", timeout=1200)
            print(f"[drive] vkcompute rc={rc}", flush=True)
            fail |= (rc != 0)
            rc = con.run("cd /root && gcc -O2 -o vkdescarr vkdescarr.c -lvulkan "
                         "&& ./vkdescarr descarr.spv", timeout=1200)
            print(f"[drive] vkdescarr rc={rc}", flush=True)
            fail |= (rc != 0)
            rc = con.run("cd /root && gcc -O2 -o vkmem vkmem.c -lvulkan "
                         "&& ./vkmem", timeout=1200)
            print(f"[drive] vkmem rc={rc}", flush=True)
            fail |= (rc != 0)

        # post-mortem: dump the whole aperture window from QEMU RAM
        try:
            mon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            mon.settimeout(10)
            mon.connect(MON)
            time.sleep(0.3)
            try:
                mon.recv(65536)
            except socket.timeout:
                pass
            mon.sendall(f"pmemsave 0x82000000 33554432 "
                        f"{args.out}/ap-dump-{mode}.bin\n".encode())
            time.sleep(3)
            try:
                print(f"[drive] monitor: {mon.recv(65536)!r}", flush=True)
            except socket.timeout:
                pass
            mon.close()
            print("[drive] aperture dump saved", flush=True)
        except OSError as e:
            print(f"[drive] monitor dump failed: {e}", flush=True)

        con.run("poweroff -f", timeout=120)
        con.expect(r"reboot|Power down|System halted", 60)
        print(f"GUEST-{'FAIL' if fail else 'PASS'}", flush=True)
        return 1 if fail else 0
    finally:
        for p in (qemu, server):
            try:
                p.terminate()
            except OSError:
                pass
        try:
            qemu.wait(timeout=20)
        except subprocess.TimeoutExpired:
            qemu.kill()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
        serial_log.close()
        server_log.close()
        qemu_log.close()


if __name__ == "__main__":
    sys.exit(main())
