// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// T6b-3 exit / T6b-4a probe payload — see smt_mixed_probe.S for the contract.

#include <stdint.h>

extern volatile uint64_t tohost, fromhost;
extern uint64_t pgtbl_h0[512], pgtbl_h0_l1[512];
extern uint64_t pgtbl_h1[512], pgtbl_h1_l1[512];

#define PTE_PTR(tab) ((((uint64_t)(uintptr_t)(tab) >> 12) << 10) | 0x1)

#define PRIV0   ((volatile uint64_t *)0x84200000ULL) /* hart 0 private PA */
#define H1_PRIV ((volatile uint64_t *)0x40000000ULL) /* hart 1 window (VA) */
#define H0_VA   ((volatile uint64_t *)0x40000000ULL) /* hart 0 same-VA window */
#define SHARED  ((volatile uint64_t *)0x84020000ULL)
#define CLINT_MTIME     ((volatile uint64_t *)0x0200BFF8ULL)
#define CLINT_MTIMECMP0 ((volatile uint64_t *)0x02004000ULL)

#define RES_PASS      1u
#define RES_FAIL_CSUM 2u
#define RES_FAIL_TRAP 3u
#define RES_FAIL_IRQ  4u
#define RES_FAIL_PP   5u
#define RES_FAIL_TLB  6u

#ifndef EXPECT_CSUM
#define EXPECT_CSUM 0ULL   /* 0 = unchecked; build supplies the reference */
#endif

/* Timer: many short pending windows so a wrong-context decode (the
 * DECODE_ACTIVE_IRQ mutation) is hit during hart-1 decode while active=0. */
#define TMR_PERIOD 8000ULL   /* mtime ticks; rtc toggles every 4 cycles */
#define TMR_FIRES   48
/* Hart-1 kernel iterations: sustained decode/queue pressure for the whole
 * storm phase so partial kills find a live peer frontier (NO_PEER_RESTART
 * oracle) and decode lanes see hart-1 entries during act=0 windows. */
#define KMAX        24

#define WIT_WORDS 256
static uint64_t wit_pat(uint64_t i) { return 0xA5A5A5A500000000ULL | (i * 0x9E3779B1ULL); }
static uint64_t wit_pat2(uint64_t i) { return 0x5C5C5C5C00000000ULL | (i * 0x2545F491ULL); }

/* Shared verdict/handshake state — defined in .data by smt_mixed_probe.S so
 * the ELF payload (not .bss) carries the zero initialization. The harness
 * HTIF services only the exit path, so probe readout goes to PRT[] and is
 * recovered post-run from [smt-flow] store_commit records. */
extern volatile uint64_t RES[4];
extern volatile uint64_t timer_seen;
extern volatile uint64_t PRT[16];
/* 1 in the -DSOLO build, 0 otherwise — .data in the .S so both flavours have
 * byte-identical .text (the hart-1 commit stream is compared literally). */
extern volatile uint64_t probe_solo;
/* 1: hart 0's S-mode witness aliases hart 1's VA window (TLB-tag test).
 * 0 (-DNOALIAS): witness uses VA 0x4020_0000 — no aliasing (drained/anchor
 * models share the TLB untagged — documented pre-existing limitation). */
extern volatile uint64_t probe_tlb_alias;
/* hart 0 -> hart 1 handshake: hart 0 has finished its storm/isolation
 * phases; hart 1 may stop looping kernels and publish RES[1]. */
extern volatile uint64_t probe_done;

#define CSR_READ(csr, v) asm volatile("csrr %0, " #csr : "=r"(v))

/* PRT slot assignment */
#define PRT_H1_CSUM   0
#define PRT_H1_RET    1
#define PRT_H1_ACT    2
#define PRT_H1_CYC    3
#define PRT_H0_RET    4
#define PRT_H0_ACT    5
#define PRT_H0_CYC    6
#define PRT_H0_PP     7
#define PRT_H0_TMR    8
#define PRT_H0_TLB    9

static void __attribute__((noreturn)) xexit(uint64_t code);

static void __attribute__((noreturn)) xexit(uint64_t code)
{
  tohost = (code << 1) | 1;
  for (;;)
    asm volatile("wfi");
}

/* ------------------------------------------------------------------ */
/* hart 1: deterministic checksum kernels over its private VA window   */
/* ------------------------------------------------------------------ */

