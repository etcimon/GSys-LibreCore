#version 450
// descriptor_copy.graphics shape: FS reads a STORAGE_IMAGE (kind3,
// rgba32f) via imageLoad -> OpImageRead.  16 fragments tile a 4x4
// image; each reads a distinct seeded texel so a wrong descriptor
// resolve returns another image's or zero data.
layout(set = 0, binding = 0, rgba32f) uniform readonly image2D img;
layout(location = 0) out vec4 o;
void main() {
    o = imageLoad(img, ivec2(gl_FragCoord.xy) & 3);
}
