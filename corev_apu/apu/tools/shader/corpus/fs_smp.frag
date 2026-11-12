#version 450
// separate sampled-image (texture2D, kind2) + sampler (kind0) combined
// via OpSampledImage -> OpImageSampleImplicitLod.  The CTS
// descriptor_copy.graphics sampler_*/sampled_image_* shapes.
layout(set = 0, binding = 0) uniform texture2D img;
layout(set = 0, binding = 1) uniform sampler smp;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = texture(sampler2D(img, smp), vcol.xy);
}