static uint64_t run_kernels(void)
{
  volatile uint64_t *d = H1_PRIV;
  uint64_t c = 0x9E3779B97F4A7C15ULL;

  /* K1: store->load chain (memdep shape). */
  for (int i = 0; i < 512; i++) d[i & 1023] = c ^ ((uint64_t)i * 0x100000001B3ULL);
  for (int i = 0; i < 512; i++) {
    c = (c << 5) | (c >> 59);
    c ^= d[i & 1023];
  }

  /* K2: pointer chase over the private region. */
  for (int i = 0; i < 512; i++) d[i] = (uint64_t)((i * 37) & 511);
  uint64_t p = 0;
  for (int i = 0; i < 512; i++) {
    p = d[p] & 511;
    c ^= p * 0x2545F4914F6CDD1DULL;
    c = (c << 7) | (c >> 57);
  }

  /* K3: independent multiply-accumulate chains (ILP). */
  uint64_t a = 1, b = 2, cc = 3;
  for (int i = 0; i < 512; i++) {
    a = a * 6364136223846793005ULL + 1442695040888963407ULL;
    b = b * 2862933555777941757ULL + 3037000493ULL;
    cc ^= a + b;
  }
  c ^= cc;

  /* K4: branchy accumulate — data-dependent direction mix. */
  uint64_t acc = 0;
  for (int i = 0; i < 512; i++) {
    if ((i * 2654435761u) & 8)
      acc += d[i & 511];
    else
      acc ^= (uint64_t)i;
  }
  c = c * 0xBF58476D1CE4E5B9ULL + acc;
  return c;
}

/* Speculative-store burst: shared-word stores-of-1 issued through spec_pad8
 * (the .S RAS-mispredict pad) — they are squashed on resolve and can never
 * commit on any model, so the shared words architecturally stay 0 and a
 * nonzero peer read is always a speculative-forwarding event. A
 * load-guarded variant deadlocked the LSQ (the guard load ordered behind
 * its own speculative stores and the stack fwd pair replayed forever), and
 * a branch-guarded variant leaked committed 1s (false positives on the
 * non-speculating anchor). */
static uint64_t burst_state = 0x9E3779B97F4A7C15ULL;

/* Tight data-dependent mispredict stream: two LFSR-driven branches per ~6
 * instructions so this hart mispredicts roughly every few cycles for a
 * stretch — meant to land kills inside a post-switch peer-leftover window. */
static void misp_burst(uint64_t seed)
{
  uint64_t x = seed | 1;
  for (int i = 0; i < 256; i++) {
    x = (x >> 1) ^ ((x & 1) ? 0xD800000000000000ULL : 0);
    if (x & 1)
      asm volatile("nop");
    if (x & 2)
      asm volatile("nop");
  }
  burst_state ^= x;
}

/* Speculative-store burst: shared-word stores-of-1 on a wrong-RAS path
 * whose resolve is delayed by two serial 64-bit divides (~70-120 cycles
 * in the speculative queue — see spec_pad8 in the .S file). A peer's pure read of
 * the same word forwards the youngest match: on a correct model its
 * own/committed entries win (peer spec entries are filtered); under
 * STB/LSQ_NO_HART the spec-1 is served.
 *
 * The stores are issued through spec_pad8 (see the .S file): they sit on a
 * path reachable only via a wrong RAS prediction, so they are squashed on
 * every model and can NEVER commit — the shared words architecturally stay
 * 0 and a nonzero read is always a speculative-forwarding event (earlier
 * guard+lagged-cleanup variants left a committed-1 window that produced
 * false positives on the non-speculating anchor model). */
extern void spec_pad8(volatile uint64_t *dst, uint64_t v, uint64_t divisor);

static void squash_burst(uint64_t i)
{
  uint64_t g = burst_state ^ (i * 0x9E3779B1ULL);
  g ^= g >> 29; g *= 0x2545F4914F6CDD1DULL;
  g ^= g >> 31; g *= 0x9E3779B97F4A7C15ULL;
  g ^= g >> 27; g *= 0xD6E8FEB86659FD93ULL;
  g ^= g >> 25;
  burst_state = g;
  int w = (int)(i & 56);                 /* 8-word block inside a 64-word set */
  spec_pad8(&SHARED[w], 1, 1);           /* divisor 1: ra=2f via two ~40cy divs */
}

