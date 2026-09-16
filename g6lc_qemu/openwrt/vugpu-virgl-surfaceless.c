// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// LD_PRELOAD helper for QEMU's contrib/vhost-user-gpu on a headless host.
// Upstream vhost-user-gpu always passes VIRGL_RENDERER_USE_EGL; when the host
// has no DRM render node that initialization fails before the guest receives
// capsets.  Mesa's EGL_PLATFORM_SURFACELESS_MESA path can render through
// llvmpipe without a render node, so request virglrenderer's surfaceless mode
// while leaving QEMU and the guest's virtio-gpu/virgl protocol unchanged.
//
// VUGPU_VIRGL_DUMP_DIR additionally archives the API boundary used by the
// backend: negotiated capsets, context/resource calls, transfers and each
// submitted virgl command buffer.  This is a test observation point only; it
// does not change the guest-visible command stream.
//
// VUGPU_VIRGL_CAP_PROFILE=gles2-min or gles2-xfer masks the backend's
// negotiated capset after virglrenderer reports it.  This is a compatibility
// probe for the future device contract: QEMU, Linux and Mesa remain unchanged.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <virgl/virglrenderer.h>

/* The installed public header only forward-declares virgl_box and does not
 * export the wire capset layout.  Keep the packed layout local to this test
 * shim; it is the virglrenderer 1.0.0 ABI used by the pinned remote package. */
struct virgl_box {
    uint32_t x, y, z;
    uint32_t w, h, d;
};

struct g6lc_format_mask {
    uint32_t bitmask[16];
};

struct g6lc_virgl_caps_v1 {
    uint32_t max_version;
    struct g6lc_format_mask sampler;
    struct g6lc_format_mask render;
    struct g6lc_format_mask depthstencil;
    struct g6lc_format_mask vertexbuffer;
    uint32_t bset;
    uint32_t glsl_level;
    uint32_t max_texture_array_layers;
    uint32_t max_streamout_buffers;
    uint32_t max_dual_source_render_targets;
    uint32_t max_render_targets;
    uint32_t max_samples;
    uint32_t prim_mask;
    uint32_t max_tbo_size;
    uint32_t max_uniform_blocks;
    uint32_t max_viewports;
    uint32_t max_texture_gather_components;
};

struct g6lc_virgl_video_caps {
    uint32_t packed_profile;
    uint32_t packed_resolution;
    uint32_t packed_format;
    uint32_t packed_flags;
};

struct g6lc_virgl_caps_v2 {
    struct g6lc_virgl_caps_v1 v1;
    float min_aliased_point_size;
    float max_aliased_point_size;
    float min_smooth_point_size;
    float max_smooth_point_size;
    float min_aliased_line_width;
    float max_aliased_line_width;
    float min_smooth_line_width;
    float max_smooth_line_width;
    float max_texture_lod_bias;
    uint32_t max_geom_output_vertices;
    uint32_t max_geom_total_output_components;
    uint32_t max_vertex_outputs;
    uint32_t max_vertex_attribs;
    uint32_t max_shader_patch_varyings;
    int32_t min_texel_offset;
    int32_t max_texel_offset;
    int32_t min_texture_gather_offset;
    int32_t max_texture_gather_offset;
    uint32_t texture_buffer_offset_alignment;
    uint32_t uniform_buffer_offset_alignment;
    uint32_t shader_buffer_offset_alignment;
    uint32_t capability_bits;
    uint32_t sample_locations[8];
    uint32_t max_vertex_attrib_stride;
    uint32_t max_shader_buffer_frag_compute;
    uint32_t max_shader_buffer_other_stages;
    uint32_t max_shader_image_frag_compute;
    uint32_t max_shader_image_other_stages;
    uint32_t max_image_samples;
    uint32_t max_compute_work_group_invocations;
    uint32_t max_compute_shared_memory_size;
    uint32_t max_compute_grid_size[3];
    uint32_t max_compute_block_size[3];
    uint32_t max_texture_2d_size;
    uint32_t max_texture_3d_size;
    uint32_t max_texture_cube_size;
    uint32_t max_combined_shader_buffers;
    uint32_t max_atomic_counters[6];
    uint32_t max_atomic_counter_buffers[6];
    uint32_t max_combined_atomic_counters;
    uint32_t max_combined_atomic_counter_buffers;
    uint32_t host_feature_check_version;
    struct g6lc_format_mask supported_readback_formats;
    struct g6lc_format_mask scanout;
    uint32_t capability_bits_v2;
    uint32_t max_video_memory;
    char renderer[64];
    float max_anisotropy;
    uint32_t max_texture_image_units;
    struct g6lc_format_mask supported_multisample_formats;
    uint32_t max_const_buffer_size[6];
    uint32_t num_video_caps;
    struct g6lc_virgl_video_caps video_caps[32];
    uint32_t max_uniform_block_size;
    uint32_t max_tcs_outputs;
    uint32_t max_tes_outputs;
};

