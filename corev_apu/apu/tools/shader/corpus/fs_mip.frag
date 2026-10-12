#version 450
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(location=0) in vec4 vcol;
layout(location=0) out vec4 o;
void main() {
  vec2 uv = vec2(gl_FragCoord.x * gl_FragCoord.x / 128.0, vcol.y);
  o = texture(tex, uv);
}