void h1_s_entry(void)
{
  uint64_t t0, t1, r0, r1, a0, a1, b0, b1, c0, c1;
  CSR_READ(cycle, t0);
  CSR_READ(hpmcounter3, r0);
  CSR_READ(hpmcounter4, a0);
  CSR_READ(hpmcounter5, b0);
  CSR_READ(hpmcounter6, c0);
  uint64_t csum = run_kernels();
  CSR_READ(cycle, t1);
  CSR_READ(hpmcounter3, r1);
  CSR_READ(hpmcounter4, a1);
  CSR_READ(hpmcounter5, b1);
  CSR_READ(hpmcounter6, c1);
  PRT[PRT_H1_CSUM] = csum;
  PRT[PRT_H1_RET] = r1 - r0;
  PRT[PRT_H1_ACT] = a1 - a0;
  PRT[PRT_H1_CYC] = t1 - t0;
  PRT[12] = b1 - b0;             /* diag: grp1 idx1 (iq stall & act) */
  PRT[13] = c1 - c0;             /* diag: grp1 idx2 (mispredict & brh) */
  uint64_t bad = 0;
  if (EXPECT_CSUM && csum != (uint64_t)EXPECT_CSUM)
    bad++;
  /* Loop the kernel until hart 0 signals probe_done: sustained real-work
   * decode/queue presence during the storm (peer-frontier kills) plus dense
   * speculative shared-word stores between iterations (ping-pong witness).
   * misp_burst adds a tight mispredict stream so this hart resolves a bad
   * branch inside the ~10-30-cycle post-switch leftover window often enough
   * to kill the peer's queued parcels — the NO_PEER_RESTART oracle. */
  for (int it = 1; it < KMAX && !probe_done; it++) {
    uint64_t c2 = run_kernels();
    if (EXPECT_CSUM && c2 != (uint64_t)EXPECT_CSUM)
      bad++;
    misp_burst((uint64_t)it * 0x2545F491ULL + 1);
    for (int k = 0; k < 512; k++)
      squash_burst((uint64_t)k * 8 + it);
    if (probe_solo && it >= 4)
      break;   /* ~5 iterations of reference stream is ample */
  }
  RES[1] = bad ? RES_FAIL_CSUM : RES_PASS;
  asm volatile("fence rw, rw" ::: "memory");
  if (probe_solo)
    xexit(RES[1] == RES_PASS ? 0 : RES[1]);
  for (;;)
    asm volatile("wfi");
}

void hart1_main(void)
{
  /* M-mode setup: PMP grant-all for S-mode, counter access, own PMU event,
   * private Sv39 root, then drop to S-mode. */
  asm volatile("csrw pmpaddr0, %0" ::"r"(~0ULL >> 2));
  asm volatile("csrw pmpcfg0, %0" ::"r"(0x1F)); /* A=NAPOT|R|W|X */
  asm volatile("csrw mcounteren, %0" ::"r"(~0u));
  asm volatile("csrw mcountinhibit, %0" ::"r"(0));
  /* grp1 idx8 = retired instructions, grp1 idx9 = active cycles
   * (both per-hart banked). */
  asm volatile("csrw mhpmevent3, %0" ::"r"((uintptr_t)0x28));
  asm volatile("csrw mhpmevent4, %0" ::"r"((uintptr_t)0x29));
  asm volatile("csrw mhpmevent5, %0" ::"r"((uintptr_t)0x21)); /* iq stall&act */
  asm volatile("csrw mhpmevent6, %0" ::"r"((uintptr_t)0x22)); /* mispred&brh */
  { /* readback diagnostics (recovered via PRT in the flow log) */
    uint64_t e3, e4;
    CSR_READ(mhpmevent3, e3);
    CSR_READ(mhpmevent4, e4);
    PRT[10] = e3;
    PRT[11] = e4;
  }
  pgtbl_h1[1] = PTE_PTR(&pgtbl_h1_l1);   /* root[1] -> hart 1's L1 table */
  uintptr_t satp = (8ULL << 60) | ((uintptr_t)&pgtbl_h1 >> 12);
  asm volatile("csrw satp, %0" ::"r"(satp));
  asm volatile("sfence.vma");
  uintptr_t pc;
  asm volatile("la %0, h1_s_entry" : "=r"(pc));
  asm volatile("csrw mepc, %0" ::"r"(pc));
  uintptr_t ms;
  CSR_READ(mstatus, ms);
  ms = (ms & ~(3ULL << 11)) | (1ULL << 11); /* MPP=S */
  asm volatile("csrw mstatus, %0" ::"r"(ms));
  asm volatile("mret");
  __builtin_unreachable();
}

