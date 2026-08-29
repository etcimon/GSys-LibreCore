/*
 * Copyright (c) 2026 Etienne Cimon
 * SPDX-License-Identifier: MIT
 */
/* Compile after `cargo build --release`:
 *   cc -Iinclude examples/c_consumer.c -Ltarget/release -lqrc_env -lpthread -ldl -lm -o /tmp/c_consumer
 */
#include "qrc_env.h"
#include <stdio.h>

int main(void) {
    qrc_env_handle env = qrc_env_create(1024);

    qrc_keyframe aisle = {
        .pose = { .position = { .x = 1.0f, .y = 0.0f, .z = 0.0f }, .yaw = 0.0f },
        .occupancy = 0.1f, .slip_risk = 0.05f, .affordance = 0.9f, .flags = 0
    };
    qrc_keyframe wet = {
        .pose = { .position = { .x = 1.2f, .y = 0.1f, .z = 0.0f }, .yaw = 0.0f },
        .occupancy = 0.2f, .slip_risk = 0.9f, .affordance = 0.1f, .flags = 1
    };
    qrc_env_load_keyframe(env, 0, &aisle);
    qrc_env_load_keyframe(env, 1, &wet);

    qrc_pose here = { .position = { .x = 1.05f, .y = 0.02f, .z = 0.0f }, .yaw = 0.0f };
    qrc_plan_hint hint;
    if (qrc_env_plan_hint(env, &here, &hint) == 0) {
        printf("foothold (%.2f, %.2f) avoid (%.2f, %.2f) conf %.3f\n",
               hint.next_foothold.x, hint.next_foothold.y,
               hint.avoid.x, hint.avoid.y, hint.confidence);
    }

    qrc_env_destroy(env);
    return 0;
}
