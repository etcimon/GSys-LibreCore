/* Copyright (c) 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 *
 * C ABI surface for Xg6lcai / ai-tensor (Desc64 + completion + status).
 * Hand-maintained lockstep with crates/ai-tensor-abi (no cbindgen required yet).
 * Framework C++ extensions (torch/tf) should include this header, not invent layouts.
 */
#ifndef AI_TENSOR_H
#define AI_TENSOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AI_TENSOR_DESC_BYTES 64
#define AI_TENSOR_CONTRACT_VERSION 1

#define AI_TENSOR_OP_GEMM 1
#define AI_TENSOR_OP_CONV2D 2
#define AI_TENSOR_OP_LAYOUT 3
#define AI_TENSOR_OP_PREFETCH 4

#define AI_TENSOR_ST_OK 0
#define AI_TENSOR_ST_ERR 1
#define AI_TENSOR_ST_BAD_VER 2
#define AI_TENSOR_ST_BAD_OP 3
#define AI_TENSOR_ST_BAD_PTR 4
#define AI_TENSOR_ST_BAD_QID 5
#define AI_TENSOR_ST_DISABLED 6
#define AI_TENSOR_ST_WATCHDOG 7

/** flags[2] — request completion IRQ when sticky IRQ is wired. */
#define AI_TENSOR_FLAG_IRQ (1u << 2)

/**
 * Host view of the 64-byte LE T2 descriptor (field order matches pack()).
 * Prefer packing via the Rust/Python stack; this documents the wire format.
 */
typedef struct ai_tensor_desc64 {
  uint16_t version; /* CONTRACT_VERSION */
  uint16_t op;      /* OP_GEMM, … */
  uint32_t flags;
  uint32_t m;
  uint32_t n;
  uint32_t k;
  uint32_t ld_ab; /* lda | (ldb << 16) */
  uint64_t ptr_a;
  uint64_t ptr_b;
  uint64_t ptr_c;
  uint64_t ptr_scale;
  uint64_t ptr_done;
} ai_tensor_desc64;

/** Completion word: ticket [31:0], status [47:32]. */
static inline uint64_t ai_tensor_completion_make(uint32_t ticket, uint16_t status) {
  return ((uint64_t)status << 32) | (uint64_t)ticket;
}

static inline uint32_t ai_tensor_completion_ticket(uint64_t w) {
  return (uint32_t)w;
}

static inline uint16_t ai_tensor_completion_status(uint64_t w) {
  return (uint16_t)((w >> 32) & 0xffffu);
}

/* Island MMIO offsets (byte, relative to base e.g. 0x4000_0000 on Variane). */
#define AI_TENSOR_MMIO_CTL 0x0100u
#define AI_TENSOR_MMIO_STATUS 0x0104u
#define AI_TENSOR_MMIO_DOORBELL 0x0108u
#define AI_TENSOR_MMIO_DONE 0x010Cu
#define AI_TENSOR_MMIO_TICKET 0x0110u
#define AI_TENSOR_MMIO_DSTATUS 0x0114u
#define AI_TENSOR_MMIO_DESC_PTR_LO 0x0118u
#define AI_TENSOR_MMIO_DESC_PTR_HI 0x011Cu
#define AI_TENSOR_MMIO_REG0 0x0120u
#define AI_TENSOR_MMIO_DESC 0x0140u
#define AI_TENSOR_MMIO_PMU_R 0x0180u
#define AI_TENSOR_MMIO_PMU_W 0x0184u
#define AI_TENSOR_MMIO_PMU_CY 0x0188u
#define AI_TENSOR_MMIO_PMU_GBPS 0x018Cu

#define AI_TENSOR_CTL_ENABLE (1u << 0)
#define AI_TENSOR_CTL_WR_CPL_EN (1u << 1)
#define AI_TENSOR_DOORBELL_FETCH (1u << 31)

#ifdef __cplusplus
}
#endif

#endif /* AI_TENSOR_H */
