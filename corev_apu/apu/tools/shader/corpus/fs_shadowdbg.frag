#version 450
// DEBUG: dump the three varyings directly so the vkcmp llvmpipe-vs-Venus
// pixel diff reveals which varying channel is broken in the Venus path.
// R = vd (fog dist, varies 0->1->0.7), G = vsh.x (su), B = vuv.x, A = 1
layout(location=0) in vec2 vuv;
layout(location=1) in vec4 vsh;
layout(location=2) in float vd;
layout(location=0) out vec4 o;
void main() {
  o = vec4(vd, vsh.x, vuv.x, 1.0);
}