_Static_assert(sizeof(struct g6lc_virgl_caps_v1) == 308,
               "virgl capset v1 wire size changed");
_Static_assert(sizeof(struct g6lc_virgl_caps_v2) == 1384,
               "virgl capset v2 wire size changed");

typedef int (*virgl_renderer_init_fn)(
    void *cookie,
    int flags,
    struct virgl_renderer_callbacks *cbs);
typedef int (*virgl_context_create_fn)(uint32_t, uint32_t, const char *);
typedef void (*virgl_context_destroy_fn)(uint32_t);
typedef int (*virgl_resource_create_fn)(
    struct virgl_renderer_resource_create_args *, struct iovec *, uint32_t);
typedef int (*virgl_submit_cmd_fn)(void *, int, int);
typedef int (*virgl_transfer_write_iov_fn)(
    uint32_t, uint32_t, int, uint32_t, uint32_t, struct virgl_box *,
    uint64_t, struct iovec *, unsigned int);
typedef int (*virgl_transfer_read_iov_fn)(
    uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, struct virgl_box *,
    uint64_t, struct iovec *, int);
typedef int (*virgl_resource_attach_iov_fn)(int, struct iovec *, int);
typedef void (*virgl_resource_detach_iov_fn)(int, struct iovec **, int *);
typedef void (*virgl_resource_unref_fn)(uint32_t);
typedef int (*virgl_create_fence_fn)(int, uint32_t);
typedef void (*virgl_ctx_resource_fn)(int, int);
typedef void (*virgl_get_cap_set_fn)(uint32_t, uint32_t *, uint32_t *);
typedef void (*virgl_fill_caps_fn)(uint32_t, uint32_t, void *);

static virgl_renderer_init_fn real_virgl_renderer_init;
static virgl_context_create_fn real_virgl_renderer_context_create;
static virgl_context_destroy_fn real_virgl_renderer_context_destroy;
static virgl_resource_create_fn real_virgl_renderer_resource_create;
static virgl_submit_cmd_fn real_virgl_renderer_submit_cmd;
static virgl_transfer_write_iov_fn real_virgl_renderer_transfer_write_iov;
static virgl_transfer_read_iov_fn real_virgl_renderer_transfer_read_iov;
static virgl_resource_attach_iov_fn real_virgl_renderer_resource_attach_iov;
static virgl_resource_detach_iov_fn real_virgl_renderer_resource_detach_iov;
static virgl_resource_unref_fn real_virgl_renderer_resource_unref;
static virgl_create_fence_fn real_virgl_renderer_create_fence;
static virgl_ctx_resource_fn real_virgl_renderer_ctx_attach_resource;
static virgl_ctx_resource_fn real_virgl_renderer_ctx_detach_resource;
static virgl_get_cap_set_fn real_virgl_renderer_get_cap_set;
static virgl_fill_caps_fn real_virgl_renderer_fill_caps;

static unsigned long capture_seq;
static uint32_t capset_size[64];

static void *next_sym(const char *name)
{
    return dlsym(RTLD_NEXT, name);
}

static int env_enabled(const char *name, int default_value)
{
    const char *value = getenv(name);

    if (!value || !*value)
        return default_value;
    return value[0] != '0';
}

static const char *capture_dir(void)
{
    const char *dir = getenv("VUGPU_VIRGL_DUMP_DIR");

    return dir && *dir ? dir : NULL;
}

