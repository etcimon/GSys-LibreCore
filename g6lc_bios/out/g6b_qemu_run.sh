#!/bin/bash
# QEMU smoke for g6lc_bios under stock virt + OpenSBI.
# usage: g6b_qemu_run.sh [gl|no] [seconds]
ELF=/mnt/e/cva6/g6lc_bios/out/g6lc_bios-virt.elf
BIOS=/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin
GL=${1:-no}
WAIT=${2:-10}
rm -f /tmp/g6b_ser.log /tmp/g6b_mon.log
if [ "$GL" = gl ]; then
  DISP="-display egl-headless,gl=on -device virtio-gpu-gl-device"
else
  DISP="-display none -device virtio-gpu-device"
fi
# serial: blocking server so the guest waits for our client (full boot log).
qemu-system-riscv64 -M virt -m 512 -smp 2 \
  -bios "$BIOS" -kernel "$ELF" \
  -serial tcp:127.0.0.1:2222,server \
  -monitor tcp:127.0.0.1:2223,server,nowait \
  -global virtio-mmio.force-legacy=false \
  $DISP -device virtio-keyboard-device &
QPID=$!
sleep 1
exec 3<>/dev/tcp/127.0.0.1/2222
cat <&3 > /tmp/g6b_ser.log &
CATPID=$!
exec 4<>/dev/tcp/127.0.0.1/2223
cat <&4 > /tmp/g6b_mon.log &
MONPID=$!
sleep 6
printf "sendkey a\n" >&4
sleep 1
printf "sendkey down\n" >&4
sleep 1
printf "sendkey ret\n" >&4
sleep 1
printf "sendkey down\n" >&4
sleep 1
printf "sendkey up\n" >&4
sleep 1
# UART Keys command → InpPoll dump
printf "Keys\n" >&3
sleep 2
printf "Ui\n" >&3
sleep 3
printf "screendump /tmp/g6b_screen.ppm\n" >&4
sleep "$WAIT"
kill $CATPID $MONPID $QPID 2>/dev/null
wait 2>/dev/null
echo "=== SERIAL ==="
tr -d '\0' < /tmp/g6b_ser.log | head -160
echo "=== MON ==="
cat /tmp/g6b_mon.log 2>/dev/null | tr -d '\r' | grep -v '^\x1b' | head -8
