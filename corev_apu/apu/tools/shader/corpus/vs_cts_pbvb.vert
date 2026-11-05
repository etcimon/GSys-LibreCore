#version 310 es
// SPDX-License-Identifier: MIT
// dEQP-VK.memory.pipeline_barrier vertex-buffer render shader (verbatim
// body): RG8_UNORM position -> one point per pixel centre of the target.
layout(location = 0) in highp vec2 a_position;
void main (void) {
	gl_PointSize = 1.0;
	gl_Position = vec4(1.998 * a_position - vec2(0.999), 0.0, 1.0);
}
