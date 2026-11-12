// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-037C: bare-metal VirtIO-MMIO virtio-blk test on ariane_testharness with
// the Storamic peripheral role (G6LC_STORAMIC_IO). Drives the device at 0x5000_1000 end to
// end against the model stick's flash chip: the commit-boundary durable
// store (128 sectors, FLUSH negotiated and exercised).
//
// The device DMA is not coherent with the D-cache. This target's D-cache is
// write-through (CPU stores reach DRAM before the doorbell `fence` retires),
// but `fence` does not invalidate it and the core has no Zicbom, so a line
// the CPU has read stays stale after a device write (found by this test).
// Every read of device-written memory (used ring, status bytes, IN and
// GET_ID buffers) therefore uses `amoor.w x0`, which the write-through cache
// performs at memory and which returns the memory value unchanged. This test
// is NOT a coherence qualification: Linux needs a coherent DMA path or
// cache-maintenance operations (ST-038).
//
// main() returns 0 on pass, or a FAIL_* code (reported through tohost).
// Built with -DORACLE_NEGATIVE, step f compares against a corrupted expected
// byte and must fail with FAIL_IN_DATA.

#define CTRL_BASE  0x50000000UL
#define MMIO_BASE  0x50001000UL
#define PWR_CUT    (CTRL_BASE + 0x3000)   // sim-only immediate power cut
#define PWR_CUT_DRAIN (CTRL_BASE + 0x3008) // arm: cut inside next flush drain
#define PLIC_BASE  0x0C000000UL
#define PLIC_PRIO(s) (PLIC_BASE + 4 * (s))
#define PLIC_PEND  (PLIC_BASE + 0x1000)
#define PLIC_SRC   11

// MMIO accessors in the Linux readl/writel shape: a fence before each write
// (orders it after earlier memory writes) and after each read; nothing
// between a register write and a following read of the same register. The
// core must therefore neither merge adjacent I/O stores nor forward an I/O
// store to a younger I/O load (both were found by this test, ST-037C step 4,
// and fixed in store_buffer.sv / wt_dcache_wbuffer.sv). Build with
// -DSTORAMIC_MMIO_FULL_FENCE to restore fences on both sides.
static inline unsigned int RD32(unsigned long a) {
  unsigned int v;
#ifdef STORAMIC_MMIO_FULL_FENCE
  __asm__ volatile ("fence" ::: "memory");
#endif
  v = *(volatile unsigned int *)a;
  __asm__ volatile ("fence" ::: "memory");
  return v;
}
static inline void WR32(unsigned long a, unsigned int v) {
  __asm__ volatile ("fence" ::: "memory");
  *(volatile unsigned int *)a = v;
#ifdef STORAMIC_MMIO_FULL_FENCE
  __asm__ volatile ("fence" ::: "memory");
#endif
}

#define R_MAGIC     (MMIO_BASE + 0x000)
#define R_VERSION   (MMIO_BASE + 0x004)
#define R_DEVID     (MMIO_BASE + 0x008)
#define R_FEATURES  (MMIO_BASE + 0x010)
#define R_FEATSEL   (MMIO_BASE + 0x014)
#define R_DRVFEAT   (MMIO_BASE + 0x020)
#define R_DRVSEL    (MMIO_BASE + 0x024)
#define R_QSEL      (MMIO_BASE + 0x030)
#define R_QNMAX     (MMIO_BASE + 0x034)
#define R_QNUM      (MMIO_BASE + 0x038)
#define R_QREADY    (MMIO_BASE + 0x044)
#define R_QNOTIFY   (MMIO_BASE + 0x050)
#define R_ISTAT     (MMIO_BASE + 0x060)
#define R_IACK      (MMIO_BASE + 0x064)
#define R_STATUS    (MMIO_BASE + 0x070)
#define R_QDESC_LO  (MMIO_BASE + 0x080)
#define R_QDESC_HI  (MMIO_BASE + 0x084)
#define R_QDRV_LO   (MMIO_BASE + 0x090)
#define R_QDRV_HI   (MMIO_BASE + 0x094)
#define R_QDEV_LO   (MMIO_BASE + 0x0A0)
#define R_QDEV_HI   (MMIO_BASE + 0x0A4)
#define R_CFG       (MMIO_BASE + 0x100)

