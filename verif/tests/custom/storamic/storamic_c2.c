// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// C2 native-topology firmware for the real ariane_testharness. Runs in M-mode
// against the Storamic window at 0x5000_0000 (G6LC_STORAMIC primary role).
// Every access lands on an IMPLEMENTED g6lc_storamic_regs / virtio register so
// the served pages answer OKAY; the monitor (g6lc_storamic_c2_monitor.sv)
// requires served=>OKAY and unserved=>error strictly.
//
//   * word read of implemented control regs: ID(0x000) VERSION(0x004)
//     CONFIG(0x008) STATUS(0x00C) CAPS(0x010)  -> ar_source_ok under probe
//   * word write + read-back of irq_enable(0x018), a writable reg -> aw/ar src_ok
//   * byte and halfword reads at implemented word offsets (size!=2 -> no src_ok)
//   * word read of the virtio page (Base+0x1000, served, not control -> no src_ok)
//   * hole read+write at Base+0x8000 (in the 1 MiB rule, outside served pages
//     -> error response; observed to complete without a trap). NB Base+0x3000
//     is the harness sim-only power-cut register, NOT a hole.
//   * back-to-back interleaved stores/loads to the control page for overlap
// Exits via tohost with a deterministic pass code. Under the origin probe the
// well-formed word control-page accesses raise source_ok; without it the CPU
// emits prot 000 and they must not. Verdict lives in the monitor / run_native_c2.

#include <stdint.h>

#define STORAMIC_BASE 0x50000000UL
#define CTRL_PAGE     (STORAMIC_BASE + 0x0000UL)   // 4 KiB control page
#define VIRTIO_PAGE   (STORAMIC_BASE + 0x1000UL)   // virtio MMIO page
#define HOLE          (STORAMIC_BASE + 0x8000UL)   // reserved -> DECERR

// Implemented g6lc_storamic_regs offsets (word addressed, <0x100 block).
#define R_ID        0x000UL   // "STRM" magic
#define R_VERSION   0x004UL
#define R_CONFIG    0x008UL
#define R_STATUS    0x00CUL
#define R_CAPS      0x010UL
#define R_IRQ_EN    0x018UL   // writable (4-bit enable, s_mask gated)
#define R_FAULTS    0x014UL   // W1C

extern volatile uint64_t tohost;
extern volatile uint64_t fromhost;

static inline uint32_t ldl(const volatile void *p) {
  uint32_t v; __asm__ volatile("lw %0, 0(%1)" : "=r"(v) : "r"(p)); return v;
}
static inline void stl(volatile void *p, uint32_t v) {
  __asm__ volatile("sw %0, 0(%1)" :: "r"(v), "r"(p));
}
static inline uint8_t ldb(const volatile void *p) {
  uint8_t v; __asm__ volatile("lb %0, 0(%1)" : "=r"(v) : "r"(p)); return v;
}
static inline uint16_t ldh(const volatile void *p) {
  uint16_t v; __asm__ volatile("lh %0, 0(%1)" : "=r"(v) : "r"(p)); return v;
}

int main(void) {
  uint32_t id0, ver, cfg, caps, st0, irqen, acc;
  uint32_t b0, h0, virt, hole_v = 0;

  acc = 0;

#ifdef STORAMIC_DELAY_EARLY
  // +storamic_sba_probe support: the fesvr producer thread only reaches
  // preload_aware_dtm_t::reset() (where the DMI SBA sequence runs) after the
  // full dm_top init handshake — well past this firmware's ~1k-cycle run.
  // Spin on registers only (no memory ops -> identical AXI counts) so the
  // debug module's SBA read+write land before the control-page traffic.
  {
    uint64_t d = 0x9E3779B97F4A7C15ULL;
    for (uint64_t i = 0; i < 200000ULL; i++) {
      d ^= d << 13; d ^= d >> 7; d ^= d << 17;
      __asm__ volatile("" : "+r"(d));
    }
    (void)d;
  }
#endif

  // No trap handler is installed: observed on both models, the in-rule-but-
  // unserved hole answers with an error response and execution simply
  // continues (no access fault is taken). crt.S keeps its default handler, so
  // an unexpected trap would exit with a failure code rather than hang.

  // ---- word reads of implemented control regs (4 AR, control page) ----
  id0  = ldl((void *)(CTRL_PAGE + R_ID));
  ver  = ldl((void *)(CTRL_PAGE + R_VERSION));
  cfg  = ldl((void *)(CTRL_PAGE + R_CONFIG));
  st0  = ldl((void *)(CTRL_PAGE + R_STATUS));
  caps = ldl((void *)(CTRL_PAGE + R_CAPS));
  acc ^= id0 ^ ver ^ cfg ^ st0 ^ caps;

  // ---- word write + read-back of irq_enable (1 AW + 1 AR, control page) --
  // irq_enable is writable and reads back its 4-bit state; writing 0 disables
  // all IRQ sources (already disabled in this bare-metal context -> benign).
  stl((void *)(CTRL_PAGE + R_IRQ_EN), 0x0UL);
  irqen = ldl((void *)(CTRL_PAGE + R_IRQ_EN));

  // ---- byte and halfword reads at implemented word offsets ---------------
  // size!=2 so they do NOT match the native source_ok shape, but they are
  // served (map to the word register) and must still answer OKAY.
  b0 = ldb((void *)(CTRL_PAGE + R_ID));        // low byte of ID
  h0 = ldh((void *)(CTRL_PAGE + R_VERSION));   // low half of VERSION
  acc ^= (uint32_t)b0 ^ ((uint32_t)h0 << 8);

  // ---- word read of the virtio page (served, not control -> no src_ok) ---
  virt = ldl((void *)(VIRTIO_PAGE + 0x000UL));
  acc ^= virt;

  // ---- hole accesses: error responses -------------------------------------
  // The bridge answers DECERR for in-rule-but-unserved offsets. Observed on
  // both models: the monitor records err_resp for both beats and execution
  // continues to completion. The error-response proof lives in the monitor
  // (unserved=>error enforced, err_resp counted); here we only require the
  // accesses to complete without hanging.
  hole_v = ldl((void *)HOLE);
  (void)hole_v;
  stl((void *)HOLE, 0xDEADBEEFUL);

  // ---- back-to-back interleaved stores/loads to the control page ---------
  // Alternating AW/W then AR/R keeps a write and a read outstanding together
  // (the bridge is one-deep per direction but the channels are independent).
  for (int i = 0; i < 8; i++) {
    stl((void *)(CTRL_PAGE + R_IRQ_EN), 0x0UL);      // word write -> src_ok
    acc += ldl((void *)(CTRL_PAGE + R_ID));          // word read  -> src_ok
  }

  // ---- deterministic pass/fail via main's return (crt.S _exit encodes) ----
  // Return 0 on pass. Fail bits (diagnostic):
  //   bit0: ID magic != "STRM"
  //   bit1: irq_enable read-back != 0 after writing 0
  // Reaching here means virtio + hole + interleave all survived (no hang).
  // The hole's error response is asserted by the monitor (err_resp / unserved).
  int fail = 0;
  if (id0 != 0x5354524DUL)       fail |= 1;
  if (irqen != 0x0UL)            fail |= 2;
  (void)acc; (void)b0; (void)h0; (void)virt; (void)cfg; (void)caps;
  return fail;
}