static FILE *capture_index(void)
{
    static FILE *index;
    const char *dir = capture_dir();
    char path[1024];

    if (index || !dir)
        return index;
    snprintf(path, sizeof(path), "%s/index.log", dir);
    index = fopen(path, "a");
    return index;
}

static unsigned long capture_event(const char *fmt, ...)
{
    FILE *index = capture_index();
    va_list ap;
    unsigned long seq = ++capture_seq;

    if (index) {
        fprintf(index, "%06lu ", seq);
        va_start(ap, fmt);
        vfprintf(index, fmt, ap);
        va_end(ap);
        fputc('\n', index);
        fflush(index);
    }
    return seq;
}

static void capture_blob(unsigned long seq, const char *kind,
                         const void *data, size_t size)
{
    const char *dir = capture_dir();
    char path[1024];
    FILE *out;

    if (!dir || !data || !size)
        return;
    snprintf(path, sizeof(path), "%s/%06lu-%s.bin", dir, seq, kind);
    out = fopen(path, "wb");
    if (!out)
        return;
    fwrite(data, 1, size, out);
    fclose(out);
}

static size_t iov_bytes(const struct iovec *iov, unsigned int count)
{
    size_t total = 0;

    for (unsigned int i = 0; i < count; i++)
        total += iov[i].iov_len;
    return total;
}

static void capture_iov(unsigned long seq, const char *kind,
                        const struct iovec *iov, unsigned int count)
{
    const char *dir = capture_dir();
    char path[1024];
    FILE *out;

    if (!dir || !iov || !count)
        return;
    snprintf(path, sizeof(path), "%s/%06lu-%s.bin", dir, seq, kind);
    out = fopen(path, "wb");
    if (!out)
        return;
    for (unsigned int i = 0; i < count; i++) {
        if (iov[i].iov_base && iov[i].iov_len)
            fwrite(iov[i].iov_base, 1, iov[i].iov_len, out);
    }
    fclose(out);
}

static void log_box(const struct virgl_box *box, char *text, size_t size)
{
    if (!box) {
        snprintf(text, size, "none");
        return;
    }
    snprintf(text, size, "%u,%u,%u %ux%ux%u",
             box->x, box->y, box->z, box->w, box->h, box->d);
}

int virgl_renderer_init(void *cookie, int flags,
                        struct virgl_renderer_callbacks *cbs)
{
    int ret;

    if (!real_virgl_renderer_init)
        real_virgl_renderer_init =
            (virgl_renderer_init_fn)next_sym("virgl_renderer_init");
    if (!real_virgl_renderer_init) {
        fprintf(stderr, "vugpu-virgl-surfaceless: virgl_renderer_init not found\n");
        return -1;
    }

    if (env_enabled("VUGPU_VIRGL_SURFACELESS", 1))
        flags |= VIRGL_RENDERER_USE_SURFACELESS;
    if (env_enabled("VUGPU_VIRGL_GLES", 1))
        flags |= VIRGL_RENDERER_USE_GLES;

    fprintf(stderr,
            "vugpu-virgl-surfaceless: virgl_renderer_init flags=0x%x\n",
            flags);
    ret = real_virgl_renderer_init(cookie, flags, cbs);
    capture_event("init flags=0x%x rc=%d", flags, ret);
    return ret;
}

int virgl_renderer_context_create(uint32_t handle, uint32_t nlen,
                                  const char *name)
{
    char safe_name[65];
    int ret;

    if (!real_virgl_renderer_context_create)
        real_virgl_renderer_context_create =
            (virgl_context_create_fn)next_sym("virgl_renderer_context_create");
    if (!real_virgl_renderer_context_create)
        return -1;
    memset(safe_name, 0, sizeof(safe_name));
    if (name && nlen)
        memcpy(safe_name, name, nlen < 64 ? nlen : 64);
    ret = real_virgl_renderer_context_create(handle, nlen, name);
    capture_event("ctx-create ctx=%u name=%s rc=%d", handle, safe_name, ret);
    return ret;
}

