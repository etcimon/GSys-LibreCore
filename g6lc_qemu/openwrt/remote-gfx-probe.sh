#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Etienne Cimon
#
# Remote OpenWrt graphics probe for the pinned QEMU/OpenWrt path. The guest
# probe is opt-in through the kernel command line and powers off when done.
set -u

SRC="${OPENWRT_SRC:-/opt/testharness/cache/openwrt}"
QEMU="${G6Q_REMOTE_QEMU:-/opt/testharness/g6lc-qemu/build/qemu/qemu-system-riscv64}"
VUGPU="${G6Q_REMOTE_VUGPU:-$(dirname "$QEMU")/contrib/vhost-user-gpu/vhost-user-gpu}"
OVERLAY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VUGPU_PRELOAD="${G6Q_REMOTE_VUGPU_PRELOAD:-$OVERLAY_DIR/vugpu-virgl-surfaceless.so}"
VUGPU_SURFACELESS="${G6Q_REMOTE_VUGPU_SURFACELESS:-1}"
RUNS="${TH_RUNS:-/opt/testharness/runs}"
TAG="gfx-$(date -u +%Y%m%dT%H%M%SZ)"
MODE="vugpu"
KERNEL=""
TIMEOUT=240
NEGATIVE=0
AUDIT=0
CAP_PROFILE="${G6Q_REMOTE_VUGPU_CAP_PROFILE:-}"

usage() {
  cat <<'USAGE'
remote-gfx-probe.sh [--mode gl|vugpu|2d] [--qemu PATH] [--kernel PATH]
                    [--tag NAME] [--timeout SEC] [--negative] [--audit]
                    [--cap-profile none|gles2-min|gles2-xfer]

Runs the graphics-enabled OpenWrt initramfs on QEMU virt with modern
virtio-mmio. gl mode uses virtio-gpu-gl-device + egl-headless,gl=on;
vugpu uses QEMU's contrib vhost-user-gpu --virgl backend, with an LD_PRELOAD
surfaceless-EGL shim unless G6Q_REMOTE_VUGPU_SURFACELESS=0; 2d mode uses
virtio-gpu-device + display none.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --qemu) QEMU="$2"; shift 2 ;;
    --kernel) KERNEL="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --negative) NEGATIVE=1; shift ;;
    --audit) AUDIT=1; shift ;;
    --cap-profile) CAP_PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CAP_PROFILE" in
  ""|none|gles2-min|gles2-xfer) ;;
  *) echo "bad --cap-profile $CAP_PROFILE" >&2; exit 2 ;;
esac

if [ -z "$KERNEL" ]; then
  KERNEL="$SRC/bin/targets/sifiveu/generic/openwrt-sifiveu-generic-sifive_unleashed-initramfs-kernel.bin"
elif [ "${KERNEL#/}" = "$KERNEL" ]; then
  if [ -f "$RUNS/$KERNEL" ]; then
    KERNEL="$RUNS/$KERNEL"
  elif [ -f "$SRC/bin/targets/sifiveu/generic/$KERNEL" ]; then
    KERNEL="$SRC/bin/targets/sifiveu/generic/$KERNEL"
  fi
fi
CAPTURE_DIR="$RUNS/$TAG.capture"
mkdir -p "$RUNS" "$CAPTURE_DIR"
SERIAL_LOG="$RUNS/$TAG.serial.log"
QEMU_LOG="$RUNS/$TAG.qemu.log"
BACKEND_LOG="$RUNS/$TAG.vugpu.log"
VUGPU_SOCK="$RUNS/$TAG.vugpu.sock"

if [ ! -x "$QEMU" ]; then
  echo "QEMU_MISSING $QEMU" >&2
  exit 2
fi
if [ ! -f "$KERNEL" ]; then
  echo "KERNEL_MISSING $KERNEL" >&2
  exit 2
fi
if file "$KERNEL" 2>/dev/null | grep -q 'gzip compressed'; then
  KERNEL_RAW="$RUNS/$TAG.kernel.Image"
  if ! gzip -dc "$KERNEL" >"$KERNEL_RAW"; then
    echo "KERNEL_DECOMPRESS_FAILED $KERNEL" >&2
    exit 2
  fi
  KERNEL="$KERNEL_RAW"
fi

APPEND='console=ttyS0,115200n8 g6lc_probe=1'
if [ "$NEGATIVE" != 0 ]; then
  APPEND="$APPEND g6lc_neg=1"
fi
if [ "$AUDIT" != 0 ]; then
  APPEND="$APPEND g6lc_audit=1"
fi

args=(
  -machine virt
  -cpu rv64
  -smp 2
  -m 1G
  -bios default
  -kernel "$KERNEL"
  -append "$APPEND"
  -global virtio-mmio.force-legacy=false
  -serial "file:$SERIAL_LOG"
  -monitor none
  -no-reboot
)
case "$MODE" in
  gl)
    args+=( -device virtio-gpu-gl-device -display egl-headless,gl=on )
    ;;
  vugpu)
    args+=(
      -object "memory-backend-memfd,id=mem,size=1G,share=on"
      -numa node,memdev=mem
      -chardev "socket,id=vgpu,path=$VUGPU_SOCK"
      -device vhost-user-gpu,chardev=vgpu,max_outputs=0
      -display none
    )
    ;;
  2d)
    args+=( -device virtio-gpu-device -display none )
    ;;
  *) echo "bad --mode $MODE" >&2; exit 2 ;;
esac

printf 'QEMU_CMD='
printf '%q ' "$QEMU" "${args[@]}"
printf '\n'
"$QEMU" --version | head -1
if grep -q '^#define CONFIG_OPENGL\b' "$(dirname "$QEMU")/config-host.h" 2>/dev/null; then
  echo QEMU_CONFIG_OPENGL=y
