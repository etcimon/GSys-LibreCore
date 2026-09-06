/* g6b-gr OpenGL-ES2 adapter — display-proxy 640x480 → 1920x1080 fps=120 dpi=192 mode=dpi accel=off */
/* purpose=gl-adapter home=gles2 */
/* GL-ACCEL off: rvv=vle8/vse8 scale blit; ai-island=16x16 tiles (GEMM @ 0x40000000, not the GR plane) */
#version 100
attribute vec2 a_pos;
attribute vec2 a_uv;
varying vec2 v_uv;
void main() {
	gl_Position = vec4(a_pos, 0.0, 1.0);
	v_uv = a_uv;
}
/* fragment */
#version 100
precision mediump float;
varying vec2 v_uv;
uniform sampler2D u_zeal;
uniform sampler2D u_dom;
void main() {
	vec4 z = texture2D(u_zeal, v_uv);
	vec4 d = texture2D(u_dom, v_uv);
	gl_FragColor = mix(z, d, d.a);
}
/* draw: triangle strip fullscreen; textures = ZealOS plane + DOM status */
/* GL-ADAPTER opengl-es2 fps=120 link=hdmi accel=off */
