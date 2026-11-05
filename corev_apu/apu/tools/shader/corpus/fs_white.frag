#version 310 es
// SPDX-License-Identifier: MIT
// dEQP-VK.memory.pipeline_barrier render-white.frag (verbatim body): no
// inputs, constant white.
layout(location = 0) out highp vec4 o_color;
void main (void) {
	o_color = vec4(1.0);
}