void virgl_renderer_context_destroy(uint32_t handle)
{
    if (!real_virgl_renderer_context_destroy)
        real_virgl_renderer_context_destroy =
            (virgl_context_destroy_fn)next_sym("virgl_renderer_context_destroy");
    if (!real_virgl_renderer_context_destroy)
        return;
    real_virgl_renderer_context_destroy(handle);
    capture_event("ctx-destroy ctx=%u", handle);
}

int virgl_renderer_resource_create(
    struct virgl_renderer_resource_create_args *args,
    struct iovec *iov, uint32_t num_iovs)
{
    unsigned long seq;
    int ret;

    if (!real_virgl_renderer_resource_create)
        real_virgl_renderer_resource_create =
            (virgl_resource_create_fn)next_sym("virgl_renderer_resource_create");
    if (!real_virgl_renderer_resource_create)
        return -1;
    seq = capture_event(
        "resource-create handle=%u target=%u format=%u bind=0x%x "
        "size=%ux%ux%u array=%u levels=%u samples=%u flags=0x%x iovs=%u",
        args ? args->handle : 0, args ? args->target : 0,
        args ? args->format : 0, args ? args->bind : 0,
        args ? args->width : 0, args ? args->height : 0,
        args ? args->depth : 0, args ? args->array_size : 0,
        args ? args->last_level : 0, args ? args->nr_samples : 0,
        args ? args->flags : 0, num_iovs);
    capture_iov(seq, "resource-create", iov, num_iovs);
    ret = real_virgl_renderer_resource_create(args, iov, num_iovs);
    capture_event("resource-create-rc handle=%u rc=%d",
                  args ? args->handle : 0, ret);
    return ret;
}

int virgl_renderer_resource_attach_iov(int res_handle, struct iovec *iov,
                                       int num_iovs)
{
    int ret;

    if (!real_virgl_renderer_resource_attach_iov)
        real_virgl_renderer_resource_attach_iov =
            (virgl_resource_attach_iov_fn)next_sym(
                "virgl_renderer_resource_attach_iov");
    if (!real_virgl_renderer_resource_attach_iov)
        return -1;
    capture_event("resource-attach-iov handle=%d iovs=%d bytes=%zu",
                  res_handle, num_iovs,
                  num_iovs > 0 ? iov_bytes(iov, (unsigned int)num_iovs) : 0);
    ret = real_virgl_renderer_resource_attach_iov(res_handle, iov, num_iovs);
    capture_event("resource-attach-iov-rc handle=%d rc=%d", res_handle, ret);
    return ret;
}

void virgl_renderer_resource_detach_iov(int res_handle, struct iovec **iov,
                                      int *num_iovs)
{
    if (!real_virgl_renderer_resource_detach_iov)
        real_virgl_renderer_resource_detach_iov =
            (virgl_resource_detach_iov_fn)next_sym(
                "virgl_renderer_resource_detach_iov");
    if (!real_virgl_renderer_resource_detach_iov)
        return;
    real_virgl_renderer_resource_detach_iov(res_handle, iov, num_iovs);
    capture_event("resource-detach-iov handle=%d iovs=%d bytes=%zu",
                  res_handle, num_iovs ? *num_iovs : -1,
                  iov && *iov && num_iovs && *num_iovs > 0
                      ? iov_bytes(*iov, (unsigned int)*num_iovs)
                      : 0);
}

void virgl_renderer_resource_unref(uint32_t res_handle)
{
    if (!real_virgl_renderer_resource_unref)
        real_virgl_renderer_resource_unref =
            (virgl_resource_unref_fn)next_sym("virgl_renderer_resource_unref");
    if (!real_virgl_renderer_resource_unref)
        return;
    real_virgl_renderer_resource_unref(res_handle);
    capture_event("resource-unref handle=%u", res_handle);
}

