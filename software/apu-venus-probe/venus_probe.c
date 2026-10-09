// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// 3d-a bare-metal Venus probe (apu-vulkan-engine.md §12.3 phase B):
// a single CVA6 hart boots this image from DRAM and drives the
// virtio-mmio + virtio-gpu probe register-for-register, lays out the
// two split virtqueues in DRAM, and replays the Mesa-shaped vn_golden
// tapes (transport + compute) in software: descriptor writes, avail
// pushes, doorbells, ISR read/ack, used-ring consumption, aperture
// polling and .exp checks.
//
// Coherence contract (Linux non-coherent DMA path): cbo.flush + fence
// on everything the device reads (descriptor table, avail ring, command
// bodies, SUBMIT_3D payloads) before QUEUE_NOTIFY; cbo.inval on
// device-written lines (used ring, response buffers) before the CPU
// reads them.  The aperture at APU_SHM_BASE is DRAM in this testbench
// but a real guest maps it WC through Svpbmt; the probe emulates that
// with cbo.inval before reads and cbo.flush + fence after writes.
// VN_CBO_LINE is the D$ line stride (gen_venus_map.py).

#include <stdint.h>
#include "venus_map.h"
#include "virtio_mmio.h"
#include "tape.h"

#define VF_NEXT  0x1u
#define VF_WRITE 0x2u

/* ---- cache maintenance ---------------------------------------------- */
static inline void cbo_flush(uint64_t a) {
  asm volatile(".insn i 0x0f, 0x2, x0, 2(%0)" :: "r"(a) : "memory");
}
static inline void cbo_inval(uint64_t a) {
  asm volatile(".insn i 0x0f, 0x2, x0, 0(%0)" :: "r"(a) : "memory");
}
static inline void fence(void) { asm volatile("fence" ::: "memory"); }

static void flush_range(uint64_t base, uint64_t bytes) {
  for (uint64_t a = base & ~((uint64_t)VN_CBO_LINE - 1);
       a < base + bytes; a += VN_CBO_LINE)
    cbo_flush(a);
  fence();
}
static void inval_range(uint64_t base, uint64_t bytes) {
  for (uint64_t a = base & ~((uint64_t)VN_CBO_LINE - 1);
       a < base + bytes; a += VN_CBO_LINE)
    cbo_inval(a);
  fence();
}

/* ---- guest memory / aperture ---------------------------------------- */
static inline void gw32(uint64_t off, uint32_t v) {
  *(volatile uint32_t *)(VN_DMA_BASE + off) = v;
}
static inline uint32_t gr32(uint64_t off) {
  return *(volatile uint32_t *)(VN_DMA_BASE + off);
}
static inline void gh16(uint64_t off, uint16_t v) {
  *(volatile uint16_t *)(VN_DMA_BASE + off) = v;
}
static inline uint16_t grh16(uint64_t off) {
  return *(volatile uint16_t *)(VN_DMA_BASE + off);
}

/* aperture: device-written lines need inval before the load; CPU-written
 * lines need flush after the store. */
static uint32_t ap_rd(uint64_t off) {
  volatile uint32_t *p = (volatile uint32_t *)(VN_SHM_BASE + off);
  cbo_inval((uint64_t)p);
  fence();
  return *p;
}
static void ap_wr(uint64_t off, uint32_t v) {
  *(volatile uint32_t *)(VN_SHM_BASE + off) = v;
  cbo_flush(VN_SHM_BASE + off);
  fence();
}

static inline uint64_t rdcycle(void) {
  uint64_t v;
  asm volatile("rdcycle %0" : "=r"(v));
  return v;
}

/* ---- cookie / checkpoint mailbox ------------------------------------ */
/* Cookie: 64-bit word at VN_COOKIE_ADDR, polled by the TB through the
 * DRAM backing store.  Checkpoint mailbox: one 64 B line at
 * VN_MBX_ADDR; the sequence word sits at offset 0x3c so an ascending
 * writeback burst delivers it last.  The TB then evaluates the record
 * against the device hierarchy and deposits VN_MBX_ACK = seq. */
static void cookie(uint64_t v) {
  *(volatile uint64_t *)VN_COOKIE_ADDR = v;
  flush_range(VN_COOKIE_ADDR, 8);
}
static void fail(uint32_t step) {
  cookie(FAIL_BASE | (uint64_t)step);
  for (;;) { }
}