#define ST_ACK 1
#define ST_DRV 2
#define ST_DOK 4
#define ST_FOK 8

#define T_IN    0
#define T_OUT   1
#define T_FLUSH 4
#define T_GETID 8

#define D_NEXT  1
#define D_WRITE 2

#define QN 8

enum {
  FAIL_CTRL_ID = 1, FAIL_MAGIC, FAIL_VERSION, FAIL_DEVID, FAIL_CAPACITY,
  FAIL_RESET, FAIL_FEATURES, FAIL_FOK, FAIL_QUEUE, FAIL_DOK,
  FAIL_OUT, FAIL_IRQ_ISTAT, FAIL_IRQ_PLIC, FAIL_IRQ_ACK,
  FAIL_IN, FAIL_IN_DATA, FAIL_GETID, FAIL_IOERR, FAIL_AFTER_IOERR,
  FAIL_REINIT, FAIL_REINIT_IO, FAIL_TIMEOUT, FAIL_CPU_RAW, FAIL_FLUSH,
  FAIL_DURABLE, FAIL_ATOMIC,
  // A3 port-2 oracle: distinct tohost codes for a DMA-window-address request.
  FAIL_DMA_WIN_OK, FAIL_DMA_WIN_REJ,
  // Timeout split: DEVICE_NEEDS_RESET (status bit 6, 0x40) vs silent stall.
  FAIL_DMA_WIN_NEEDS_RESET, FAIL_DMA_WIN_STALL
};

struct vq_desc { unsigned long long addr; unsigned int len;
                 unsigned short flags, next; };
struct vq_avail { unsigned short flags, idx, ring[QN]; };
struct vq_used_elem { unsigned int id, len; };
struct vq_used { unsigned short flags, idx; struct vq_used_elem ring[QN]; };

static struct vq_desc vdesc[QN] __attribute__((aligned(4096)));
static struct vq_avail vavail __attribute__((aligned(4096)));
static volatile struct vq_used vused __attribute__((aligned(4096)));
static unsigned char req_hdr[16] __attribute__((aligned(4096)));
static volatile unsigned char stat_buf[8] __attribute__((aligned(4096)));
static unsigned char out_buf[1024] __attribute__((aligned(4096)));
static volatile unsigned char in_buf[1024] __attribute__((aligned(4096)));
static volatile unsigned char id_buf[32] __attribute__((aligned(4096)));

static unsigned short avail_i, used_i;
static unsigned int last_len;

static inline void fence(void) { __asm__ volatile ("fence" ::: "memory"); }

