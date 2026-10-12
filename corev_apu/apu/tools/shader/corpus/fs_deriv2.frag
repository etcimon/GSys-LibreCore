#version 450
layout(location=0) in vec2 vuv;
layout(location=1) in vec4 vc;
layout(location=0) out vec4 o;
void main() {
  o = vec4(fwidth(vuv) * 8.0, dFdx(vc.r) * 4.0 + 0.5, 1.0);
}