static uint32_t mbx_seq;
static void chkp(uint32_t kind, uint32_t ring, uint32_t arg,
                 uint64_t exp) {
  uint64_t b = VN_MBX_ADDR;
  volatile uint32_t *m = (volatile uint32_t *)b;
  m[0] = kind;
  m[1] = ring;
  m[2] = arg;
  m[4] = (uint32_t)exp;
  m[5] = (uint32_t)(exp >> 32);
  ++mbx_seq;
  m[15] = mbx_seq;                       /* 0x3c: last beat of the line */
  flush_range(b, 64);
  for (;;) {
    volatile uint32_t *a = (volatile uint32_t *)VN_MBX_ACK;
    cbo_inval((uint64_t)a);
    fence();
    if (*a == mbx_seq) break;
  }
}

/* ---- virtqueues ------------------------------------------------------ */
static uint32_t av_push[2], dcur[2], uexp[2];

static void put_desc(uint32_t q, uint32_t idx, uint64_t addr,
                     uint32_t len, uint16_t flags, uint16_t next) {
  uint64_t base = (q == 0 ? VN_Q0_DESC : VN_Q1_DESC);
  volatile uint32_t *d = (volatile uint32_t *)(base + 16 * idx);
  d[0] = (uint32_t)addr;
  d[1] = (uint32_t)(addr >> 32);
  d[2] = len;
  d[3] = ((uint32_t)next << 16) | flags;
}
static void push_avail(uint32_t q, uint32_t head) {
  uint64_t base = (q == 0 ? VN_Q0_AVAIL : VN_Q1_AVAIL);
  uint32_t num = q == 0 ? VN_Q0_NUM : VN_Q1_NUM;
  gh16(base + 4 + 2 * (av_push[q] % num) - VN_DMA_BASE,
       (uint16_t)head);
  gh16(base + 2 - VN_DMA_BASE, (uint16_t)(av_push[q] + 1));
  av_push[q]++;
  flush_range(base, 4 + 2 * num);
}

/* ---- tape/exp streams ------------------------------------------------- */
static const uint32_t *tp, *ep;
static uint32_t ntap(void) { return *tp++; }
static uint32_t nexp(void) { return *ep++; }
static int rec_kind(void) {
  if (ep[0] == 0xFFFFFFFFu && ep[1] == 0xFFFFFFFFu) return 0;
  return (int)ep[0];
}
static uint32_t ring_head_ap(const vn_session_t *s, uint32_t slot) {
  for (const uint32_t *r = s->rmap; r[0] != 0xff; r += 3)
    if (r[0] == slot) return r[1];
  return 0xFFFFFFFFu;
}
static uint32_t ring_status_ap(const vn_session_t *s, uint32_t slot) {
  for (const uint32_t *r = s->rmap; r[0] != 0xff; r += 3)
    if (r[0] == slot) return r[2];
  return 0xFFFFFFFFu;
}

/* ---- chain submit / expect ------------------------------------------- */
static uint32_t pend_head, pend_flags, pend_ridx;
static uint64_t pend_raddr, pend_fence;

static void chain_submit(void) {
  uint32_t nd = ntap();
  uint32_t head = dcur[0];
  pend_raddr = 0;
  for (uint32_t i = 0; i < nd; i++) {
    uint32_t a0 = ntap(), a1 = ntap(), dl = ntap(), dw = ntap();
    uint64_t a = ((uint64_t)a1 << 32) | a0;
    put_desc(0, (dcur[0] + i) % VN_Q0_NUM, VN_DMA_BASE + a, dl,
             (dw ? VF_WRITE : 0) | (i + 1 < nd ? VF_NEXT : 0),
             (uint16_t)((dcur[0] + i + 1) % VN_Q0_NUM));
    if (dw) pend_raddr = a;
  }
  /* chain may wrap the table; flush the whole descriptor region */
  flush_range(VN_Q0_DESC, 16 * VN_Q0_NUM);
  dcur[0] = (dcur[0] + nd) % VN_Q0_NUM;
  /* tape order: flags, fence_id lo, fence_id hi, cx, ring_idx */
  pend_flags = ntap();
  pend_fence = ntap();
  pend_fence |= (uint64_t)ntap() << 32;
  (void)ntap();                          /* cx */
  pend_ridx = ntap();
  pend_head = head;
  push_avail(0, head);
  vwr(VREG_QUEUE_NOTIFY, 0);
}