int virgl_renderer_transfer_write_iov(uint32_t handle, uint32_t ctx_id,
                                      int level, uint32_t stride,
                                      uint32_t layer_stride,
                                      struct virgl_box *box,
                                      uint64_t offset,
                                      struct iovec *iovec,
                                      unsigned int iovec_cnt)
{
    char box_text[96];
    unsigned long seq;
    int ret;

    if (!real_virgl_renderer_transfer_write_iov)
        real_virgl_renderer_transfer_write_iov =
            (virgl_transfer_write_iov_fn)next_sym(
                "virgl_renderer_transfer_write_iov");
    if (!real_virgl_renderer_transfer_write_iov)
        return -1;
    log_box(box, box_text, sizeof(box_text));
    seq = capture_event(
        "transfer-write handle=%u ctx=%u level=%d stride=%u layer_stride=%u "
        "box=%s offset=%llu iovs=%u bytes=%zu",
        handle, ctx_id, level, stride, layer_stride, box_text,
        (unsigned long long)offset, iovec_cnt,
        iovec ? iov_bytes(iovec, iovec_cnt) : 0);
    capture_iov(seq, "transfer-write", iovec, iovec_cnt);
    ret = real_virgl_renderer_transfer_write_iov(
        handle, ctx_id, level, stride, layer_stride, box, offset, iovec,
        iovec_cnt);
    capture_event("transfer-write-rc handle=%u ctx=%u rc=%d",
                  handle, ctx_id, ret);
    return ret;
}

int virgl_renderer_transfer_read_iov(uint32_t handle, uint32_t ctx_id,
                                     uint32_t level, uint32_t stride,
                                     uint32_t layer_stride,
                                     struct virgl_box *box,
                                     uint64_t offset, struct iovec *iov,
                                     int iovec_cnt)
{
    char box_text[96];
    unsigned long seq;
    int ret;

    if (!real_virgl_renderer_transfer_read_iov)
        real_virgl_renderer_transfer_read_iov =
            (virgl_transfer_read_iov_fn)next_sym(
                "virgl_renderer_transfer_read_iov");
    if (!real_virgl_renderer_transfer_read_iov)
        return -1;
    log_box(box, box_text, sizeof(box_text));
    seq = capture_event(
        "transfer-read handle=%u ctx=%u level=%u stride=%u layer_stride=%u "
        "box=%s offset=%llu iovs=%d bytes=%zu",
        handle, ctx_id, level, stride, layer_stride, box_text,
        (unsigned long long)offset, iovec_cnt,
        iov && iovec_cnt > 0 ? iov_bytes(iov, (unsigned int)iovec_cnt) : 0);
    ret = real_virgl_renderer_transfer_read_iov(
        handle, ctx_id, level, stride, layer_stride, box, offset, iov,
        iovec_cnt);
    if (ret == 0 && iov && iovec_cnt > 0)
        capture_iov(seq, "transfer-read", iov, (unsigned int)iovec_cnt);
    capture_event("transfer-read-rc handle=%u ctx=%u rc=%d",
                  handle, ctx_id, ret);
    return ret;
}

int virgl_renderer_submit_cmd(void *buffer, int ctx_id, int ndw)
{
    unsigned long seq;
    int ret;

    if (!real_virgl_renderer_submit_cmd)
        real_virgl_renderer_submit_cmd =
            (virgl_submit_cmd_fn)next_sym("virgl_renderer_submit_cmd");
    if (!real_virgl_renderer_submit_cmd)
        return -1;
    seq = capture_event("submit ctx=%d ndw=%d bytes=%d",
                        ctx_id, ndw, ndw > 0 ? ndw * 4 : 0);
    if (ndw > 0)
        capture_blob(seq, "submit", buffer, (size_t)ndw * 4);
    ret = real_virgl_renderer_submit_cmd(buffer, ctx_id, ndw);
    capture_event("submit-rc ctx=%d rc=%d", ctx_id, ret);
    return ret;
}

int virgl_renderer_create_fence(int client_fence_id, uint32_t ctx_id)
{
    int ret;

    if (!real_virgl_renderer_create_fence)
        real_virgl_renderer_create_fence =
            (virgl_create_fence_fn)next_sym("virgl_renderer_create_fence");
    if (!real_virgl_renderer_create_fence)
        return -1;
    ret = real_virgl_renderer_create_fence(client_fence_id, ctx_id);
    capture_event("fence-create cmd_type=0x%x fence=%d rc=%d",
                  ctx_id, client_fence_id, ret);
    return ret;
}

