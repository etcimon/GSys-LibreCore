/*
 * Copyright (c) 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 *
 * qrc_humanoid.h — Virtual humanoid embodiment C ABI
 *
 * Exposes the sensor, motor, circulatory and nervous-system stubs described in
 * AGENTS.md. This is a *simulated* humanoid: the images are not rendered, the
 * muscles do not solve multi-body dynamics, but the wiring from captors through
 * the cervical bus to the quantum-reversible runtime is real.
 *
 * See quantum_ai/intuition_synthetics/src/humanoid.rs for the Rust side.
 */
#ifndef QRC_HUMANOID_H
#define QRC_HUMANOID_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t qrc_humanoid_handle;

/* ------------------------------------------------------------------ */
/* 3D types (same layout as qrc_vec3 in qrc_env.h)                     */
/* ------------------------------------------------------------------ */

typedef struct qrc_hvec3 {
    float x, y, z;
} qrc_hvec3;

typedef struct qrc_hpose {
    qrc_hvec3 position;
    float     yaw;
} qrc_hpose;

/* ------------------------------------------------------------------ */
/* Captors / sensors                                                   */
/* ------------------------------------------------------------------ */

/* Camera focus command: converge both eyes on this world point. */
int qrc_hu_look_at(qrc_humanoid_handle h, qrc_hvec3 world_point);

/* Read the current head pose and gaze. */
int qrc_hu_head_pose(qrc_humanoid_handle h, qrc_hpose* out);

/* Read the flattened captor vector. The caller provides `out` of length
 * `qrc_hu_sensor_dimension(h)`; `n_written` is set to the actual count. */
int qrc_hu_sensor_frame(qrc_humanoid_handle h,
                        float* out, size_t max, size_t* n_written);

/* Set one captor cell manually (for diagnostics / test fixtures). */
int qrc_hu_set_thermo(qrc_humanoid_handle h, uint16_t part, uint8_t idx,
                      float kelvin);
int qrc_hu_set_touch(qrc_humanoid_handle h, uint16_t part, uint8_t idx,
                     float pressure, float proximity, float shear);

/* ------------------------------------------------------------------ */
/* Motors / articulation                                               */
/* ------------------------------------------------------------------ */

/* Command one joint to a target angle (radians) with a requested effort. */
int qrc_hu_articulate(qrc_humanoid_handle h, uint16_t joint_id,
                      float target_rad, float effort);

/* Read the flattened motor state vector. */
int qrc_hu_motor_frame(qrc_humanoid_handle h,
                       float* out, size_t max, size_t* n_written);

/* ------------------------------------------------------------------ */
/* Physiology                                                          */
/* ------------------------------------------------------------------ */

/* Open / close the zipper-ring service port behind the neck. */
int qrc_hu_zipper_open(qrc_humanoid_handle h);
int qrc_hu_zipper_replace_cord(qrc_humanoid_handle h, uint8_t cord_idx);
int qrc_hu_zipper_sealed(qrc_humanoid_handle h);

/* Read circulatory state. */
typedef struct qrc_hu_circulation {
    float stator_pressure_kpa;
    float stator_temp_k;
    float stator_flow_lpm;
    float rotor_pressure_kpa;
    float rotor_temp_k;
    float rotor_flow_lpm;
    uint32_t purge_cycles;
} qrc_hu_circulation;

int qrc_hu_get_circulation(qrc_humanoid_handle h, qrc_hu_circulation* out);

/* ------------------------------------------------------------------ */
/* Nervous / intuition integration                                     */
/* ------------------------------------------------------------------ */

/* Bind a qrc_env world handle to this humanoid. The world is pre-loaded
 * elsewhere and then queried, never rebuilt (rule 1). */
int qrc_hu_bind_env(qrc_humanoid_handle h, uint64_t env_handle);

/* Run one embodiment tick: sensors -> cervical bus -> quantum query (if bound)
 * -> motor actuators. dt_s is the simulation step. */
int qrc_hu_tick(qrc_humanoid_handle h, float dt_s);

/* Convenience: total sensor + motor scalar count. */
size_t qrc_hu_sensor_dimension(qrc_humanoid_handle h);
size_t qrc_hu_motor_dimension(qrc_humanoid_handle h);

/* ------------------------------------------------------------------ */
/* Lifecycle                                                           */
/* ------------------------------------------------------------------ */

qrc_humanoid_handle qrc_hu_create(void);
void                qrc_hu_destroy(qrc_humanoid_handle h);

#ifdef __cplusplus
}
#endif

#endif /* QRC_HUMANOID_H */
