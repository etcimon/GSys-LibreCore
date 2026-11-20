#version 450
// G3a-iv-s: MRT x8 — eight colour attachments (the full ca[7:0] /
// at_q cursor range).  FS-out location l -> ca[l]:
//   location 0 -> attachment 0 : o0 = the proven fs_color gradient.
//   location 1 -> attachment 1 : o1 = R/B channel swap.
//   location 2 -> attachment 2 : o2 = RGB left-rotation.
//   location 3 -> attachment 3 : o3 = FULL channel reversal.
//   locations 4..7 -> attachments 4..7 : four further distinct
//     permutations so all eight attachments stay independently
//     observable (each permutes the same base colour c).
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o0;
layout(location=1) out vec4 o1;
layout(location=2) out vec4 o2;
layout(location=3) out vec4 o3;
layout(location=4) out vec4 o4;
layout(location=5) out vec4 o5;
layout(location=6) out vec4 o6;
layout(location=7) out vec4 o7;
void main() {
  vec4 c = vcol * 0.5 + gl_FragCoord.x * 0.001;
  o0 = c;                                  // (r,g,b,a)
  o1 = vec4(c.b, c.g, c.r, c.a);            // (b,g,r,a) R/B swap
  o2 = vec4(c.g, c.b, c.r, c.a);            // (g,b,r,a) RGB rotate
  o3 = vec4(c.a, c.b, c.g, c.r);            // (a,b,g,r) full reverse
  o4 = vec4(c.r, c.b, c.g, c.a);            // (r,b,g,a) G/B swap
  o5 = vec4(c.g, c.r, c.b, c.a);            // (g,r,b,a) R/G swap
  o6 = vec4(c.b, c.a, c.g, c.r);            // (b,a,g,r)
  o7 = vec4(c.a, c.r, c.g, c.b);            // (a,r,g,b)
}
