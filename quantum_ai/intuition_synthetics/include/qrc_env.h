/*
 * Copyright (c) 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 */
/* qrc_env.h — Environmental intuition C ABI
 *
 * World-as-qRAM: a stored environment (map, failures, affordances)
 * queried in one shot. Not AGI; late measurement over a palace of memory.
 */
#ifndef QRC_ENV_H
#define QRC_ENV_H

#include "qrc_full.h"
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t qrc_env_handle;

typedef struct qrc_vec3 {
    float x, y, z;
} qrc_vec3;

typedef struct qrc_pose {
    qrc_vec3 position;
    float    yaw;
} qrc_pose;

typedef struct qrc_keyframe {
    qrc_pose pose;
    float    occupancy;     /* 0 empty … 1 occupied */
    float    slip_risk;     /* historical failure density */
    float    affordance;    /* grasp / foothold quality */
    uint32_t flags;
} qrc_keyframe;

typedef struct qrc_hit {
    uint64_t   slot;
    qrc_keyframe frame;
    float      score;       /* estimated |⟨query|key⟩|² analogue */
} qrc_hit;

typedef struct qrc_plan_hint {
    qrc_vec3 next_foothold;
    qrc_vec3 avoid;
    float    confidence;
    uint32_t n_hits_used;
} qrc_plan_hint;

/* World memory ------------------------------------------------------ */

qrc_env_handle qrc_env_create(uint64_t capacity_slots);
void           qrc_env_destroy(qrc_env_handle env);
int            qrc_env_load_keyframe(qrc_env_handle env, uint64_t slot,
                                    const qrc_keyframe* kf);
int            qrc_env_load_batch(qrc_env_handle env, uint64_t base_slot,
                                  const qrc_keyframe* kfs, size_t n);
uint64_t       qrc_env_len(qrc_env_handle env);

/* Query: one superposition glance over the stored world ------------- */

int qrc_env_query(qrc_env_handle env,
                  const qrc_pose* query,
                  qrc_hit* out_hits,
                  size_t max_hits,
                  size_t* n_hits,
                  uint32_t shots);

int qrc_env_plan_hint(qrc_env_handle env,
                      const qrc_pose* here,
                      qrc_plan_hint* out);

/* Record a physical outcome so the palace grows --------------------- */

int qrc_env_remember_failure(qrc_env_handle env, const qrc_pose* where,
                             float severity);
int qrc_env_remember_success(qrc_env_handle env, const qrc_pose* where,
                             float quality);

#ifdef __cplusplus
}
#endif

#endif /* QRC_ENV_H */