/* ------------------------------------------------------------------ */
/* hart 0: storm + isolation witness + timer accounting                */
/* ------------------------------------------------------------------ */

static uint64_t lfsr(uint64_t x)
{
  return (x >> 1) ^ ((x & 1) ? 0xD800000000000000ULL : 0);
}

static void storm_mispredict(void)
{
  /* ~50% taken, data-dependent — trains nothing, flushes constantly. */
  uint64_t x = 0x9E3779B97F4A7C15ULL, ctr = 0;
  for (int i = 0; i < 20000; i++) {
    x = lfsr(x);
    if (x & 1)
      ctr += x >> 32;
    else
      ctr ^= x;
    x = lfsr(x);
    if (x & 4)
      ctr -= i;
  }
  PRIV0[0] = ctr;
}

static void storm_replay(void)
{
  /* Pointer chase -> store -> dependent load to the same line: keeps
   * unresolved-store waits and memory-order replays firing. */
  volatile uint64_t *d = PRIV0 + 8;
  for (int i = 0; i < 256; i++) d[i] = (uint64_t)((i * 13 + 7) & 255);
  uint64_t p = 0, acc = 0;
  for (int i = 0; i < 8192; i++) {
    p = d[p] & 255;
    d[p ^ 64] = acc + i;      /* same-line store */
    acc ^= d[p ^ 64];         /* dependent load, store->load alias */
    d[(p + 1) & 255] = p;     /* perturb the chain deterministically */
  }
  PRIV0[1] = acc;
}

/* Store-isolation witness — pure reads, no own store in flight: the shared
 * words' newest *committed* value is ~always 0 (hart 1's burst writes a
 * speculative 1 then an unconditional 0 in program order). A nonzero read
 * can therefore only come from a *speculative* peer store forwarded across
 * harts (STB/LSQ_NO_HART) or a committed-1 race (~1-cycle window, thresholded).
 * An own st->ld pair cannot see it: the own store is always the youngest
 * match and a peer spec store can never outrank it. */
/* Interrupt-context witness: hart 0 spins with MTIP armed+enabled. While it
 * spins, act=0 holds and hart-1's queued instructions still occupy decode
 * lanes *while the active hart is 0 and the bank-0 timer is pending*. Under
 * G6LC_MUT_DECODE_ACTIVE_IRQ a hart-1 lane sees bank 0's pending+enabled
 * context and vectors on hart 0's timer — RES[1]=FAIL_IRQ. On a correct
 * model hart 0 takes its own tick.
 * (A wfi sleep here was replaced by a bounded spin: the inactive-hart
 * window built an eret+switch+restart interleave under which this hart's
 * restart fetch of a gigapage-mapped VA took an instruction page fault —
 * a fetch-side translation-context leak; see AGENTS-ooo-plan.md.) */
static void irq_witness(void)
{
  for (int j = 0; j < 96; j++) {
    *CLINT_MTIMECMP0 = *CLINT_MTIME + 120;
    /* The trap handler may already have disarmed MTIE after TMR_FIRES —
     * re-enable so this window is guaranteed a pending tick. */
    asm volatile("csrs mie, %0" ::"r"(1ULL << 7));
    for (int s = 0; s < 400; s++)
      asm volatile("nop" ::: "memory");
  }
}

static int ping_pong(void)
{
  int mismatch = 0;
  for (int i = 0; i < 8192; i++) {
    int w = (i * 8) & 63;
    for (int k = 0; k < 8; k++) {
      uint64_t v = SHARED[(w + k) & 63];
      if (v != 0)
        mismatch++;
    }
  }
  return mismatch;
}

/* TLB hart-tag witness: hart 0 briefly enters S-mode on its own Sv39 root,
 * which maps the SAME data VA window (0x4000_0000) to hart 0's private page
 * while hart 1's root maps it to hart 1's page. With hart tags intact the
 * two mappings coexist; without them one untagged entry serves both harts —
 * hart 0's reads then return hart 1's page contents (and its writes land in
 * hart 1's page). Runs early so it overlaps hart 1's kernel phase. */
extern volatile uint64_t tlb_bad; /* .data in the .S file */
static volatile uintptr_t h0_sp_save;

