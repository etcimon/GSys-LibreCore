#version 450
// SPDX-License-Identifier: MIT
// Graphics-stage descriptor read (CTS binding_model.*.graphics shape):
// the fragment colour comes from a uniform buffer bound at the GRAPHICS
// bind point (set 0, binding 0).
layout(set = 0, binding = 0) uniform U { vec4 c; } u;
layout(location = 0) out vec4 o;
void main() { o = u.c; }
