#version 450
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// The copied descriptor must reach array element 1, not the red element 0.
layout(set = 0, binding = 0) uniform U { vec4 c; } u[2];
layout(location = 0) out vec4 o;
void main() { o = u[1].c; }
