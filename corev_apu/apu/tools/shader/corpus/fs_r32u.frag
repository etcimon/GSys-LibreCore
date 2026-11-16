#version 450
// R32_UINT colour attachment (ue_gpos_r32u*): integer fragment output —
// the output type Vulkan requires for a UINT-format attachment.  Channel
// R is stored raw; floatBitsToUint(vcol.r) makes the stored word the
// fp32 bit pattern of the interpolated channel-0 value, so the expected
// image is identical to the r32f session — a controlled A/B on the FS
// output type and the attachment format alone.
layout(location=0) in vec4 vcol;
layout(location=0) out uint o;
void main() {
  o = floatBitsToUint(vcol.r);
}