/* Called (not entered) by h0_s_stub in the .S file: runs in S-mode on
 * hart 0's own Sv39 root, then returns normally to the stub, which ecalls
 * back to M-mode and jumps to the h0_wit_done label inside storm_main.
 * .data is S-reachable via the identity gigapage leaf in root[2]. */
__attribute__((noinline)) void h0_s_witness(void)
{
  /* probe_tlb_alias selects the aliasing VA (0x4000_0000, same window as
   * hart 1 — the TLB-tag witness) or the non-aliased VA 0x4020_0000 (L1[1],
   * same PA page — used where the shared TLB is untagged by design). */
  volatile uint64_t *wv =
      (volatile uint64_t *)(0x40000000ULL + (probe_tlb_alias ? 0 : 0x200000));
  uint64_t bad = 0;
  for (int i = 0; i < WIT_WORDS; i++)
    if (wv[16 + i] != wit_pat(i))
      bad++;
  for (int i = 0; i < WIT_WORDS; i++)
    wv[16 + WIT_WORDS + i] = wit_pat2(i);
  tlb_bad += bad;
}

/* Returns-twice: the mret exits to h0_s_stub (S-mode), whose ecall jumps
 * back into storm_main at h0_wit_done — the caller must keep its frame and
 * continuation live across this call even though no ret ever runs. */
__attribute__((noinline, returns_twice)) static void tlb_witness(void)
{
  for (int i = 0; i < WIT_WORDS; i++)
    PRIV0[16 + i] = wit_pat(i);           /* bare-PA prefill */
  asm volatile("csrw pmpaddr0, %0" ::"r"(~0ULL >> 2));
  asm volatile("csrw pmpcfg0, %0" ::"r"(0x1F));
  pgtbl_h0[1] = PTE_PTR(&pgtbl_h0_l1);   /* root[1] -> hart 0's L1 table */
  uintptr_t satp = (8ULL << 60) | ((uintptr_t)&pgtbl_h0 >> 12);
  asm volatile("csrw satp, %0" ::"r"(satp));
  asm volatile("sfence.vma");
  uintptr_t pc;
  asm volatile("la %0, h0_s_stub" : "=r"(pc));
  asm volatile("csrw mepc, %0" ::"r"(pc));
  uintptr_t ms;
  CSR_READ(mstatus, ms);
  ms = (ms & ~(3ULL << 11)) | (1ULL << 11); /* MPP=S */
  asm volatile("csrw mstatus, %0" ::"r"(ms));
  asm volatile("mret");
  /* unreachable at runtime — left reachable to the compiler so the call
   * site in storm_main keeps its post-call continuation (h0_wit_done). */
}

static void timer_arm(void)
{
  *CLINT_MTIMECMP0 = *CLINT_MTIME + TMR_PERIOD;
  uintptr_t v;
  asm volatile("csrs mie, %0" ::"r"(1ULL << 7));      /* MTIE */
  CSR_READ(mstatus, v);
  v |= (1ULL << 3);                                    /* MIE */
  asm volatile("csrw mstatus, %0" ::"r"(v));
}