// ST-012: LR/SC + AMO ownership evidence on the primary memory path (in the
// primary role every access traverses Storamic into sim_mem; the exclusive
// monitor in g6lc_axi_atomics_wrap is what these instructions exercise).
static volatile unsigned int atomic_var __attribute__((aligned(64)));
static volatile unsigned int atomic_other __attribute__((aligned(64)));
static int atomics_check(void) {
  unsigned long lr, ok;
  atomic_var = 0; atomic_other = 0;
  // LR/SC spin-increment: reservation + store-conditional round-trip.
  for (int i = 0; i < 8; i++) {
    int spins = 0;
    do {
      __asm__ volatile("lr.w %0, (%1)" : "=r"(lr) : "r"(&atomic_var) : "memory");
      lr++;
      __asm__ volatile("sc.w %0, %1, (%2)" : "=r"(ok) : "r"(lr),
                       "r"(&atomic_var) : "memory");
    } while (ok && ++spins < 64);
    if (ok) return FAIL_ATOMIC | (1 << 8);   // SC never succeeded
  }
  if (atomic_var != 8) return FAIL_ATOMIC | (2 << 8) |
                              (atomic_var << 16);
  // Address-keyed reservation: an SC to a different address must fail
  // (sc.w returns nonzero on failure) and must not store.
  __asm__ volatile("lr.w %0, (%1)" : "=r"(lr) : "r"(&atomic_var) : "memory");
  __asm__ volatile("sc.w %0, %1, (%2)" : "=r"(ok) : "r"(0x77ul),
                       "r"(&atomic_other) : "memory");
  if (!ok || atomic_other != 0) return FAIL_ATOMIC | (3 << 8) |
                              (ok << 16) | (atomic_other << 24);
  // AMOs: add / swap / and / or, checking both the loaded old value and the
  // resulting memory contents.
  __asm__ volatile("amoadd.w %0, %2, (%1)" : "=r"(lr) : "r"(&atomic_var),
                   "r"(4u) : "memory");
  if (atomic_var != 12 || lr != 8) return FAIL_ATOMIC | (4 << 8) |
                              (lr << 16) | (atomic_var << 24);
  __asm__ volatile("amoswap.w %0, %2, (%1)" : "=r"(lr) : "r"(&atomic_var),
                   "r"(99u) : "memory");
  if (atomic_var != 99 || lr != 12) return FAIL_ATOMIC | (5 << 8);
  __asm__ volatile("amoand.w %0, %2, (%1)" : "=r"(lr) : "r"(&atomic_var),
                   "r"(0xF0u) : "memory");
  __asm__ volatile("nop\nnop\nnop\nnop\nnop\nnop\nnop\nnop" ::: "memory");
  {
    unsigned int chk_var = atomic_var;
    if (chk_var != 96)
      return FAIL_ATOMIC | (6 << 8) | ((chk_var & 0xFF) << 16) |
             (((chk_var >> 8) & 0xFF) << 24);
    if (lr != 99)
      return FAIL_ATOMIC | (9 << 8) | ((((unsigned long)lr) & 0xFF) << 16) |
             ((((unsigned long)(lr >> 8)) & 0xFF) << 24);
  }
  __asm__ volatile("amoor.w %0, %2, (%1)" : "=r"(lr) : "r"(&atomic_var),
                   "r"(5u) : "memory");
  if (atomic_var != 101 || lr != 96) return FAIL_ATOMIC | (7 << 8);
  // Store-visibility lag probe (found via sub-6): an AMO writes 1 each
  // iteration; the immediately following load must always see the new
  // value. Report the first iteration where a stale read appears.
  atomic_var = 0;
  for (int i = 0; i < 32; i++) {
    unsigned int seen;
    __asm__ volatile("amoadd.w zero, %1, (%0)" :: "r"(&atomic_var), "r"(1u)
                     : "memory");
    seen = atomic_var;                    // volatile load right after the AMO
    if (seen != (unsigned int)(i + 1))
      return FAIL_ATOMIC | (8 << 8) | ((i & 0xF) << 16) | (seen << 20);
  }
  return 0;
}
// Read a device-written DRAM word. With STORAMIC_COHERENT_DMA the harness
// invalidates the CPU caches for every device write, so a plain load must see
// the device data; otherwise amoor.w reads at memory past a stale line.
static inline unsigned int dram_rd32(const volatile void *p) {
#ifdef STORAMIC_COHERENT_DMA
  return *(const volatile unsigned int *)p;
#else
  unsigned int v;
  __asm__ volatile ("amoor.w %0, zero, (%1)" : "=r"(v) : "r"(p) : "memory");
  return v;
#endif
}
static inline unsigned long long ptr(const volatile void *p) {
  return (unsigned long long)(unsigned long)p;
}

