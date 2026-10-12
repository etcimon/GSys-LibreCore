#version 450
layout(location=0) in vec3 pos;
layout(location=1) in vec4 col;
layout(location=0) out vec4 vcol;
void main() {
  gl_Position = vec4(pos.x, pos.y, 0.5 * pos.z + 0.5, -pos.z);
  vcol = col;
}
