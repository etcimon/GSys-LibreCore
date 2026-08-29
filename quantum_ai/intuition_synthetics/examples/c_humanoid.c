/*
 * Copyright (c) 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 *
 * Minimal C consumer of qrc_humanoid.h.
 *
 * Build (Windows, after `cargo build --release`):
 *   cl /Iinclude examples\c_humanoid.c /link target\release\qrc_env.dll.lib
 * Or with the .lib renamed to qrc_env.lib:
 *   cl /Iinclude examples\c_humanoid.c /link qrc_env.lib
 */

#include <stdio.h>
#include <string.h>
#include "qrc_humanoid.h"

int main(void) {
    qrc_humanoid_handle h = qrc_hu_create();
    if (h == 0) {
        printf("failed to create humanoid\n");
        return 1;
    }

    printf("sealed after creation: %d\n", qrc_hu_zipper_sealed(h));

    /* Point the head and converge the eyes. */
    qrc_hvec3 look = {1.0f, 0.0f, 5.0f};
    qrc_hu_look_at(h, look);

    /* Flex the left elbow about 30 degrees. */
    qrc_hu_articulate(h, 22, 0.52f, 0.8f);

    /* Run one second of simulation. */
    for (int i = 0; i < 100; i++) {
        qrc_hu_tick(h, 0.01f);
    }

    /* Read motor state. */
    size_t m = qrc_hu_motor_dimension(h);
    printf("motor frame dimension: %zu\n", m);

    /* Read circulatory state. */
    qrc_hu_circulation circ;
    if (qrc_hu_get_circulation(h, &circ) == 0) {
        printf("rotor oil: %.0f kPa, %.1f K\n", circ.rotor_pressure_kpa, circ.rotor_temp_k);
    }

    qrc_hu_destroy(h);
    return 0;
}
