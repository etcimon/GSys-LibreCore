#version 310 es
// SPDX-License-Identifier: MIT
// dEQP-VK.memory.pipeline_barrier index/storage/uniform render shape
// (verbatim body): no vertex input, the point position derives from
// gl_VertexIndex on a 256x256 grid.
precision highp float;
void main (void) {
	gl_PointSize = 1.0;
	highp vec2 pos = vec2(gl_VertexIndex % 256, gl_VertexIndex / 256) / vec2(255.0);
	gl_Position = vec4(1.998 * pos - vec2(0.999), 0.0, 1.0);
}