void storm_main(void)
{
  /* Solo build: park hart 0 so hart 1 runs alone (the reference stream). */
  if (probe_solo) {
    for (;;)
      asm volatile("wfi");
  }
  /* own PMU: grp1 idx8 = retired, idx9 = active cycles */
  asm volatile("csrw mhpmevent3, %0" ::"r"((uintptr_t)0x28));
  asm volatile("csrw mhpmevent4, %0" ::"r"((uintptr_t)0x29));
  uint64_t r0, c0, a0;
  CSR_READ(mhpmcounter3, r0);
  CSR_READ(mhpmcounter4, a0);
  CSR_READ(mcycle, c0);
  timer_arm();
  asm volatile("mv %0, sp" : "=r"(h0_sp_save));
  tlb_witness();
  /* The ecall inside h0_s_stub resumes here (handler mepc+4 -> j h0_wit_done)
   * — a normal call return is impossible because the stub was entered by
   * mret and owns no return address. tlb_witness's frame was abandoned by
   * the mret, so restore sp before touching storm_main locals. */
  asm volatile(".p2align 2\n"
               ".globl h0_wit_done\n"
               "h0_wit_done:\n"
               "1: auipc t0, %pcrel_hi(h0_sp_save)\n"
               "   ld    sp, %pcrel_lo(1b)(t0)");
  /* Phase-C verify: the S-mode stores must have landed in hart 0's own
   * private page — if a peer's untagged mapping served them they went to
   * the peer's page instead. */
  for (int i = 0; i < WIT_WORDS; i++)
    if (PRIV0[16 + WIT_WORDS + i] != wit_pat2(i))
      tlb_bad++;
  PRT[PRT_H0_TLB] = tlb_bad;
  storm_mispredict();
  storm_replay();
  irq_witness();
  /* Witness baseline: spec-pad stores never commit, so the shared words are
   * architecturally 0 — a nonzero read is always a forwarding event. */
  for (int i = 0; i < 64; i++)
    SHARED[i] = 0;
  asm volatile("fence rw, rw" ::: "memory");
  /* Ping-pong runs while hart 1 is still looping kernels + squash bursts —
   * its in-flight speculative 1-stores are what the witness probes. */
  int mm = ping_pong();
  /* Tell hart 1 the storm phase is over; it publishes RES[1] next. */
  probe_done = 1;
  while (RES[1] == 0)
    ;
  uint64_t r1, c1, a1;
  CSR_READ(mhpmcounter3, r1);
  CSR_READ(mhpmcounter4, a1);
  CSR_READ(mcycle, c1);
  PRT[PRT_H0_RET] = r1 - r0;
  PRT[PRT_H0_ACT] = a1 - a0;
  PRT[PRT_H0_CYC] = c1 - c0;
  PRT[PRT_H0_PP] = (uint64_t)mm;
  PRT[PRT_H0_TMR] = timer_seen;
  /* Spec-pad stores can never commit, so the clean count is 0 by
   * construction; a small threshold guards stray transient effects. */
  if (mm > 4) {
    RES[0] = RES_FAIL_PP;
  } else if (timer_seen < 2 || tlb_bad != 0) {
    RES[0] = RES_FAIL_TLB;
  } else {
    RES[0] = RES_PASS;
  }
  asm volatile("fence rw, rw" ::: "memory");
  xexit((RES[0] == RES_PASS && RES[1] == RES_PASS) ? 0 : 0x100 | RES[1]);
}

/* ------------------------------------------------------------------ */
/* shared M trap handler                                               */
/* ------------------------------------------------------------------ */

uint64_t m_trap_c(uint64_t hart)
{
  uint64_t mcause;
  CSR_READ(mcause, mcause);
  if (mcause == 9 && hart == 0) {
    /* hart 0's deliberate ecall leaving its S-mode witness: resume in
     * M-mode at the instruction after the ecall. */
    uint64_t ep, ms;
    CSR_READ(mepc, ep);
    CSR_READ(mstatus, ms);
    asm volatile("csrw mepc, %0" ::"r"(ep + 4));
    /* MPP=M, MPIE=1: the timer is armed with mstatus.MIE before the S-mode
     * excursion; the mret below restores MIE from MPIE, which reset to 0 and
     * was never re-armed, so without this bit M-mode interrupts stay masked
     * for the rest of storm_main and the MTI never delivers. */
    asm volatile("csrw mstatus, %0" ::"r"(ms | (3ULL << 11) | (1ULL << 7)));
    return 1;
  }
  if ((mcause >> 63) && (mcause & 0xff) == 7 && hart == 0) {
    /* hart 0's expected timer tick: count and keep re-arming for many
     * short pending windows (the DECODE_ACTIVE_IRQ exposure). */
    timer_seen++;
    if (timer_seen < TMR_FIRES)
      *CLINT_MTIMECMP0 = *CLINT_MTIME + TMR_PERIOD;
    else
      asm volatile("csrc mie, %0" ::"r"(1ULL << 7));
    return 1;
  }
  uint64_t verdict =
      ((mcause >> 63) && (mcause & 0xff) == 7) ? RES_FAIL_IRQ : RES_FAIL_TRAP;
  RES[hart & 3] = verdict;
  PRT[15] = mcause;              /* trap forensics for the log parser */
  asm volatile("fence rw, rw" ::: "memory");
  if (probe_solo) {
    /* Solo build: hart 0 is parked; a fatal trap on hart 1 exits itself. */
    xexit(0x300 | verdict);
  } else if (hart == 0) {
    xexit(0x200 | verdict); /* hart 0 owns tohost; a hart-1 verdict parks and
                               lets hart 0 report it. */
  }
  return 0;
}
