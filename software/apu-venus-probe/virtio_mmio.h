// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// virtio-mmio register access for the bare-metal Venus probe.  All
// offsets/constants come from venus_map.h, generated out of
// g6lc_apu_pkg.sv + g6lc_apu_cfg_pkg.sv by tools/gen_venus_map.py —
// nothing here retypes the map.

#ifndef VIRTIO_MMIO_H
#define VIRTIO_MMIO_H

#include <stdint.h>
#include "venus_map.h"

/* The MMIO window is non-cacheable on this hart.  Loads to a different
 * address may bypass a store still queued in the LSU, so every device
 * access is fenced: a store must be drained before a dependent read,
 * and a read must complete before a subsequent store can reorder the
 * driver's protocol.  `fence` drains the store buffer and stalls the
 * pipeline until the LSU is empty. */
static inline uint32_t vrd(uint32_t off) {
  uint32_t v;
  asm volatile("fence" ::: "memory");
  v = *(volatile uint32_t *)(VN_MMIO_BASE + off);
  asm volatile("fence" ::: "memory");
  return v;
}
static inline void vwr(uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(VN_MMIO_BASE + off) = v;
  asm volatile("fence" ::: "memory");
}

#endif
