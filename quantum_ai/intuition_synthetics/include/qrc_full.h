/*
 * Copyright (c) 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 */
/* qrc_full.h — Quantum-Reversible C Standard Header (2035 Edition)
 * Public C ABI for physical / logical qubits and qRAM.
 * Implemented by the Rust crate `qrc_env` (see qrc_env.h for intuition).
 */
#ifndef QRC_FULL_H
#define QRC_FULL_H

#include <stdint.h>
#include <stddef.h>
#include <stdalign.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Opaque-ish register types (layout stable for FFI; do not mutate)    */
/* ------------------------------------------------------------------ */

typedef struct preg_t {
    alignas(64) double sin3[1];
    alignas(64) double cos3[1];
    uint64_t           mode_id;
    void*              hardware_ptr;
} preg_t;

typedef struct lreg_t {
    alignas(128) uint64_t logical_id;
    uint32_t              code_distance;
    uint32_t              patch_x, patch_y;
    void*                 syndrome_buffer;
    void*                 decoder_handle;
} lreg_t;

typedef struct qram_t {
    alignas(256) uint64_t base_addr;
    uint64_t              capacity_slots;
    uint32_t              data_width_bits;
    uint32_t              address_bits;
    void*                 storage_medium;
    double                coherence_time_s;
    double                recall_fidelity;
} qram_t;

typedef preg_t* preg_any;
typedef lreg_t* lreg_any;
typedef qram_t* qram_any;

/* ------------------------------------------------------------------ */
/* Lifecycle                                                          */
/* ------------------------------------------------------------------ */

preg_any qrc_preg_alloc(size_t n);
lreg_any qrc_lreg_alloc(size_t n);
qram_any qrc_qram_alloc(uint64_t capacity_slots, uint32_t data_width_bits);
void     qrc_preg_free(preg_any p);
void     qrc_lreg_free(lreg_any p);
void     qrc_qram_free(qram_any p);

/* ------------------------------------------------------------------ */
/* Physical layer                                                     */
/* ------------------------------------------------------------------ */

void P_H(preg_any q);
void P_X(preg_any q);
void P_Z(preg_any q);
void P_S(preg_any q);
void P_T(preg_any q);
void P_RZ(preg_any q, double phi);
void P_CNOT(preg_any c, preg_any t);
void P_CZ(preg_any c, preg_any t);
void P_Toffoli(preg_any c1, preg_any c2, preg_any t);
void P_Measure(preg_any q, int* out);

/* ------------------------------------------------------------------ */
/* Logical layer                                                      */
/* ------------------------------------------------------------------ */

void L_H(lreg_any q);
void L_X(lreg_any q);
void L_Z(lreg_any q);
void L_S(lreg_any q);
void L_T(lreg_any q);
void L_RZ(lreg_any q, double phi);
void L_CNOT(lreg_any c, lreg_any t);
void L_CZ(lreg_any c, lreg_any t);
void L_Toffoli(lreg_any c1, lreg_any c2, lreg_any t);
void L_Measure(lreg_any q, int* out);
void L_H_all(lreg_any q, size_t n);
void L_X_all(lreg_any q, size_t n);
void L_Measure_all(lreg_any q, size_t n, int* out_array);

/* ------------------------------------------------------------------ */
/* qRAM                                                               */
/* ------------------------------------------------------------------ */

void QRAM_LoadAddress(qram_any ram, uint64_t addr, lreg_any index);
void QRAM_Store(qram_any ram, lreg_any data);
void QRAM_Load(qram_any ram, lreg_any data);
void QRAM_LoadSuperposition(qram_any ram, lreg_any index, lreg_any data);
void QRAM_StoreSuperposition(qram_any ram, lreg_any index, lreg_any data);
void QRAM_LoadClassical(qram_any ram, uint64_t addr, lreg_any target);
void QRAM_StoreClassical(qram_any ram, uint64_t addr, lreg_any source);
void QRAM_StoreClassicalPacked(qram_any ram, uint64_t addr,
                               const void* blob, size_t n);

/* ------------------------------------------------------------------ */
/* Linear-algebra helpers                                             */
/* ------------------------------------------------------------------ */

void encode_vector_classical(const float* vec, size_t dim, lreg_any q);
void kernel_swap_test(lreg_any a, lreg_any b, lreg_any ancilla);
void L_HHL_solve(lreg_any b, qram_any matrix_ram, lreg_any x);
void amp_estimate(lreg_any flagged, double* p_hat, uint32_t shots);
void L_block_encode_oracle(qram_any ram, lreg_any sys);
void amp_estimate_to_dram(lreg_any flagged, double* dram_buffer,
                          size_t n, uint32_t shots);

#ifdef __cplusplus
}
#endif

#endif /* QRC_FULL_H */
