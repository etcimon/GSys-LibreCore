#version 450
// vkcmp scene 10 (f10_shadow_fog): fullscreen quad; carries the
// colour-map uv, the projective shadow lookup {su,sv,ref,w} (all
// numerators pre-multiplied by w), and a fog distance.
layout(location=0) in vec2 pos;
layout(location=1) in vec4 attr;   // {su, sv, ref, w}
layout(location=2) in vec4 col;    // colour-map uv in .xy, fog dist .z
layout(location=0) out vec2 vuv;
layout(location=1) out vec4 vsh;
layout(location=2) out float vd;
void main() {
  gl_Position = vec4(pos, 0.5, 1.0);
  vuv = col.xy;
  vd  = col.z;
  vsh = attr;
}