void virgl_renderer_ctx_attach_resource(int ctx_id, int res_handle)
{
    if (!real_virgl_renderer_ctx_attach_resource)
        real_virgl_renderer_ctx_attach_resource =
            (virgl_ctx_resource_fn)next_sym(
                "virgl_renderer_ctx_attach_resource");
    if (!real_virgl_renderer_ctx_attach_resource)
        return;
    real_virgl_renderer_ctx_attach_resource(ctx_id, res_handle);
    capture_event("ctx-attach-resource ctx=%d handle=%d", ctx_id, res_handle);
}

void virgl_renderer_ctx_detach_resource(int ctx_id, int res_handle)
{
    if (!real_virgl_renderer_ctx_detach_resource)
        real_virgl_renderer_ctx_detach_resource =
            (virgl_ctx_resource_fn)next_sym(
                "virgl_renderer_ctx_detach_resource");
    if (!real_virgl_renderer_ctx_detach_resource)
        return;
    real_virgl_renderer_ctx_detach_resource(ctx_id, res_handle);
    capture_event("ctx-detach-resource ctx=%d handle=%d", ctx_id, res_handle);
}

void virgl_renderer_get_cap_set(uint32_t set, uint32_t *max_ver,
                                uint32_t *max_size)
{
    if (!real_virgl_renderer_get_cap_set)
        real_virgl_renderer_get_cap_set =
            (virgl_get_cap_set_fn)next_sym("virgl_renderer_get_cap_set");
    if (!real_virgl_renderer_get_cap_set)
        return;
    real_virgl_renderer_get_cap_set(set, max_ver, max_size);
    if (set < sizeof(capset_size) / sizeof(capset_size[0]) && max_size)
        capset_size[set] = *max_size;
    capture_event("get-cap-set set=%u max_version=%u max_size=%u",
                  set, max_ver ? *max_ver : 0, max_size ? *max_size : 0);
}

enum g6lc_cap_profile {
    G6LC_CAP_PROFILE_NONE = 0,
    G6LC_CAP_PROFILE_GLES2_MIN = 1,
    G6LC_CAP_PROFILE_GLES2_XFER = 2,
};

static enum g6lc_cap_profile cap_profile(void)
{
    static int profile = -1;
    const char *name;

    if (profile >= 0)
        return (enum g6lc_cap_profile)profile;
    name = getenv("VUGPU_VIRGL_CAP_PROFILE");
    if (!name || !*name || !strcmp(name, "none"))
        profile = G6LC_CAP_PROFILE_NONE;
    else if (!strcmp(name, "gles2-min"))
        profile = G6LC_CAP_PROFILE_GLES2_MIN;
    else if (!strcmp(name, "gles2-xfer"))
        profile = G6LC_CAP_PROFILE_GLES2_XFER;
    else {
        fprintf(stderr,
                "vugpu-virgl-surfaceless: unknown VUGPU_VIRGL_CAP_PROFILE=%s\n",
                name);
        profile = G6LC_CAP_PROFILE_NONE;
    }
    return (enum g6lc_cap_profile)profile;
}

static void format_mask_clear(struct g6lc_format_mask *mask)
{
    memset(mask, 0, sizeof(*mask));
}

static void format_mask_add(struct g6lc_format_mask *mask, uint32_t format)
{
    if (format < 16 * 32)
        mask->bitmask[format / 32] |= 1u << (format % 32);
}

static void format_mask_add_list(struct g6lc_format_mask *mask,
                                 const uint32_t *formats, size_t count)
{
    for (size_t i = 0; i < count; i++)
        format_mask_add(mask, formats[i]);
}

