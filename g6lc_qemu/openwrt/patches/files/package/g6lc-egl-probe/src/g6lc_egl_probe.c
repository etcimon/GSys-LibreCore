// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int open_drm_node(void)
{
    char path[64];
    int fd;

    for (int i = 128; i < 192; i++) {
        snprintf(path, sizeof(path), "/dev/dri/renderD%d", i);
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            printf("G6LC_DRM_NODE=%s\n", path);
            return fd;
        }
    }
    for (int i = 0; i < 16; i++) {
        snprintf(path, sizeof(path), "/dev/dri/card%d", i);
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            printf("G6LC_DRM_NODE=%s\n", path);
            return fd;
        }
    }
    return -1;
}

static GLuint make_shader(GLenum type, const char *src)
{
    GLuint shader = glCreateShader(type);
    GLint status = GL_FALSE;
    char log[512];

    glShaderSource(shader, 1, &src, NULL);
    glCompileShader(shader);
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_TRUE)
        return shader;
    glGetShaderInfoLog(shader, sizeof(log), NULL, log);
    fprintf(stderr, "shader compile failed: %s\n", log);
    return 0;
}

static int run_audit_scene(void)
{
    static const char vs_src[] =
        "attribute vec2 pos;\n"
        "attribute vec2 tex_uv;\n"
        "varying vec2 uv;\n"
        "void main() { uv = tex_uv; gl_Position = vec4(pos, 0.0, 1.0); }\n";
    static const char fs_src[] =
        "precision mediump float;\n"
        "varying vec2 uv;\n"
        "uniform sampler2D tex;\n"
        "uniform vec4 tint;\n"
        "void main() { gl_FragColor = texture2D(tex, uv) * tint; }\n";
    static const GLfloat quad[] = {
        -1.0f, -1.0f, 0.0f, 0.0f,
         1.0f, -1.0f, 1.0f, 0.0f,
         1.0f,  1.0f, 1.0f, 1.0f,
        -1.0f,  1.0f, 0.0f, 1.0f,
    };
    static const GLushort indices[] = { 0, 1, 2, 0, 2, 3 };
    GLuint vs, fs, prog, vbo, ibo, tex;
    GLint sampler_loc, tint_loc;
    uint8_t texels[4 * 4 * 4];

    for (size_t i = 0; i < sizeof(texels); i += 4) {
        texels[i + 0] = (uint8_t)(32 + i);
        texels[i + 1] = (uint8_t)(192 - i);
        texels[i + 2] = (uint8_t)(96 + i / 2);
        texels[i + 3] = 255;
    }

    vs = make_shader(GL_VERTEX_SHADER, vs_src);
    fs = make_shader(GL_FRAGMENT_SHADER, fs_src);
    prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "pos");
    glBindAttribLocation(prog, 1, "tex_uv");
    glLinkProgram(prog);
    if (!vs || !fs || !prog)
        return 9;
    glUseProgram(prog);

    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    glGenBuffers(1, &ibo);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices,
                 GL_STATIC_DRAW);

    glGenTextures(1, &tex);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER,
                    GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 4, 4, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, texels);
    glGenerateMipmap(GL_TEXTURE_2D);

    sampler_loc = glGetUniformLocation(prog, "tex");
    tint_loc = glGetUniformLocation(prog, "tint");
    glUniform1i(sampler_loc, 0);
    glUniform4f(tint_loc, 0.75f, 1.0f, 0.5f, 0.75f);

    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (const void *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (const void *)8);
    glViewport(8, 8, 48, 48);
    glEnable(GL_SCISSOR_TEST);
    glScissor(8, 8, 48, 48);
    glEnable(GL_BLEND);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA,
                        GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_ALWAYS);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (const void *)0);
    glFinish();
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glBindTexture(GL_TEXTURE_2D, 0);
    glUseProgram(0);
    glDeleteTextures(1, &tex);
    glDeleteBuffers(1, &ibo);
    glDeleteBuffers(1, &vbo);
    glDeleteShader(vs);
    glDeleteShader(fs);
    glDeleteProgram(prog);
    return 0;
}

