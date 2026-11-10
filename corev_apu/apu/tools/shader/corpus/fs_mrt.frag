#version 450
// G3a-iv-n: MRT — two colour attachments.  FS-out location l -> ca[l]:
//   location 0 -> attachment 0 : o0 = the proven fs_color gradient
//     (vcol*0.5 + FragCoord.x*0.001) so att0 reuses the is_fcolor oracle.
//   location 1 -> attachment 1 : o1 = R/B channel swap of o0 — a pure
//     per-channel permutation, so the per-channel UNORM8 encode commutes
//     and att1's expected word is a byte-permute of att0's.
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o0;
layout(location=1) out vec4 o1;
void main() {
  vec4 c = vcol * 0.5 + gl_FragCoord.x * 0.001;
  o0 = c;
  o1 = vec4(c.b, c.g, c.r, c.a);
}