else
  echo QEMU_CONFIG_OPENGL=n
fi
if "$QEMU" -device help 2>/dev/null | grep -q 'virtio-gpu-gl-device'; then
  echo QEMU_DEVICE_VIRTIO_GPU_GL=y
else
  echo QEMU_DEVICE_VIRTIO_GPU_GL=n
fi
if "$QEMU" -device help 2>/dev/null | grep -q 'vhost-user-gpu'; then
  echo QEMU_DEVICE_VHOST_USER_GPU=y
else
  echo QEMU_DEVICE_VHOST_USER_GPU=n
fi
ls -l /dev/dri 2>/dev/null || true

backend_pid=""
if [ "$MODE" = vugpu ]; then
  if [ ! -x "$VUGPU" ]; then
    echo "VHOST_USER_GPU_MISSING $VUGPU" >&2
    exit 2
  fi
  rm -f "$VUGPU_SOCK" "$BACKEND_LOG"
  if [ "$VUGPU_SURFACELESS" != 0 ]; then
    VUGPU_SHIM_SRC="$OVERLAY_DIR/vugpu-virgl-surfaceless.c"
    if [ ! -f "$VUGPU_PRELOAD" ] || [ "$VUGPU_SHIM_SRC" -nt "$VUGPU_PRELOAD" ]; then
      if ! cc -shared -fPIC -O2 -Wall -Wextra "$VUGPU_SHIM_SRC" \
        -o "$VUGPU_PRELOAD" -ldl; then
        echo "VUGPU_SURFACELESS_SHIM_BUILD_FAILED $VUGPU_SHIM_SRC" >&2
        exit 2
      fi
    fi
    env LD_PRELOAD="$VUGPU_PRELOAD" LIBGL_ALWAYS_SOFTWARE=1 \
      VUGPU_VIRGL_DUMP_DIR="$CAPTURE_DIR" \
      VUGPU_VIRGL_CAP_PROFILE="$CAP_PROFILE" \
      "$VUGPU" --virgl --socket-path "$VUGPU_SOCK" >"$BACKEND_LOG" 2>&1 &
  else
    "$VUGPU" --virgl --socket-path "$VUGPU_SOCK" >"$BACKEND_LOG" 2>&1 &
  fi
  backend_pid=$!
  for _ in $(seq 1 50); do
    [ -S "$VUGPU_SOCK" ] && break
    sleep 0.1
  done
  if [ ! -S "$VUGPU_SOCK" ]; then
    echo "VHOST_USER_GPU_SOCKET_TIMEOUT $VUGPU_SOCK" >&2
    cat "$BACKEND_LOG" >&2 || true
    kill "$backend_pid" 2>/dev/null || true
    exit 2
  fi
fi

set +e
timeout "$TIMEOUT" "$QEMU" "${args[@]}" >"$QEMU_LOG" 2>&1
qemu_rc=$?
if [ -n "$backend_pid" ]; then
  kill "$backend_pid" 2>/dev/null || true
  wait "$backend_pid" 2>/dev/null || true
fi
set -e

printf 'QEMU_RC=%s\n' "$qemu_rc"
printf 'QEMU_LOG=%s\nSERIAL_LOG=%s\nBACKEND_LOG=%s\nCAPTURE_DIR=%s\n' \
  "$QEMU_LOG" "$SERIAL_LOG" "$BACKEND_LOG" "$CAPTURE_DIR"
if [ -s "$QEMU_LOG" ]; then
  echo '===== qemu stderr/stdout ====='
  cat "$QEMU_LOG"
fi
if [ -s "$BACKEND_LOG" ]; then
  echo '===== vhost-user-gpu backend ====='
  cat "$BACKEND_LOG"
fi
echo '===== guest markers ====='
grep -E 'G6LC_|Linux version|virtio|drm|DRM|procd|Power down' "$SERIAL_LOG" 2>/dev/null || true

ok=1
if ! grep -q 'G6LC_GFX_DONE rc=0' "$SERIAL_LOG" 2>/dev/null; then
  echo G6LC_GFX_RESULT=FAIL
  ok=0
elif [ "$NEGATIVE" = 0 ] && { [ "$MODE" = gl ] || [ "$MODE" = vugpu ]; } && ! grep -q 'G6LC_EGL_GLES2_OK' "$SERIAL_LOG" 2>/dev/null; then
  echo G6LC_GFX_RESULT=FAIL
  ok=0
else
  echo G6LC_GFX_RESULT=PASS
fi
if [ "$NEGATIVE" != 0 ]; then
  if grep -q 'G6LC_NEG_DONE' "$SERIAL_LOG" 2>/dev/null; then
    echo G6LC_NEG_RESULT=PASS
  else
    echo G6LC_NEG_RESULT=FAIL
    ok=0
  fi
fi
if [ "$AUDIT" != 0 ]; then
  if grep -q 'G6LC_AUDIT_RESULT=PASS' "$SERIAL_LOG" 2>/dev/null; then
    echo G6LC_AUDIT_RESULT=PASS
  else
    echo G6LC_AUDIT_RESULT=FAIL
    ok=0
  fi
fi
if grep -q 'G6LC_EGL_GLES2_DRIVER=virgl' "$SERIAL_LOG" 2>/dev/null; then
  echo G6LC_RENDERER_CLASS=virgl
elif grep -q 'G6LC_EGL_GLES2_DRIVER=other' "$SERIAL_LOG" 2>/dev/null; then
  echo G6LC_RENDERER_CLASS=other
else
  echo G6LC_RENDERER_CLASS=none
fi
[ "$ok" -eq 1 ]