static uint32_t wait_used_idx(void) {
  /* poll used.idx until it advances past uexp[0] */
  uint64_t t0 = rdcycle();
  uint64_t u = VN_Q0_USED;
  for (;;) {
    inval_range(u, 8);
    if (grh16(u + 2 - VN_DMA_BASE) == (uint16_t)(uexp[0] + 1))
      break;
    if (rdcycle() - t0 > 20000000ull) fail(0x20);
  }
  /* used element {id,len} at used+4+8*pos */
  inval_range(u + 4 + 8 * (uexp[0] % VN_Q0_NUM), 8);
  return gr32(u + 8 + 8 * (uexp[0] % VN_Q0_NUM) - VN_DMA_BASE);
}

static void chain_expect(void) {
  uint32_t head = pend_head, flags = pend_flags, ridx = pend_ridx;
  uint64_t raddr = pend_raddr, fence_id = pend_fence;
  uint32_t ulen = wait_used_idx();
  /* INTERRUPT_STATUS bit0 then INTERRUPT_ACK <- 1 */
  if ((vrd(VREG_INTERRUPT_STATUS) & 1u) == 0) fail(0x21);
  vwr(VREG_INTERRUPT_ACK, 1);
  /* EK_RESP {kind, used_len, resp_type, nbody, 0,0,0,0} */
  if (rec_kind() != 1) fail(0x22);
  ep++;
  uint32_t e_used = nexp(), e_type = nexp(), e_nbody = nexp();
  ep += 4;
  if (ulen != e_used) fail(0x23);
  /* used element id == the head we pushed */
  uint64_t u = VN_Q0_USED;
  uint32_t eid = gr32(u + 4 + 8 * (uexp[0] % VN_Q0_NUM) - VN_DMA_BASE);
  if (eid != head) fail(0x24);
  uexp[0]++;
  /* response buffer: type word + nbody body words at +24 */
  if (raddr) {
    inval_range(VN_DMA_BASE + raddr, 24 + 4 * e_nbody);
    if (gr32(raddr) != e_type) fail(0x25);
    for (uint32_t i = 0; i < e_nbody; i++) {
      if (rec_kind() != 2) fail(0x26);
      ep++;
      if (gr32(raddr + 24 + 4 * i) != ep[0]) fail(0x27);
      ep += 7;
    }
  } else {
    for (uint32_t i = 0; i < e_nbody; i++) ep += 8;
  }
  if ((flags & 1u) != 0) {
    if (rec_kind() != 8) fail(0x28);
    ep += 8;
    /* fence pulse is not guest-visible; the TB checks the last
     * fence_pulse_o against this checkpoint */
    chkp(8, ridx, 0, fence_id);
  }
}

static void do_chain(void) { chain_submit(); chain_expect(); }

/* ---- TP_CHECK --------------------------------------------------------- */
static uint32_t ulpd(uint32_t a, uint32_t b) {
  if (a == b) return 0;
  if (((a & 0x7FFFFFFFu) == 0) && ((b & 0x7FFFFFFFu) == 0)) return 0;
  if ((a >> 23 & 0xFF) == 0xFF && (a & 0x7FFFFFu) &&
      (b >> 23 & 0xFF) == 0xFF && (b & 0x7FFFFFu)) return 0;
  if ((a >> 31) != (b >> 31)) return 0x7FFFFFFFu;
  return a > b ? a - b : b - a;
}

static void do_check(const vn_session_t *s) {
  uint32_t what = ntap(), a0 = ntap(), a1 = ntap();
  switch (what) {
  case 0: { /* CK_HEAD: aperture ring head word */
    if (rec_kind() != 3 || ep[1] != a0) fail(0x30);
    uint32_t ap = ring_head_ap(s, a0);
    if (ap == 0xFFFFFFFFu) chkp(3, a0, 0, ep[2]);
    else if (ap_rd(ap) != ep[2]) fail(0x31);
    ep += 8;
    break;
  }
  case 1: { /* CK_STATUS: aperture ring status word */
    if (rec_kind() != 4 || ep[1] != a0) fail(0x32);
    uint32_t ap = ring_status_ap(s, a0);
    if (ap == 0xFFFFFFFFu) chkp(4, a0, 0, ep[2]);
    else if ((ap_rd(ap) & ~1u) != (ep[2] & ~1u)) fail(0x33);
    ep += 8;
    break;
  }
  case 2:   /* CK_REPLY: a0 reply words at aperture offset a1 */
    for (uint32_t i = 0; i < a0; i++) {
      if (rec_kind() != 5) fail(0x34);
      ep++;
      if (ap_rd(a1 + 4 * ep[0]) != ep[1]) fail(0x35);
      ep += 7;
    }
    break;
  case 3:   /* CK_LIVE + EK_PAGES: internal state, TB-side check */
    if (rec_kind() != 6) fail(0x36);
    chkp(6, 0, 0, ep[1]);
    ep += 8;
    if (rec_kind() != 11) fail(0x37);
    chkp(11, 0, 0, ep[1]);
    ep += 8;
    break;
  case 4:   /* CK_EXTRA: ring extra region, aperture via TB */
    if (rec_kind() != 7) fail(0x38);
    chkp(7, a0, a1, ep[3]);
    ep += 8;
    break;
  case 6:   /* CK_APR: Gate-1/Gate-2 aperture readback */
    for (uint32_t i = 0; i < a0; i++) {
      if (rec_kind() != 10) fail(0x39);
      ep++;
      if (ep[0] != a1 + 4 * i) fail(0x3a);
      uint32_t got = ap_rd(a1 + 4 * i);
      if (got != ep[1]) fail(0x3b);
      if (ep[3] == 0) {
        if (got != ep[2]) fail(0x3c);
      } else if (ulpd(got, ep[2]) > 2) {
        fail(0x3d);
      }
      ep += 7;
    }
    break;
  default:
    fail(0x3f);
  }
}

