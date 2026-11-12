#version 450
// separate sampled-image (texture2D, SAMPLED_IMAGE) + sampler (SAMPLER)
// combined via OpSampledImage -> OpImageSampleImplicitLod.  Mirrors
// fs_mip's FragCoord-driven uv so the Venus-vs-llvmpipe oracle compares
// the same sampled output, but through the SEPARATE descriptor kinds
// (kind2 image + kind0 sampler) the descriptor_copy.graphics sampler_*
// /sampled_image_* cases exercise — the path tx_smpk_q fixed in shwave.
layout(set = 0, binding = 0) uniform texture2D img;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  vec2 uv = vec2(gl_FragCoord.x * gl_FragCoord.x / 128.0, vcol.y);
  o = texture(sampler2D(img, smp), uv);
}