// Full driver initialisation (VirtIO 1.x section 3.1.1) for queue 0.
static int dev_init(void) {
  int i;
  WR32(R_STATUS, 0);
  for (i = 0; i < 100000 && RD32(R_STATUS) != 0; i++) ;
  if (RD32(R_STATUS) != 0) return FAIL_RESET;
  WR32(R_STATUS, ST_ACK);
  WR32(R_STATUS, ST_ACK | ST_DRV);
  if ((RD32(R_FEATURES) & (1u << 9)) == 0) return FAIL_FEATURES; // bank 0 FLUSH
  WR32(R_FEATSEL, 1);
  if ((RD32(R_FEATURES) & 1) == 0) return FAIL_FEATURES;   // VERSION_1
  WR32(R_DRVSEL, 0); WR32(R_DRVFEAT, 1u << 9);             // negotiate FLUSH
  // Back-to-back stores to the two halves of one 8-byte word with no fence
  // in between: they must reach the device as two 32-bit writes, in order.
  *(volatile unsigned int *)R_DRVSEL = 1;
  *(volatile unsigned int *)R_DRVFEAT = 1;
  WR32(R_STATUS, ST_ACK | ST_DRV | ST_FOK);
  if ((RD32(R_STATUS) & ST_FOK) == 0) return FAIL_FOK;
  WR32(R_QSEL, 0);
  // Queue failures carry diagnostics above bit 8: status, QueueReady, a
  // QueueNumMax-too-small flag and which check failed.
  if (RD32(R_QREADY) != 0 || RD32(R_QNMAX) < QN)
    return FAIL_QUEUE | (RD32(R_STATUS) << 8) | (RD32(R_QREADY) << 16) |
           ((RD32(R_QNMAX) < QN) << 17);
  WR32(R_QNUM, QN);
  for (i = 0; i < QN; i++) {
    vavail.ring[i] = 0; vused.ring[i].id = 0; vused.ring[i].len = 0;
  }
  vavail.flags = 0; vavail.idx = 0; vused.flags = 0; vused.idx = 0;
  avail_i = 0; used_i = 0;
  fence();
  WR32(R_QDESC_LO, (unsigned int)ptr(vdesc));
  WR32(R_QDESC_HI, (unsigned int)(ptr(vdesc) >> 32));
  WR32(R_QDRV_LO, (unsigned int)ptr(&vavail));
  WR32(R_QDRV_HI, (unsigned int)(ptr(&vavail) >> 32));
  WR32(R_QDEV_LO, (unsigned int)ptr(&vused));
  WR32(R_QDEV_HI, (unsigned int)(ptr(&vused) >> 32));
  WR32(R_QREADY, 1);
  if (RD32(R_QREADY) != 1)
    return FAIL_QUEUE | (RD32(R_STATUS) << 8) | (1 << 18);
  WR32(R_STATUS, ST_ACK | ST_DRV | ST_FOK | ST_DOK);
  if ((RD32(R_STATUS) & ST_DOK) == 0) return FAIL_DOK;
  return 0;
}

// Post one three-descriptor request and wait for its completion via
// InterruptStatus (an uncached MMIO poll, so no fence inside the loop).
// Returns the status byte, or -1 on timeout / wrong used entry. The
// interrupt is left pending; the caller acknowledges it.
static int blk_req(int type, unsigned long long sector,
                   const volatile void *data, unsigned int dlen) {
  unsigned int *h = (unsigned int *)req_hdr;
  int i;
  h[0] = type; h[1] = 0;
  *(unsigned long long *)(h + 2) = sector;
  vdesc[0].addr = ptr(req_hdr); vdesc[0].len = 16;
  vdesc[0].flags = D_NEXT; vdesc[0].next = 1;
#ifdef ORACLE_DMA_WINDOW
  // A3: ORACLE_DMA_WINDOW carries the in-window offset; the data segment is
  // forced into the Storamic window so the device's DMA-window check decides.
  vdesc[1].addr = 0x50000000UL + ORACLE_DMA_WINDOW;
#else
  vdesc[1].addr = ptr(data);
#endif
  vdesc[1].len = dlen;
  vdesc[1].flags = D_NEXT | (type == T_OUT ? 0 : D_WRITE); vdesc[1].next = 2;
  vdesc[2].addr = ptr(stat_buf); vdesc[2].len = 1;
  vdesc[2].flags = D_WRITE; vdesc[2].next = 0;
  stat_buf[0] = 0xFF;
  vavail.ring[avail_i % QN] = 0;
  fence();
  vavail.idx = ++avail_i;
  fence();
  WR32(R_QNOTIFY, 0);
  for (i = 0; i < 200000 && (RD32(R_ISTAT) & 1) == 0; i++) ;
  if ((RD32(R_ISTAT) & 1) == 0) return -1;
  // used.flags (le16) and used.idx (le16) share the first word.
  if ((dram_rd32(&vused) >> 16) != (unsigned short)(used_i + 1)) return -1;
  if (dram_rd32(&vused.ring[used_i % QN].id) != 0) return -1;
  last_len = dram_rd32(&vused.ring[used_i % QN].len);
  used_i++;
  return dram_rd32(stat_buf) & 0xFF;
}