/* ---- tape player ------------------------------------------------------ */
static void play(const vn_session_t *s) {
  tp = s->tape;
  ep = s->exp;
  for (;;) {
    uint32_t op = ntap();
    if (op == 0) break;
    switch (op) {
    case 1: {              /* TP_MEMW */
      uint32_t n = ntap(), al = ntap();
      (void)ntap();
      uint64_t base = VN_DMA_BASE + al;
      for (uint32_t i = 0; i < n; i++)
        *(volatile uint32_t *)(base + 4 * i) = ntap();
      flush_range(base, 4 * n);
      break;
    }
    case 2: do_chain(); break;
    case 3: {              /* TP_APW */
      uint32_t n = ntap(), al = ntap();
      (void)ntap();
      for (uint32_t i = 0; i < n; i++)
        ap_wr(al + 4 * i, ntap());
      break;
    }
    case 4: {              /* TP_WAIT_HEAD [ring][ap][exp][tmo] */
      uint32_t rg = ntap(), ad = ntap(), eh = ntap(), tmo = ntap();
      uint64_t t0 = rdcycle();
      while (ap_rd(ad) != eh)
        if (rdcycle() - t0 > tmo) fail(0x40);
      if (rec_kind() != 3 || ep[1] != rg || ep[2] != eh) fail(0x41);
      ep += 8;
      break;
    }
    case 5: {              /* TP_WAIT_IDLE [ring][ap][mask][want][tmo] */
      uint32_t rg = ntap(), ad = ntap(), mask = ntap(),
               want = ntap(), tmo = ntap();
      uint64_t t0 = rdcycle();
      while ((ap_rd(ad) & mask) != want)
        if (rdcycle() - t0 > tmo) fail(0x42);
      if (rec_kind() != 4 || ep[1] != rg) fail(0x45);
      /* RING_IDLE is a real-time pump timer the golden model's cycle
       * accounting cannot reproduce on a real hart; the mask/want poll
       * above already proved the bit transition. */
      if ((ep[2] & ~1u) != (ap_rd(ad) & ~1u)) fail(0x43);
      ep += 8;
      break;
    }
    case 6: do_check(s); break;
    case 7: {              /* TP_DELAY */
      uint32_t n = ntap();
      for (volatile uint32_t i = 0; i < n; i++) ;
      break;
    }
    default:
      fail(0x44);
    }
  }
}

