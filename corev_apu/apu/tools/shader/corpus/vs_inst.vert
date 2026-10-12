#version 450
layout(location=0) in vec2 pos;
layout(location=1) in vec4 col;
layout(location=0) out vec4 vcol;
void main() {
  float x = pos.x + 0.4 * float(gl_InstanceIndex) - 0.6;
  gl_Position = vec4(x, pos.y, 0.5, 1.0);
  vcol = vec4(col.rgb, float(gl_VertexIndex) * 0.25);
}
