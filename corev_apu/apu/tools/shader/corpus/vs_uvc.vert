#version 450
layout(location=0) in vec2 pos;
layout(location=1) in vec2 uv;
layout(location=2) in vec4 c;
layout(location=0) out vec2 vuv;
layout(location=1) out vec4 vc;
void main() {
  gl_Position = vec4(pos, 0.5, 1.0);
  vuv = uv;
  vc = c;
}