/* ---- virtio probe ----------------------------------------------------- */
static void probe(void) {
  if (vrd(VREG_MAGIC) != VN_MAGIC) fail(1);
  if (vrd(VREG_VERSION) != VN_VERSION) fail(2);
  if (vrd(VREG_DEVICE_ID) != VN_DEVICE_ID) fail(3);
  if (vrd(VREG_VENDOR_ID) != VN_VENDOR) fail(4);
  vwr(VREG_STATUS, 0);
  vwr(VREG_STATUS, VN_ACKNOWLEDGE);
  vwr(VREG_STATUS, VN_ACKNOWLEDGE | VN_DRIVER);
  vwr(VREG_DEVICE_FEAT_SEL, 0);
  uint32_t flo = vrd(VREG_DEVICE_FEATURES);
  vwr(VREG_DEVICE_FEAT_SEL, 1);
  uint32_t fhi = vrd(VREG_DEVICE_FEATURES);
  if ((flo & (1u | (1u << 3) | (1u << 4))) != (1u | (1u << 3) | (1u << 4)))
    fail(5);
  if ((fhi & 1u) == 0 || (fhi & (1u << 8)) == 0) fail(6);
  vwr(VREG_DRIVER_FEAT_SEL, 0);
  vwr(VREG_DRIVER_FEATURES, flo);
  vwr(VREG_DRIVER_FEAT_SEL, 1);
  vwr(VREG_DRIVER_FEATURES, fhi);
  vwr(VREG_STATUS, VN_ACKNOWLEDGE | VN_DRIVER | VN_FEATURES_OK);
  if ((vrd(VREG_STATUS) & VN_FEATURES_OK) == 0) fail(7);
  vwr(VREG_SHM_SEL, 1);
  /* §12.3 F5: SHM_LEN is the guest-mappable span; the top of the
   * VN_SHM_BYTES window is the device-private descriptor arena */
  if (vrd(VREG_SHM_LEN_LO) != (uint32_t)VN_SHM_GUEST_BYTES) fail(8);
  if (vrd(VREG_SHM_LEN_HI) != (uint32_t)(VN_SHM_GUEST_BYTES >> 32))
    fail(9);
  if (vrd(VREG_SHM_BASE_LO) != (uint32_t)VN_SHM_BASE) fail(10);
  if (vrd(VREG_SHM_BASE_HI) != (uint32_t)(VN_SHM_BASE >> 32)) fail(11);
  vwr(VREG_SHM_SEL, 0);
  if (vrd(VREG_SHM_LEN_LO) != 0xFFFFFFFFu) fail(12);
  if (vrd(VREG_SHM_BASE_LO) != 0xFFFFFFFFu) fail(13);
  if (vrd(VCFG_NUM_CAPSETS) != VN_NUM_CAPSETS) fail(14);
  if (vrd(VCFG_NUM_SCANOUTS) != 0) fail(15);
  /* queue 0 (control): num 64; queue 1 (cursor): num 16 */
  vwr(VREG_QUEUE_SEL, 0);
  if (vrd(VREG_QUEUE_NUM_MAX) < VN_Q0_NUM) fail(16);
  vwr(VREG_QUEUE_NUM, VN_Q0_NUM);
  vwr(VREG_QUEUE_DESC_LO, (uint32_t)VN_Q0_DESC);
  vwr(VREG_QUEUE_DESC_HI, (uint32_t)(VN_Q0_DESC >> 32));
  vwr(VREG_QUEUE_AVAIL_LO, (uint32_t)VN_Q0_AVAIL);
  vwr(VREG_QUEUE_AVAIL_HI, (uint32_t)(VN_Q0_AVAIL >> 32));
  vwr(VREG_QUEUE_USED_LO, (uint32_t)VN_Q0_USED);
  vwr(VREG_QUEUE_USED_HI, (uint32_t)(VN_Q0_USED >> 32));
  vwr(VREG_QUEUE_READY, 1);
  vwr(VREG_QUEUE_SEL, 1);
  if (vrd(VREG_QUEUE_NUM_MAX) < VN_Q1_NUM) fail(17);
  vwr(VREG_QUEUE_NUM, VN_Q1_NUM);
  vwr(VREG_QUEUE_DESC_LO, (uint32_t)VN_Q1_DESC);
  vwr(VREG_QUEUE_DESC_HI, (uint32_t)(VN_Q1_DESC >> 32));
  vwr(VREG_QUEUE_AVAIL_LO, (uint32_t)VN_Q1_AVAIL);
  vwr(VREG_QUEUE_AVAIL_HI, (uint32_t)(VN_Q1_AVAIL >> 32));
  vwr(VREG_QUEUE_USED_LO, (uint32_t)VN_Q1_USED);
  vwr(VREG_QUEUE_USED_HI, (uint32_t)(VN_Q1_USED >> 32));
  vwr(VREG_QUEUE_READY, 1);
  vwr(VREG_STATUS, VN_ACKNOWLEDGE | VN_DRIVER | VN_FEATURES_OK |
                   VN_DRIVER_OK);
}

int main(void) {
  probe();
  for (uint32_t i = 0; i < VN_NUM_SESSIONS; i++) {
    play(&vn_sessions[i]);
    if (i == 0) cookie(PASS_TRANSPORT);
  }
  cookie(PASS_COMPUTE);
  for (;;) { }
}