// Post a two-descriptor FLUSH (header + status, no data segments).
// Returns the status byte or -1 like blk_req.
static int blk_flush(void) {
  unsigned int *h = (unsigned int *)req_hdr;
  int i;
  h[0] = T_FLUSH; h[1] = 0;
  *(unsigned long long *)(h + 2) = 0;
  vdesc[0].addr = ptr(req_hdr); vdesc[0].len = 16;
  vdesc[0].flags = D_NEXT; vdesc[0].next = 1;
  vdesc[1].addr = ptr(stat_buf); vdesc[1].len = 1;
  vdesc[1].flags = D_WRITE; vdesc[1].next = 0;
  stat_buf[0] = 0xFF;
  vavail.ring[avail_i % QN] = 0;
  fence();
  vavail.idx = ++avail_i;
  fence();
  WR32(R_QNOTIFY, 0);
  for (i = 0; i < 200000 && (RD32(R_ISTAT) & 1) == 0; i++) ;
  if ((RD32(R_ISTAT) & 1) == 0) return -1;
  if ((dram_rd32(&vused) >> 16) != (unsigned short)(used_i + 1)) return -1;
  if (dram_rd32(&vused.ring[used_i % QN].id) != 0) return -1;
  last_len = dram_rd32(&vused.ring[used_i % QN].len);
  used_i++;
  return dram_rd32(stat_buf) & 0xFF;
}

#ifdef STORAMIC_COMMIT_SLOW
// Flush whose drain is cut mid-commit: notify, cut power while the drain
// runs (CommitCycles > 1), then poll like blk_flush. The journaled head
// entry must replay and the held request must still complete OK.
static int blk_flush_cut(void) {
  unsigned int *h = (unsigned int *)req_hdr;
  int i;
  h[0] = T_FLUSH; h[1] = 0;
  *(unsigned long long *)(h + 2) = 0;
  vdesc[0].addr = ptr(req_hdr); vdesc[0].len = 16;
  vdesc[0].flags = D_NEXT; vdesc[0].next = 1;
  vdesc[1].addr = ptr(stat_buf); vdesc[1].len = 1;
  vdesc[1].flags = D_WRITE; vdesc[1].next = 0;
  stat_buf[0] = 0xFF;
  vavail.ring[avail_i % QN] = 0;
  fence();
  vavail.idx = ++avail_i;
  fence();
  WR32(R_QNOTIFY, 0);
  WR32(PWR_CUT_DRAIN, 1);      // armed: cut lands inside the drain
  for (i = 0; i < 200000 && (RD32(R_ISTAT) & 1) == 0; i++) ;
  if ((RD32(R_ISTAT) & 1) == 0) return -1;
  if ((dram_rd32(&vused) >> 16) != (unsigned short)(used_i + 1)) return -1;
  if (dram_rd32(&vused.ring[used_i % QN].id) != 0) return -1;
  last_len = dram_rd32(&vused.ring[used_i % QN].len);
  used_i++;
  return dram_rd32(stat_buf) & 0xFF;
}
#endif

static void irq_ack(void) { WR32(R_IACK, RD32(R_ISTAT)); }

// Compare device-written memory against an expected buffer, word by word
// through dram_rd32. len is a multiple of 4.
static int dev_eq(const volatile void *dev, const unsigned char *exp, int len) {
  int i;
  for (i = 0; i < len; i += 4) {
    unsigned int w = dram_rd32((const volatile unsigned char *)dev + i);
    unsigned int e = exp[i] | (exp[i + 1] << 8) | (exp[i + 2] << 16) |
                     ((unsigned int)exp[i + 3] << 24);
    if (w != e) return 0;
  }
  return 1;
}

