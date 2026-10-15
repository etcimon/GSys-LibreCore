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
CTS_CACHE = os.environ.get("G6LC_CTS_CACHE", f"{ROOT}/.cache/cts")
CTSDATA = os.environ.get("G6LC_CTSDATA", f"{CTS_CACHE}/ctsdata.img")
# Usable guest RAM in MiB.  The machine's low bank always supplies
# 224 MiB (256 MiB DRAM minus the 32 MiB APU aperture); -m above that
# adds a second bank at 0xa0000000 and needs the matching DTB (see
# g6lc-g6lc64_stream8.dts).  224 keeps the legacy embedded-DTB map.
GUEST_MEM_MIB = int(os.environ.get("G6LC_GUEST_MEM", "224"))
DRAM2_BASE = 0xA0000000
LOW_USABLE_MIB = 224
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
    required = [IMG, CIDATA, KERNEL]
    if not os.environ.get("G6LC_CTS"):
        required.append(SWAP)
    for f in required:
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
    # -m N = N MiB usable guest RAM; >224 MiB instantiates the second
    # bank in the machine and needs the extended DTB (memory@a0000000).
    dtb_arg = []
    if GUEST_MEM_MIB > LOW_USABLE_MIB:
        dram2_bytes = (GUEST_MEM_MIB - LOW_USABLE_MIB) << 20
        dts = open(f"{GUEST_DIR}/g6lc-g6lc64_stream8.dts").read()
        dtb = f"{CACHE}/g6lc-mem{GUEST_MEM_MIB}.dtb"
        stamp = f"{CACHE}/g6lc-mem{GUEST_MEM_MIB}.dts"
        if not os.path.exists(dtb):
            open(stamp, "w").write(
                dts.replace("@DRAM2_SIZE@", f"0x{dram2_bytes:x}"))
            subprocess.run(["dtc", "-I", "dts", "-O", "dtb",
                            "-o", dtb, stamp], check=True)
        dtb_arg = ["-dtb", dtb]
        print(f"[drive] guest RAM {GUEST_MEM_MIB} MiB usable "
              f"(+{dram2_bytes >> 20} MiB bank at 0x{DRAM2_BASE:x})",
              flush=True)
    qemu_cmd = [
        QEMU, "-L", QLIB,
        "-machine", "g6lc-g6lc64_stream8",
        "-cpu", "g6lc-g6lc64_stream8",
        "-m", str(GUEST_MEM_MIB),
        "-smp", "2",
        "-bios", "default",
        "-kernel", KERNEL,
        *dtb_arg,
        # No -initrd: the g6lc machine loads the kernel above the
        # 32 MiB aperture hole, so a 75 MiB initrd cannot fit before
        # the DTB ("No enough memory to place DTB after kernel/
        # initrd").  virtio_blk/virtio_mmio/ext4 are
        # built-in (config-7.0.0-31: =y), so the rootfs mounts direct.
        "-append", "root=PARTUUID=362560d2-8002-4ede-a939-37232b94afa1 "
                    "rw console=ttyS0 "
                    "systemd.unit=multi-user.target "
                    "systemd.mask=systemd-resolved.service "
                    "systemd.mask=systemd-networkd-wait-online.service "
                    # Low-RAM guests (224 MiB usable post-aperture)
                    # need cloud-init (sets the ubuntu password) but
                    # shed the heavy nonessential units that OOM the
                    # boot; harmless at higher -m.
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
    ]
    # Swap exists to keep 224 MiB guests alive during apt; CTS runs at
    # >=2 GiB must not depend on it.
    swap_attached = not os.environ.get("G6LC_CTS")
    if swap_attached:
        qemu_cmd += [
            "-drive", f"file={SWAP},format=raw,if=none,id=sw0,"
                      "cache=writeback",
            "-device", "virtio-blk-device,drive=sw0",
        ]
    if os.environ.get("G6LC_CTS"):
        # CTS-0: deqp-vk + data + caselist on an ext4 image; mounted rw
        # in the guest so results are written back to it, then pulled
        # host-side with debugfs after QEMU exits.
        qemu_cmd += [
            "-drive", f"file={CTSDATA},format=raw,if=none,id=cts0,"
                      "cache=unsafe",
            "-device", "virtio-blk-device,drive=cts0",
        ]
    qemu_cmd += [
        "-netdev", "user,id=n0",
        "-device", "virtio-net-device,netdev=n0",
        "-device", "virtio-rng-device",
        "-display", "none",
        "-serial", f"unix:{CONSOLE},server,nowait",
        "-monitor", f"unix:{MON},server,nowait",
    ]
    qemu_cmd += os.environ.get("G6LC_QEMU_EXTRA", "").split()
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

        # Gate login on cloud-init completion — the ubuntu password is
        # committed in modules:config, which can land tens of seconds
        # after the login prompt appears.
        m = con.expect(r"cloud-init.*finished|Finished cloud-final", 900)
        if m:
            print(f"[drive] cloud-init finished at +{time.time()-t0:.1f}s",
                  flush=True)
        else:
            print("[drive] cloud-init completion not seen", flush=True)

        # Preinstalled images ship ubuntu with lastchg=0 (PAM-forced
        # change on first login) and cloud-init finishes the user setup
        # (password unlock) late — a fast boot can reach the login prompt
        # before either lands.  bootcmd in user-data pre-empts the
        # forced change; the loop below also answers the prompts if it
        # fires anyway, and retries while cloud-init is still running.
        login_ok = False
        # The rw image persists a forced password change made by the
        # other arm — alternate the candidate across attempts.
        passwords = ("ubuntu\n", "G6lcGuest-2026\n")
        for _attempt in range(6):
            con.buf = b""
            con.send("ubuntu\n")
            m = con.expect(r"Password:", 60)
            if m:
                con.send(passwords[_attempt % len(passwords)])
            m = con.expect(r"ubuntu@|Current password:|Login incorrect", 120)
            g = m.group(0) if m else b""
            if b"ubuntu@" in g:
                login_ok = True
                break
            if b"Current password" in g:
                con.send("ubuntu\n")
                con.expect(r"New password:", 30)
                con.send("G6lcGuest-2026\n")
                con.expect(r"Retype new password:", 30)
                con.send("G6lcGuest-2026\n")
                m = con.expect(r"ubuntu@", 60)
                login_ok = bool(m)
                break
            time.sleep(15)  # Login incorrect — cloud-init still setting up
        if not login_ok:
            print("[drive] login failed", flush=True)
            return 4
        print(f"[drive] logged in at +{time.time()-t0:.1f}s", flush=True)
        print(f"BOOT_WALL_SECONDS={time.time()-t0:.1f}", flush=True)

        # sudo -i: NOPASSWD on cloud images, but answer a password prompt
        # if one appears.  con.expect searches the accumulated console
        # buffer, so buf is cleared before each expect — otherwise a
        # stale "password for ubuntu" re-matches instantly and stray
        # sends land at the shell (typed text executes as commands).
        con.send("sudo -i\n")
        con.buf = b""
        m = con.expect(r"root@|password for ubuntu", 30)
        if m and b"password" in m.group(0):
            con.send("ubuntu\n")
            con.buf = b""
            m = con.expect(r"root@|try again", 30)
            if m and b"try again" in m.group(0):
                con.send("G6lcGuest-2026\n")
                con.buf = b""
                m = con.expect(r"root@", 30)

        # systemd-resolved is masked (crash-loops under TCG); give the
        # guest a direct nameserver on the user-mode net.
        con.run("rm -f /etc/resolv.conf && "
                "printf 'nameserver 10.0.2.3\\n' > /etc/resolv.conf && "
                "ip -o -4 addr show scope global | awk '{print $2,$4}'",
                timeout=60)
        con.run("ping -c1 -W10 10.0.2.3 && ping -c1 -W10 ports.ubuntu.com",
                timeout=90)

        # Low-DRAM guests OOM during apt — a dedicated virtio-blk swap
        # device (whole disk, no fs indirection).  Find it by size:
        # 768 MiB == 1572864 512B sectors.  bootcmd in user-data already
        # swapon'd it on later seeds; only mkswap when it is not active
        # yet (mkswap on a live swap would rewrite its signature).
        # Skipped when the swap disk was not attached (CTS).
        if swap_attached:
            con.run("swapon --show | grep -q . || "
                    "for d in /sys/block/vd*; do "
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
            print("\nGUEST-PASS (boot-only)", flush=True)
            return 0

        # If the virtio_gpu probe died early (ENOMEM under boot memory
        # pressure leaves no /dev/dri node), re-bind the virtio device
        # with id 0x0010 once and re-check.  The tests run either way —
        # a still-missing node fails downstream exactly as before.
        rc = con.run("ls /dev/dri/card* >/dev/null 2>&1", timeout=15)
        if rc == 0:
            print("[drive] virtio_gpu rebind: present", flush=True)
        else:
            con.run("for v in /sys/bus/virtio/devices/virtio*; do "
                    "grep -q '^0x0010$' $v/device 2>/dev/null && "
                    "echo ${v##*/} > /sys/bus/virtio/drivers/virtio_gpu/bind; "
                    "done; sleep 2; ls -l /dev/dri 2>&1; "
                    "dmesg | grep -i virtio_gpu | tail -5", timeout=60)
            rc = con.run("ls /dev/dri/card* >/dev/null 2>&1", timeout=15)
            print(f"[drive] virtio_gpu rebind: "
                  f"{'rebound' if rc == 0 else 'still-missing'}", flush=True)

        t_apt0 = time.time()
        if os.environ.get("G6LC_SKIP_APT"):
            print("[drive] G6LC_SKIP_APT: skipping apt update/install",
                  flush=True)
        else:
            rc = con.run("apt-get update -o Acquire::Retries=3", timeout=1800)
            print(f"[drive] apt update rc={rc} (+{time.time()-t_apt0:.0f}s)",
                  flush=True)
            rc = con.run("DEBIAN_FRONTEND=noninteractive apt-get install -y "
                         "mesa-vulkan-drivers vulkan-tools", timeout=4800)
            print(f"[drive] apt install rc={rc} (+{time.time()-t_apt0:.0f}s total)",
                  flush=True)
        print(f"APT_WALL_SECONDS={time.time()-t_apt0:.1f}", flush=True)

        con.run("dmesg | grep -i -E 'virtio|gpu' | tail -40", timeout=60)
        con.run("ls -la /dev/dri/ 2>&1; "
                "cat /sys/class/drm/renderD*/device/uevent 2>/dev/null",
                timeout=30)
        con.run("dpkg -l | grep -E 'mesa|vulkan|linux-image'", timeout=60)

        # G6LC_ONLY: comma-separated test subset (debug repro aid).
        # Also gates the vulkaninfo probe so focused runs skip its
        # ~10-minute enumeration on the debug bridge.
        only = {t.strip() for t in
                os.environ.get("G6LC_ONLY", "").split(",") if t.strip()}
        if not only or "vulkaninfo" in only:
            t_vk = time.time()
            con.run("vulkaninfo --summary 2>&1 | tee /root/vulkaninfo-summary.txt | tail -60",
                    timeout=900)
            print(f"VULKANINFO_WALL_SECONDS={time.time()-t_vk:.1f}", flush=True)

        # pull cidata files into rootfs — find the seed by fs label;
        # virtio-blk enumeration order varies between runs
        con.run("mkdir -p /mnt/cidata && "
                "cdev=$(blkid -t LABEL=CIDATA -o device | head -1); "
                "for d in $cdev /dev/vda /dev/vdb /dev/vda1 /dev/vdb1; do "
                "  [ -n \"$d\" ] && mount -o ro $d /mnt/cidata 2>/dev/null && break; "
                "done; "
                "cp /mnt/cidata/vkcompute.c /mnt/cidata/vkdescarr.c "
                "/mnt/cidata/vkmem.c /mnt/cidata/vkimage.c "
                "/mnt/cidata/vktri.c /mnt/cidata/vkcmp.c /mnt/cidata/vkping.c "
                "/mnt/cidata/bufcopy.spv /mnt/cidata/descarr.spv "
                "/mnt/cidata/vkimage.spv "
                "/mnt/cidata/vs_passthru.spv /mnt/cidata/fs_color.spv "
                "/mnt/cidata/vs_pc.spv /mnt/cidata/fs_vcol.spv "
                "/mnt/cidata/vs_pos3.spv /mnt/cidata/vs_inst.spv "
                "/mnt/cidata/vs_tex.spv /mnt/cidata/fs_mip.spv "
                "/mnt/cidata/vs_clip.spv /mnt/cidata/vs_uvc.spv "
                "/mnt/cidata/fs_deriv2.spv /mnt/cidata/fs_scene8.spv "
                "/mnt/cidata/vs_shadowfog.spv /mnt/cidata/fs_shadowfog.spv "
                "/mnt/cidata/expected.json /root/ && ls -la /root/",
                timeout=60)

        if args.venusoff:
            # control: no Venus GPU may appear — llvmpipe only.
            rc = con.run("vulkaninfo --summary 2>&1 | grep -c -i venus",
                         timeout=900)
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

            if not only or "vkcompute" in only:
                rc = con.run("cd /root && gcc -O2 -o vkcompute vkcompute.c "
                             "-lvulkan && ./vkcompute bufcopy.spv",
                             timeout=1200)
                print(f"[drive] vkcompute rc={rc}", flush=True)
                fail |= (rc != 0)
            if not only or "vkdescarr" in only:
                rc = con.run("cd /root && gcc -O2 -o vkdescarr vkdescarr.c "
                             "-lvulkan && ./vkdescarr descarr.spv",
                             timeout=1200)
                print(f"[drive] vkdescarr rc={rc}", flush=True)
                fail |= (rc != 0)
            if not only or "vkmem" in only:
                rc = con.run("cd /root && gcc -O2 -o vkmem vkmem.c -lvulkan "
                             "&& ./vkmem bufcopy.spv", timeout=1200)
                print(f"[drive] vkmem rc={rc}", flush=True)
                fail |= (rc != 0)
            # §12.3 C/5b: images + samplers + Xfer image copies on the
            # stock path (textureLod bilinear edge/repeat into an
            # rgba32f storage image, CopyImageToBuffer readback).
            if not only or "vkimage" in only:
                if os.environ.get("G6LC_WEDGE_DUMP"):
                    # wedge forensics: run vkimage in background; if it
                    # outlives the watchdog, dump every thread's kernel
                    # stack + ps wchan + sysrq-w before killing it.
                    rc = con.run(
                        "cd /root && gcc -O2 -o vkimage vkimage.c "
                        "-lvulkan -lm && "
                        "( ./vkimage vkimage.spv & p=$!; n=0; "
                        "while kill -0 $p 2>/dev/null && [ $n -lt 60 ]; "
                        "do sleep 5; n=$((n+1)); done; "
                        "if kill -0 $p 2>/dev/null; then "
                        "echo ===WEDGE-DUMP===; "
                        "head -6 /proc/$p/status; "
                        "for t in /proc/$p/task/*/stack; do "
                        "echo -- $t; cat $t; done; "
                        "ps -e -o pid,comm,stat,wchan:40 | head -30; "
                        "echo w > /proc/sysrq-trigger; sleep 1; "
                        "dmesg | tail -50; "
                        "kill -9 $p; exit 99; "
                        "else wait $p; exit $?; fi )",
                        timeout=1200)
                else:
                    rc = con.run("cd /root && gcc -O2 -o vkimage vkimage.c "
                                 "-lvulkan -lm && ./vkimage vkimage.spv",
                                 timeout=1200)
                print(f"[drive] vkimage rc={rc}", flush=True)
                fail |= (rc != 0)
            # wedge forensics: vkping loops the full per-process
            # instance/device/ring/blob lifecycle; a stall detector
            # dumps the wedged process's kernel stacks when an
            # iteration stops producing output.
            if only and "vkloop" in only:
                rc = con.run(
                    "cd /root && gcc -O2 -o vkping vkping.c -lvulkan || "
                    "exit 2; : > /tmp/vkping.log; "
                    "( for i in $(seq 1 40); do ./vkping $i || exit 1; "
                    "done > /tmp/vkping.log 2>&1 ) & L=$!; "
                    "n=0; c=0; "
                    "while kill -0 $L 2>/dev/null && [ $n -lt 240 ]; do "
                    "sleep 5; n=$((n+1)); "
                    "c2=$(wc -l < /tmp/vkping.log); "
                    "if [ \"$c2\" != \"$c\" ]; then c=$c2; n=0; fi; "
                    "if [ $n -ge 12 ]; then break; fi; done; "
                    "if kill -0 $L 2>/dev/null; then "
                    "echo ===WEDGE-DUMP===; "
                    "tail -5 /tmp/vkping.log; "
                    "pgrep -a vkping; P=$(pgrep -n vkping); "
                    "head -6 /proc/$P/status; "
                    "for t in /proc/$P/task/*/stack; do "
                    "echo -- $t; cat $t; done; "
                    "ps -e -o pid,comm,stat,wchan:40 | head -30; "
                    "echo w > /proc/sysrq-trigger; sleep 1; "
                    "dmesg | tail -60; "
                    "kill -9 $L $(pgrep vkping) 2>/dev/null; exit 99; "
                    "else cat /tmp/vkping.log | tail -5; wait $L; "
                    "exit $?; fi",
                    timeout=1500)
                print(f"[drive] vkloop rc={rc}", flush=True)
                fail |= (rc != 0)
            # G1d: the first stock-guest triangle — vs_passthru + fs_color
            # through a real render pass; the C reference rasterizer
            # mirrors g6lc_apu_rast.sv's op sequence (-ffp-contract=off
            # keeps it honest at single precision).
            if not only or "vktri" in only:
                rc = con.run("cd /root && gcc -O2 -ffp-contract=off "
                             "-fexcess-precision=standard -o vktri vktri.c "
                             "-lvulkan -lm && ./vktri vs_passthru.spv "
                             "fs_color.spv", timeout=1200)
                print(f"[drive] vktri rc={rc}", flush=True)
                fail |= (rc != 0)
            # G2c: the broad oracle — the same 8 scenes rendered on
            # Venus and on Mesa llvmpipe (lavapipe ICD in the same
            # guest), readback compared per channel.  Venus can take
            # tens of seconds per scene.
            if not only or "vkcmp" in only:
                vkenv = os.environ.get("G6LC_VKCMP_ENV", "")
                rc = con.run("cd /root && gcc -O2 -ffp-contract=off "
                             "-fexcess-precision=standard -o vkcmp vkcmp.c "
                             "-lvulkan -lm && " + vkenv +
                             " ./vkcmp vs_passthru.spv "
                             "fs_color.spv vs_pc.spv fs_vcol.spv "
                             "vs_pos3.spv vs_inst.spv vs_tex.spv fs_mip.spv "
                             "vs_clip.spv vs_uvc.spv fs_deriv2.spv fs_scene8.spv "
                             "vs_shadowfog.spv fs_shadowfog.spv",
                             timeout=int(os.environ.get(
                                 "G6LC_VKCMP_TIMEOUT", "5400")))
                print(f"[drive] vkcmp rc={rc}", flush=True)
                fail |= (rc != 0)
                # VKCMP_DUMP leaves vkcmp_s*_*.bin in guest /root —
                # pull them back over the console as base64 so the
                # host can diff venus vs llvmpipe pixels
                if "VKCMP_DUMP" in vkenv:
                    con.run("cd /root && for f in vkcmp_s*.bin; do "
                            "echo B64DUMP:$f; base64 $f; "
                            "echo B64END; done", timeout=300)
            # CTS-0: run the pinned caselist on the Venus device with
            # the deqp-vk shipped on the CTSDATA image.  Results are
            # written back onto the image (/results/) and pulled
            # host-side in the finally block once QEMU is down.
            if os.environ.get("G6LC_CTS") and \
                    (not only or "cts" in only):
                caselist = os.environ.get(
                    "G6LC_CTS_CASELIST",
                    "caselists/cts0-info-smoke.txt")
                logimgs = os.environ.get("G6LC_CTS_LOG_IMAGES",
                                         "disable")
                logshd = os.environ.get("G6LC_CTS_LOG_SHADERS",
                                        "disable")
                logflush = os.environ.get("G6LC_CTS_LOG_FLUSH",
                                          "disable")
                # case count for the marker: read the caselist out of
                # the image host-side.  The guest may hold it mounted
                # rw, but the caselist is static content written at
                # image creation — a read-only debugfs open is safe.
                r = subprocess.run(
                    ["debugfs", "-R", f"cat /{caselist}", CTSDATA],
                    capture_output=True, text=True)
                ctscases = (str(len(r.stdout.splitlines()))
                            if r.returncode == 0 else "?")
                rc = con.run(
                    "mkdir -p /mnt/ctsdata && "
                    "cdev=$(blkid -t LABEL=CTSDATA -o device | head -1); "
                    "echo ctsdev=$cdev; "
                    "mount $cdev /mnt/ctsdata && "
                    "mkdir -p /mnt/ctsdata/results && "
                    "DEVID=$(vulkaninfo --summary 2>/dev/null | awk '"
                    "/^GPU[0-9]+:/{g++} "
                    "/deviceName/ && /Venus/{print g; exit}'); "
                    "echo G6LC_CTS_DEVID=${DEVID:-none}; "
                    "vulkaninfo --summary 2>/dev/null | "
                    "awk '/deviceName/{print; exit}'",
                    timeout=900)
                print(f"[drive] cts mount/enum rc={rc}", flush=True)
                fail |= (rc != 0)
                if rc == 0:
                    # assert the Venus device is the one selected; the
                    # deqp run log must name it (implementation info).
                    rc = con.run(
                        "cd /mnt/ctsdata && "
                        "DEVID=$(vulkaninfo --summary 2>/dev/null | awk '"
                        "/^GPU[0-9]+:/{g++} "
                        "/deviceName/ && /Venus/{print g; exit}'); "
                        "echo running deqp-vk device-id=${DEVID:-none}; "
                        "[ -n \"$DEVID\" ] || { echo 'FAIL: no Venus "
                        "physical device for CTS' >&2; false; } && "
                        "set -o pipefail; "
                        "./deqp-vk "
                        f"--deqp-caselist-file={caselist} "
                        f"--deqp-log-images={logimgs} "
                        f"--deqp-log-shader-sources={logshd} "
                        "--deqp-vk-device-id=$DEVID "
                        "--deqp-log-filename=/mnt/ctsdata/results/"
                        "TestResults.qpa "
                        f"--deqp-log-flush={logflush} "
                        "--deqp-shadercache=disable "
                        "--deqp-archive-dir=/mnt/ctsdata "
                        "2>&1 | tail -25",
                        timeout=int(os.environ.get(
                            "G6LC_CTS_TIMEOUT", "14400")))
                    if rc is None:
                        # con.run timeout — possible wedge; leave rc
                        # visible, mark the guest run failed.
                        print("G6LC_CTS_RUN cases=? rc=timeout",
                              flush=True)
                        fail = True
                    else:
                        print(f"G6LC_CTS_RUN cases={ctscases} rc={rc}",
                              flush=True)
                        fail |= (rc != 0)
                    con.run(
                        "cd /root; "
                        "cp /root/vulkaninfo-summary.txt "
                        "/mnt/ctsdata/results/ 2>/dev/null; "
                        "dmesg > /mnt/ctsdata/results/dmesg.txt; "
                        "sync; umount /mnt/ctsdata; echo CTS_SYNCED",
                        timeout=120)

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

        # send (not run): the DONE marker can never echo back once the
        # guest starts halting.  virtio-blk teardown can panic the guest
        # during poweroff; that still means QEMU is on its way out.
        con.send("poweroff -f\n")
        con.expect(r"reboot|Power down|System halted|Kernel panic", 60)
        # Leading newline: the final serial chunk can end mid-line
        # (kernel 'reboot:' text races this print); the runner requires
        # the marker to be the terminal line verbatim.
        print(f"\nGUEST-{'FAIL' if fail else 'PASS'}", flush=True)
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
        # QEMU is down; the CTSDATA image is closed — pull the deqp
        # results out of it unprivileged with debugfs.
        if os.environ.get("G6LC_CTS") and not args.venusoff and \
                os.path.exists(CTSDATA):
            for src, dst in (("/results/TestResults.qpa",
                              "cts-TestResults.qpa"),
                             ("/results/vulkaninfo-summary.txt",
                              "cts-vulkaninfo-summary.txt"),
                             ("/results/dmesg.txt", "cts-dmesg.txt")):
                r = subprocess.run(
                    ["debugfs", "-R", f"dump {src} {args.out}/{dst}",
                     CTSDATA],
                    capture_output=True, text=True)
                print(f"[drive] cts pull {src}: "
                      f"{'ok' if r.returncode == 0 else r.stderr.strip()}",
                      flush=True)
        serial_log.close()
        server_log.close()
        qemu_log.close()


if __name__ == "__main__":
    sys.exit(main())
