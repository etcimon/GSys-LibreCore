#version 450
// 2D-array explicit-lod: coord=vec3(vcol.xy, vcol.w) -> layer=round(w)
// in {0,1} on the 2-layer image, OpImageSampleExplicitLod lod=0 ->
// mip0 LINEAR bilinear inside that layer.  vs_texzw gives vcol.w a
// varying [0.4,1.2] selector.
layout(set = 0, binding = 0) uniform sampler2DArray tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  o = textureLod(tex, vec3(vcol.xy, vcol.w), 0.0);
}
