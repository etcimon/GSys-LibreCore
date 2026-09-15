// SPDX-License-Identifier: MIT
// Stub for core/id_stage.sv DPI. Testharness owns the real peek.
extern "C" int g6lc_dram_peek64(long long addr, long long *data) {
  (void)addr;
  if (data)
    *data = 0;
  return 0;
}