static void apply_gles2_v1(struct g6lc_virgl_caps_v1 *caps)
{
    static const uint32_t color_formats[] = {
        1,   /* B8G8R8A8_UNORM */
        2,   /* B8G8R8X8_UNORM */
        3,   /* A8R8G8B8_UNORM */
        4,   /* X8R8G8B8_UNORM */
        7,   /* B5G6R5_UNORM */
        64,  /* R8_UNORM */
        65,  /* R8G8_UNORM */
        66,  /* R8G8B8_UNORM */
        67,  /* R8G8B8A8_UNORM */
        68,  /* X8B8G8R8_UNORM */
        121, /* A8B8G8R8_UNORM */
        134, /* R8G8B8X8_UNORM */
        91,  /* R16_FLOAT */
        92,  /* R16G16_FLOAT */
        93,  /* R16G16B16_FLOAT */
        94,  /* R16G16B16A16_FLOAT */
        28,  /* R32_FLOAT */
        29,  /* R32G32_FLOAT */
        30,  /* R32G32B32_FLOAT */
        31,  /* R32G32B32A32_FLOAT */
    };
    static const uint32_t vertex_formats[] = {
        48, 49, 50, 51, /* R16*_UNORM */
        52, 53, 54, 55, /* R16*_USCALED */
        56, 57, 58, 59, /* R16*_SNORM */
        60, 61, 62, 63, /* R16*_SSCALED */
        64, 65, 66, 67, /* R8*_UNORM */
        69, 70, 71, 72, /* R8*_USCALED */
        74, 75, 76, 77, /* R8*_SNORM */
        82, 83, 84, 85, /* R8*_SSCALED */
        87, 88, 89, 90, /* R32*_FIXED */
        91, 92, 93, 94, /* R16*_FLOAT */
        28, 29, 30, 31, /* R32*_FLOAT */
    };

    format_mask_clear(&caps->sampler);
    format_mask_clear(&caps->render);
    format_mask_clear(&caps->depthstencil);
    format_mask_clear(&caps->vertexbuffer);
    format_mask_add_list(&caps->sampler, color_formats,
                         sizeof(color_formats) / sizeof(color_formats[0]));
    format_mask_add_list(&caps->render, color_formats,
                         sizeof(color_formats) / sizeof(color_formats[0]));
    format_mask_add(&caps->depthstencil, 16); /* Z16_UNORM */
    format_mask_add(&caps->depthstencil, 18); /* Z32_FLOAT */
    format_mask_add(&caps->depthstencil, 19); /* Z24_UNORM_S8_UINT */
    format_mask_add(&caps->depthstencil, 20); /* S8_UINT_Z24_UNORM */
    format_mask_add(&caps->depthstencil, 23); /* S8_UINT */
    format_mask_add_list(&caps->vertexbuffer, vertex_formats,
                         sizeof(vertex_formats) / sizeof(vertex_formats[0]));

    caps->bset = 0;
    caps->glsl_level = 120;
    caps->max_texture_array_layers = 1;
    caps->max_streamout_buffers = 0;
    caps->max_dual_source_render_targets = 0;
    caps->max_render_targets = 1;
    caps->max_samples = 0;
    caps->prim_mask = 0x7f; /* points, lines, line loop/strip, triangles, strip, fan */
    caps->max_tbo_size = 0;
    caps->max_uniform_blocks = 1; /* slot zero/default uniforms only */
    caps->max_viewports = 1;
    caps->max_texture_gather_components = 0;
}