int main(void) {
  int i, rc;

  // a. The Storamic control page (CTRL_BASE) belongs to the primary-memory
  //    role; in the peripheral-only build it answers DECERR, so it is only
  //    read when compiled with STORAMIC_PRIMARY.
#ifdef STORAMIC_PRIMARY
  if (RD32(CTRL_BASE) != 0x5354524D) return FAIL_CTRL_ID;
#endif
  // a2. CPU-only read-after-write through the cache on this memory (no DMA):
  //     fill, read (caching the lines), overwrite with zeros, read back.
  {
    static volatile unsigned char scratch[1024] __attribute__((aligned(4096)));
    unsigned int sum = 0;
    for (i = 0; i < 1024; i++) scratch[i] = (unsigned char)(i * 5 + 1);
    for (i = 0; i < 1024; i++) sum += scratch[i];
    for (i = 0; i < 1024; i++) scratch[i] = 0;
    for (i = 0; i < 1024; i += 4)
      if (*(volatile unsigned int *)(scratch + i) != 0)
        return FAIL_CPU_RAW | (i << 8) | ((sum & 1) << 31);
  }
  // a3. ST-012: LR/SC and AMOs on DRAM — in the primary role these traverse
  //     the Storamic path through the exclusive monitor.
  if ((rc = atomics_check()) != 0) return rc;
  // b. VirtIO identity and capacity (le64 sectors at config offset 0).
  if (RD32(R_MAGIC) != 0x74726976) return FAIL_MAGIC;
  if (RD32(R_VERSION) != 2) return FAIL_VERSION;
  if (RD32(R_DEVID) != 2) return FAIL_DEVID;
  if (RD32(R_CFG) != 128 || RD32(R_CFG + 4) != 0) return FAIL_CAPACITY;

  // c. Initialisation.
  if ((rc = dev_init()) != 0) return rc;
  WR32(PLIC_PRIO(PLIC_SRC), 1);

  // d. OUT 1024 bytes at sector 5.
  for (i = 0; i < 1024; i++) out_buf[i] = (unsigned char)((i * 7 + 3) ^ (i >> 8));
#ifdef ORACLE_DMA_WINDOW
  // A3: the data segment targets the Storamic window; the device must reject
  // it (win_ok) with a non-OK status and issue no port-2 DMA. A status of OK
  // means the window address was wrongly accepted -> FAIL_DMA_WIN_OK.
  rc = blk_req(T_OUT, 5, out_buf, 1024);
  if (rc < 0) {
    // Timeout: classify by device state. status bit 6 (0x40) is
    // DEVICE_NEEDS_RESET; anything else with no completion/interrupt is a
    // silent stall (a device-liveness finding). Status is encoded in bits 8+.
    unsigned int dst = RD32(R_STATUS);
    unsigned int dist = RD32(R_ISTAT);
    if (dst & 0x40) return FAIL_DMA_WIN_NEEDS_RESET | (dst << 8);
    return FAIL_DMA_WIN_STALL | (dst << 8) | ((dist & 0xFF) << 28);
  }
  if (rc == 0) return FAIL_DMA_WIN_OK;
  return FAIL_DMA_WIN_REJ;
#else
  rc = blk_req(T_OUT, 5, out_buf, 1024);
  if (rc < 0) return FAIL_TIMEOUT;
  if (rc != 0 || last_len != 1) return FAIL_OUT;
#endif

  // e. Interrupt: device status bit, PLIC pending, acknowledge clears it.
  if ((RD32(R_ISTAT) & 1) == 0) return FAIL_IRQ_ISTAT;
  if ((RD32(PLIC_PEND) & (1u << PLIC_SRC)) == 0) return FAIL_IRQ_PLIC;
  irq_ack();
  if ((RD32(R_ISTAT) & 1) != 0) return FAIL_IRQ_ACK;

  // e2. FLUSH: negotiated; must return OK, committing the sector-5 write.
  rc = blk_flush();
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  if (rc != 0) return FAIL_FLUSH;

  // e3. Durability boundary (8-entry write-back staging): commit A to
  //     sector 10 and flush; write B without flushing, so the first 56
  //     words of B commit by spilling and the last 8 words stay staged.
  //     A power cut then must drop only the staged tail — the read shows
  //     B for 448 bytes and A for the last 64.
  {
#ifndef STORAMIC_PRIMARY
    // ST-025 durability-after-cut oracle. In the primary role the Storamic
    // stick RAM *is* the system memory this program runs from: PWR_CUT
    // (CTRL_BASE+0x3000) raises storamic_power_cut -> lost_q/ScanClear of the
    // live array, so the staged-tail-survival check is meaningless and the
    // cut itself wedges the hart (the next main-memory AW is never serviced,
    // observed as tohost=126). Power-cut survival is the C5/C6 checkpoint
    // flow, not this native virtio test -> compiled out under STORAMIC_PRIMARY.
    // The sector-5 pattern restore below is *not* part of the cut test and
    // stays for every role.
    static unsigned char a_buf[512] __attribute__((aligned(64)));
    for (i = 0; i < 512; i++) a_buf[i] = out_buf[i] = (unsigned char)(0xA5 ^ i);
    rc = blk_req(T_OUT, 10, out_buf, 512);
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0) return FAIL_OUT;
    rc = blk_flush();
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0) return FAIL_FLUSH;
    for (i = 0; i < 512; i++) out_buf[i] = (unsigned char)(0x3C ^ (i * 3));
    rc = blk_req(T_OUT, 10, out_buf, 512);
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0) return FAIL_OUT;
    WR32(PWR_CUT, 1);                        // drops the staged tail of B
    for (i = 0; i < 512; i++) in_buf[i] = 0;
    rc = blk_req(T_IN, 10, in_buf, 512);
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0) return FAIL_IN;
    if (!dev_eq(in_buf, out_buf, 448) || !dev_eq(in_buf + 448, a_buf + 448, 64))
      return FAIL_DURABLE;
    // The store recovers: a later write still stages and commits.
    for (i = 0; i < 512; i++) out_buf[i] = (unsigned char)(0x77 ^ (i >> 1));
    rc = blk_req(T_OUT, 11, out_buf, 512);
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0) return FAIL_OUT;
    rc = blk_flush();
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0) return FAIL_FLUSH;
    rc = blk_req(T_IN, 11, in_buf, 512);
    if (rc < 0) return FAIL_TIMEOUT;
    irq_ack();
    if (rc != 0 || !dev_eq(in_buf, out_buf, 512)) return FAIL_DURABLE;