int main(int argc, char **argv)
{
    static const char vs_src[] =
        "attribute vec2 pos;\n"
        "varying vec2 uv;\n"
        "void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n";
    static const char fs_src[] =
        "precision mediump float;\n"
        "varying vec2 uv;\n"
        "void main() { gl_FragColor = vec4(uv, 0.25, 1.0); }\n";
    const EGLint pbuffer_attrs[] = {
        EGL_WIDTH, 64,
        EGL_HEIGHT, 64,
        EGL_NONE,
    };
    const EGLint context_attrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };
    const GLfloat vertices[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
         0.0f,  1.0f,
    };
    uint8_t pixels[64 * 64 * 4];
    uint32_t checksum = 2166136261u;
    GLuint vs, fs, prog, buffer;
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig config;
    EGLint count = 0;
    EGLint major = 0, minor = 0;
    struct gbm_device *gbm;
    struct gbm_surface *gbm_surface = NULL;
    const char *renderer;
    int fd;

    fd = open_drm_node();
    if (fd < 0) {
        fprintf(stderr, "no DRM node: %s\n", strerror(errno));
        return 2;
    }
    gbm = gbm_create_device(fd);
    if (!gbm) {
        fprintf(stderr, "gbm_create_device failed\n");
        close(fd);
        return 3;
    }

    display = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, &major, &minor)) {
        fprintf(stderr, "eglInitialize failed: 0x%04lx\n", (unsigned long)eglGetError());
        gbm_device_destroy(gbm);
        close(fd);
        return 4;
    }
    printf("G6LC_EGL_VERSION=%d.%d\n", major, minor);
    printf("G6LC_EGL_VENDOR=%s\n", eglQueryString(display, EGL_VENDOR));
    printf("G6LC_EGL_CLIENT_APIS=%s\n", eglQueryString(display, EGL_CLIENT_APIS));

    EGLConfig configs[128];
    EGLint surface_type = 0;
    EGLint renderable = 0;
    EGLint colors[4] = {0, 0, 0, 0};
    config = NULL;
    if (!eglGetConfigs(display, NULL, 0, &count) || count == 0) {
        fprintf(stderr, "no EGL configs: 0x%04lx\n", (unsigned long)eglGetError());
        return 5;
    }
    printf("G6LC_EGL_CONFIG_COUNT=%d\n", count);
    if (count > (EGLint)(sizeof(configs) / sizeof(configs[0])))
        count = (EGLint)(sizeof(configs) / sizeof(configs[0]));
    if (!eglGetConfigs(display, configs, count, &count)) {
        fprintf(stderr, "eglGetConfigs failed: 0x%04lx\n", (unsigned long)eglGetError());
        return 5;
    }
    for (EGLint i = 0; i < count; i++) {
        eglGetConfigAttrib(display, configs[i], EGL_RENDERABLE_TYPE, &renderable);
        eglGetConfigAttrib(display, configs[i], EGL_RED_SIZE, &colors[0]);
        eglGetConfigAttrib(display, configs[i], EGL_GREEN_SIZE, &colors[1]);
        eglGetConfigAttrib(display, configs[i], EGL_BLUE_SIZE, &colors[2]);
        eglGetConfigAttrib(display, configs[i], EGL_ALPHA_SIZE, &colors[3]);
        if ((renderable & EGL_OPENGL_ES2_BIT) && colors[0] >= 8 &&
            colors[1] >= 8 && colors[2] >= 8 && colors[3] >= 8) {
            config = configs[i];
            eglGetConfigAttrib(display, config, EGL_SURFACE_TYPE, &surface_type);
            break;
        }
    }
    if (!config) {
        fprintf(stderr, "no EGL ES2 RGBA8 config\n");
        return 5;
    }
    printf("G6LC_EGL_CONFIG_SURFACE_TYPE=0x%x\n", (unsigned int)surface_type);

    const char *extensions = eglQueryString(display, EGL_EXTENSIONS);
    int surfaceless = extensions && strstr(extensions, "EGL_KHR_surfaceless_context");
    printf("G6LC_EGL_SURFACELESS_CONTEXT=%s\n", surfaceless ? "y" : "n");

    eglBindAPI(EGL_OPENGL_ES_API);
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attrs);
    if (context == EGL_NO_CONTEXT) {
        fprintf(stderr, "eglCreateContext failed: 0x%04lx\n", (unsigned long)eglGetError());
        return 6;
    }
    if (surface_type & EGL_PBUFFER_BIT) {
        surface = eglCreatePbufferSurface(display, config, pbuffer_attrs);
        if (surface != EGL_NO_SURFACE)
            printf("G6LC_EGL_SURFACE_KIND=pbuffer\n");
    } else if (surface_type & EGL_WINDOW_BIT) {
        gbm_surface = gbm_surface_create(gbm, 64, 64, GBM_FORMAT_XRGB8888,
                                         GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
        if (gbm_surface) {
            surface = eglCreateWindowSurface(display, config,
                                             (EGLNativeWindowType)gbm_surface, NULL);
            if (surface != EGL_NO_SURFACE)
                printf("G6LC_EGL_SURFACE_KIND=gbm-window\n");
        }
    }
    if (surface == EGL_NO_SURFACE && !surfaceless) {
        fprintf(stderr, "no usable EGL surface: 0x%04lx\n",
                (unsigned long)eglGetError());
        return 7;
    }
    if (surface == EGL_NO_SURFACE)
        printf("G6LC_EGL_SURFACE_KIND=surfaceless\n");
    if (!eglMakeCurrent(display, surface, surface, context)) {
        fprintf(stderr, "eglMakeCurrent failed: 0x%04lx\n", (unsigned long)eglGetError());
        return 7;
    }

    renderer = (const char *)glGetString(GL_RENDERER);
    printf("G6LC_GL_RENDERER=%s\n", renderer ? renderer : "<null>");
    printf("G6LC_GL_VERSION=%s\n", glGetString(GL_VERSION));
    printf("G6LC_GLSL_VERSION=%s\n", glGetString(GL_SHADING_LANGUAGE_VERSION));

    vs = make_shader(GL_VERTEX_SHADER, vs_src);
    fs = make_shader(GL_FRAGMENT_SHADER, fs_src);
    prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);
    glBindAttribLocation(prog, 0, "pos");
    glLinkProgram(prog);
    glUseProgram(prog);
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    glViewport(0, 0, 64, 64);
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();
    glReadPixels(0, 0, 64, 64, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    for (size_t i = 0; i < sizeof(pixels); i++) {
        checksum ^= pixels[i];
        checksum *= 16777619u;
    }
    printf("G6LC_PIXEL_FNV1A=0x%08x\n", checksum);
    if (argc > 1 && strcmp(argv[1], "audit") == 0) {
        int audit_rc = run_audit_scene();

        checksum = 2166136261u;
        glReadPixels(0, 0, 64, 64, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        for (size_t i = 0; i < sizeof(pixels); i++) {
            checksum ^= pixels[i];
            checksum *= 16777619u;
        }
        printf("G6LC_AUDIT_PIXEL_FNV1A=0x%08x\n", checksum);
        if (audit_rc != 0) {
            printf("G6LC_AUDIT_RESULT=FAIL\n");
            return audit_rc;
        }
        printf("G6LC_AUDIT_RESULT=PASS\n");
    }
    if (renderer && strstr(renderer, "virgl"))
        printf("G6LC_EGL_GLES2_DRIVER=virgl\n");
    else
        printf("G6LC_EGL_GLES2_DRIVER=other\n");
    printf("G6LC_EGL_GLES2_OK\n");

    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    if (surface != EGL_NO_SURFACE)
        eglDestroySurface(display, surface);
    eglTerminate(display);
    if (gbm_surface)
        gbm_surface_destroy(gbm_surface);
    gbm_device_destroy(gbm);
    close(fd);
    return checksum == 0 ? 8 : 0;
}