static void apply_gles2_profile(uint32_t set, void *caps, uint32_t bytes)
{
    static const uint32_t readback_formats[] = {1, 2, 3, 4, 7, 64, 65, 66, 67, 68, 121, 134};
    struct g6lc_virgl_caps_v2 *v2;
    enum g6lc_cap_profile profile = cap_profile();
    size_t i;

    if (!profile || !caps)
        return;
    if (set == 1 && bytes >= sizeof(struct g6lc_virgl_caps_v1)) {
        apply_gles2_v1(caps);
        return;
    }
    if (set != 2 || bytes < sizeof(struct g6lc_virgl_caps_v2))
        return;

    v2 = caps;
    apply_gles2_v1(&v2->v1);
    v2->min_aliased_point_size = 0.0f;
    v2->max_aliased_point_size = 1.0f;
    v2->min_smooth_point_size = 0.0f;
    v2->max_smooth_point_size = 1.0f;
    v2->min_aliased_line_width = 0.0f;
    v2->max_aliased_line_width = 1.0f;
    v2->min_smooth_line_width = 0.0f;
    v2->max_smooth_line_width = 1.0f;
    v2->max_texture_lod_bias = 0.0f;
    v2->max_geom_output_vertices = 0;
    v2->max_geom_total_output_components = 0;
    v2->max_vertex_outputs = 8;
    v2->max_vertex_attribs = 8;
    v2->max_shader_patch_varyings = 0;
    v2->min_texel_offset = 0;
    v2->max_texel_offset = 0;
    v2->min_texture_gather_offset = 0;
    v2->max_texture_gather_offset = 0;
    v2->texture_buffer_offset_alignment = 0;
    v2->uniform_buffer_offset_alignment = 256;
    v2->shader_buffer_offset_alignment = 0;
    v2->capability_bits =
        profile == G6LC_CAP_PROFILE_GLES2_XFER ? (1u << 17) : 0;
    memset(v2->sample_locations, 0, sizeof(v2->sample_locations));
    v2->max_vertex_attrib_stride = 2048;
    v2->max_shader_buffer_frag_compute = 0;
    v2->max_shader_buffer_other_stages = 0;
    v2->max_shader_image_frag_compute = 0;
    v2->max_shader_image_other_stages = 0;
    v2->max_image_samples = 0;
    v2->max_compute_work_group_invocations = 0;
    v2->max_compute_shared_memory_size = 0;
    memset(v2->max_compute_grid_size, 0, sizeof(v2->max_compute_grid_size));
    memset(v2->max_compute_block_size, 0, sizeof(v2->max_compute_block_size));
    v2->max_texture_2d_size = 2048;
    v2->max_texture_3d_size = 1;
    v2->max_texture_cube_size = 2048;
    v2->max_combined_shader_buffers = 0;
    memset(v2->max_atomic_counters, 0, sizeof(v2->max_atomic_counters));
    memset(v2->max_atomic_counter_buffers, 0,
           sizeof(v2->max_atomic_counter_buffers));
    v2->max_combined_atomic_counters = 0;
    v2->max_combined_atomic_counter_buffers = 0;
    v2->host_feature_check_version = 2;
    format_mask_clear(&v2->supported_readback_formats);
    format_mask_add_list(&v2->supported_readback_formats, readback_formats,
                         sizeof(readback_formats) / sizeof(readback_formats[0]));
    format_mask_clear(&v2->scanout);
    format_mask_add_list(&v2->scanout, readback_formats,
                         sizeof(readback_formats) / sizeof(readback_formats[0]));
    v2->capability_bits_v2 = 0;
    v2->max_video_memory = 0;
    memset(v2->renderer, 0, sizeof(v2->renderer));
    snprintf(v2->renderer, sizeof(v2->renderer),
             "virgl (G6LC reduced GLES2 probe)");
    v2->max_anisotropy = 1.0f;
    v2->max_texture_image_units = 8;
    format_mask_clear(&v2->supported_multisample_formats);
    for (i = 0; i < 6; i++)
        v2->max_const_buffer_size[i] = 65536;
    v2->num_video_caps = 0;
    memset(v2->video_caps, 0, sizeof(v2->video_caps));
    v2->max_uniform_block_size = 0;
    v2->max_tcs_outputs = 0;
    v2->max_tes_outputs = 0;
}

void virgl_renderer_fill_caps(uint32_t set, uint32_t version, void *caps)
{
    uint32_t max_ver = 0, max_size = 0;
    unsigned long seq;

    if (!real_virgl_renderer_fill_caps)
        real_virgl_renderer_fill_caps =
            (virgl_fill_caps_fn)next_sym("virgl_renderer_fill_caps");
    if (!real_virgl_renderer_fill_caps)
        return;
    real_virgl_renderer_fill_caps(set, version, caps);
    if (set < sizeof(capset_size) / sizeof(capset_size[0]))
        max_size = capset_size[set];
    if (!max_size && real_virgl_renderer_get_cap_set)
        real_virgl_renderer_get_cap_set(set, &max_ver, &max_size);
    apply_gles2_profile(set, caps, max_size);
    seq = capture_event("fill-caps set=%u version=%u bytes=%u profile=%u",
                        set, version, max_size, cap_profile());
    if (caps && max_size)
        capture_blob(seq, "capset", caps, max_size);
}
