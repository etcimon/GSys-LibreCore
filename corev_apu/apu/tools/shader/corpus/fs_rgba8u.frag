#version 450
// R8G8B8A8_UINT colour attachment: integer fragment output — the
// uvec4 output type Vulkan requires for a UINT-format attachment.
// floatBitsToUint(vcol) bitcasts each interpolated f32 channel to its
// uint pattern, so res_q[c] holds the f32 bits and f_enc8 keeps the
// low byte: the stored RGBA word is {f32b(a)[7:0],f32b(b)[7:0],
// f32b(g)[7:0],f32b(r)[7:0]} — deterministic per pixel, matching the
// model's f32b(_v[c])&0xFF per channel.
layout(location=0) in vec4 vcol;
layout(location=0) out uvec4 o;
void main() {
  o = floatBitsToUint(vcol);
}