#ifdef STORAMIC_COMMIT_SLOW
    // e4. Mid-commit power cut: A committed to sector 12, B staged without
    //     flush, then a flush is cut mid-drain. The head entry (word 56)
    //     was journaled, so it survives; words 57-63 were still staged and
    //     drop. Expected: B for 456 bytes, A for the last 56.
    {
      for (i = 0; i < 512; i++) a_buf[i] = out_buf[i] = (unsigned char)(0x11 ^ i);
      rc = blk_req(T_OUT, 12, out_buf, 512);
      if (rc < 0) return FAIL_TIMEOUT;
      irq_ack();
      if (rc != 0) return FAIL_OUT;
      rc = blk_flush();
      if (rc < 0) return FAIL_TIMEOUT;
      irq_ack();
      if (rc != 0) return FAIL_FLUSH;
      for (i = 0; i < 512; i++) out_buf[i] = (unsigned char)(0x6B ^ (i * 5));
      rc = blk_req(T_OUT, 12, out_buf, 512);
      if (rc < 0) return FAIL_TIMEOUT;
      irq_ack();
      if (rc != 0) return FAIL_OUT;
      rc = blk_flush_cut();
      if (rc < 0) return FAIL_TIMEOUT;
      irq_ack();
      if (rc != 0) return FAIL_FLUSH;
      for (i = 0; i < 512; i++) in_buf[i] = 0;
      rc = blk_req(T_IN, 12, in_buf, 512);
      if (rc < 0) return FAIL_TIMEOUT;
      irq_ack();
      if (rc != 0) return FAIL_IN;
      if (!dev_eq(in_buf, out_buf, 456) || !dev_eq(in_buf + 456, a_buf + 456, 56))
        return FAIL_DURABLE;
    }
