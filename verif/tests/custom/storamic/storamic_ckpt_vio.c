// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// Native checkpoint with a VirtIO writer in flight (native-composition.md,
// C4). One virtio-blk OUT request is notified and the checkpoint SAVE is
// issued immediately behind it, so the endpoint's pause request reaches the
// device with an accepted job outstanding. The job must finish exactly once
// before the RAM is sealed: the saved image then already holds its single
// used-ring entry. RESTORE proves that from the image; the device (whose own
// state is not rolled back) is then re-initialized and the block read back.
//
// Driver helpers are reused from storamic_virtio_blk.c (its main is renamed
// and unused). Build with -DSTORAMIC_COHERENT_DMA like the native C2 cases.
#define main vblk_unused_main
#include "storamic_virtio_blk.c"
#undef main

#define CK_SAVE      (CTRL_BASE + 0x00)
#define CK_RESTORE   (CTRL_BASE + 0x04)
#define CK_CONSUME   (CTRL_BASE + 0x08)
#define CK_STATUS    (CTRL_BASE + 0x10)
#define CK_RES_CODE  (CTRL_BASE + 0x18)
#define CK_ST_READY  0x01U
#define CK_ST_RESULT 0x02U
#define CK_ST_BUSY   0x04U
#define CK_ST_LOCKED 0x08U
#define CK_ST_INIT   0x10U

enum {
  VF_BOOT = 40, VF_INIT, VF_SAVE_TIMEOUT, VF_SAVE_CODE, VF_IRQ,
  VF_USED_AFTER_SAVE,   // completion missing or duplicated after SAVE
  VF_STATUS_BYTE, VF_IN, VF_IN_DATA, VF_RESTORE_TIMEOUT, VF_RESTORE_CODE,
  VF_USED_IN_IMAGE,     // saved image does not hold exactly the one completion
  VF_REINIT, VF_IN_AFTER, VF_IN_AFTER_DATA
};

static inline __attribute__((always_inline)) int ck_wait(void) {
  for (unsigned long n = 0; n < 4000000UL; n++)
    if (RD32(CK_STATUS) & CK_ST_RESULT) return 1;
  return 0;
}

int main(void) {
  unsigned int st, *h;
  int i;

  st = RD32(CK_STATUS);
  if ((st & (CK_ST_INIT | CK_ST_READY)) != (CK_ST_INIT | CK_ST_READY) ||
      (st & (CK_ST_BUSY | CK_ST_LOCKED | CK_ST_RESULT)))
    return VF_BOOT;
  if (dev_init() != 0) return VF_INIT;
  for (i = 0; i < 1024; i++) out_buf[i] = (unsigned char)((i * 7 + 3) ^ (i >> 8));

  // Post OUT(sector 5) and issue SAVE right behind the notify.
  h = (unsigned int *)req_hdr;
  h[0] = T_OUT; h[1] = 0;
  *(unsigned long long *)(h + 2) = 5;
  vdesc[0].addr = ptr(req_hdr); vdesc[0].len = 16;
  vdesc[0].flags = D_NEXT; vdesc[0].next = 1;
  vdesc[1].addr = ptr(out_buf); vdesc[1].len = 1024;
  vdesc[1].flags = D_NEXT; vdesc[1].next = 2;
  vdesc[2].addr = ptr(stat_buf); vdesc[2].len = 1;
  vdesc[2].flags = D_WRITE; vdesc[2].next = 0;
  stat_buf[0] = 0xFF;
  vavail.ring[0] = 0;
  fence();
  vavail.idx = ++avail_i;
  fence();
  WR32(R_QNOTIFY, 0);
  WR32(CK_SAVE, 0xC0DE0011U);

  if (!ck_wait()) return VF_SAVE_TIMEOUT;
  if (RD32(CK_RES_CODE) != 0) return VF_SAVE_CODE;
  WR32(CK_CONSUME, 0xC0DE0011U);
  if ((RD32(R_ISTAT) & 1) == 0) return VF_IRQ;
  if ((dram_rd32(&vused) >> 16) != 1) return VF_USED_AFTER_SAVE;
  if ((dram_rd32(stat_buf) & 0xFF) != 0) return VF_STATUS_BYTE;
  used_i = 1;
  irq_ack();

  // The block was written once and reads back; used.idx becomes 2 in RAM.
  if (blk_req(T_IN, 5, in_buf, 1024) != 0) return VF_IN;
  irq_ack();
  if (!dev_eq(in_buf, out_buf, 1024)) return VF_IN_DATA;

  WR32(CK_RESTORE, 0xC0DE0012U);
  if (!ck_wait()) return VF_RESTORE_TIMEOUT;
  if (RD32(CK_RES_CODE) != 0) return VF_RESTORE_CODE;
  WR32(CK_CONSUME, 0xC0DE0012U);
  // The image was taken after the in-flight job retired: exactly one entry.
  if ((dram_rd32(&vused) >> 16) != 1) return VF_USED_IN_IMAGE;

  // Device state is not part of the image: resynchronize, then read back.
  if (dev_init() != 0) return VF_REINIT;
  if (blk_req(T_IN, 5, in_buf, 1024) != 0) return VF_IN_AFTER;
  irq_ack();
  if (!dev_eq(in_buf, out_buf, 1024)) return VF_IN_AFTER_DATA;
  return 0;
}