#endif
#endif  // !STORAMIC_PRIMARY — durability-after-cut oracle (see note above)
    // Restore the sector-5 pattern that step f compares against.
    for (i = 0; i < 1024; i++) out_buf[i] = (unsigned char)((i * 7 + 3) ^ (i >> 8));
  }

  // f. IN the same two sectors into a separate buffer; compare every byte.
  for (i = 0; i < 1024; i++) in_buf[i] = 0;
  rc = blk_req(T_IN, 5, in_buf, 1024);
  if (rc < 0) return FAIL_TIMEOUT;
  if (rc != 0 || last_len != 1025) return FAIL_IN;
  irq_ack();
#ifdef ORACLE_NEGATIVE
  out_buf[517] ^= 0x40;
#endif
  if (!dev_eq(in_buf, out_buf, 1024)) return FAIL_IN_DATA;
#ifdef ORACLE_NEGATIVE
  out_buf[517] ^= 0x40;
#endif

  // g. GET_ID returns the 20-byte serial.
  for (i = 0; i < 32; i++) id_buf[i] = 0;
  rc = blk_req(T_GETID, 0, id_buf, 32);
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  if (rc != 0 || last_len != 21) return FAIL_GETID;
  if (!dev_eq(id_buf, (const unsigned char *)"G6LC-STORAMIC-MODEL0", 20)) return FAIL_GETID;

  // h. Past capacity (sector 127 + 2 sectors > 128): IOERR and no data
  //    written, then a valid read of sector 5 into a cleared buffer.
  for (i = 0; i < 1024; i++) in_buf[i] = 0;
  rc = blk_req(T_IN, 127, in_buf, 1024);
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  // Diagnostics above bit 8: the status byte and used length seen, or the
  // first non-zero word offset of the untouched buffer (bit 24 set).
  if (rc != 1 || last_len != 1)
    return FAIL_IOERR | ((rc & 0xFF) << 8) | ((last_len & 0xFF) << 16);
  for (i = 0; i < 1024; i += 4)
    if (dram_rd32(in_buf + i) != 0) return FAIL_IOERR | (1 << 24) | (i << 8);
  rc = blk_req(T_IN, 5, in_buf, 512);
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  if (rc != 0 || last_len != 513) return FAIL_AFTER_IOERR;
  if (!dev_eq(in_buf, out_buf, 512)) return FAIL_AFTER_IOERR;

  // i. Device reset, full re-initialisation, one more round trip (sector 20).
  if ((rc = dev_init()) != 0) return FAIL_REINIT;
  for (i = 0; i < 512; i++) out_buf[i] = (unsigned char)(0x5A ^ i);
  rc = blk_req(T_OUT, 20, out_buf, 512);
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  if (rc != 0) return FAIL_REINIT_IO;
  for (i = 0; i < 512; i++) in_buf[i] = 0;
  rc = blk_req(T_IN, 20, in_buf, 512);
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  if (rc != 0) return FAIL_REINIT_IO;
  if (!dev_eq(in_buf, out_buf, 512)) return FAIL_REINIT_IO;
  // Sector 5 survived the device reset (the store is not reset with it).
  for (i = 0; i < 512; i++) {
    in_buf[i] = 0;
    out_buf[i] = (unsigned char)((i * 7 + 3) ^ (i >> 8));
  }
  rc = blk_req(T_IN, 5, in_buf, 512);
  if (rc < 0) return FAIL_TIMEOUT;
  irq_ack();
  if (rc != 0) return FAIL_REINIT_IO;
  if (!dev_eq(in_buf, out_buf, 512)) return FAIL_REINIT_IO;
  return 0;
}
