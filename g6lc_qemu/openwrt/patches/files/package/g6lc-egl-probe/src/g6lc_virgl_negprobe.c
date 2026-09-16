// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/virtgpu_drm.h>

static int open_drm_node(void)
{
    char path[64];
    int fd;

    for (int i = 128; i < 192; i++) {
        snprintf(path, sizeof(path), "/dev/dri/renderD%d", i);
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            printf("G6LC_NEG_DRM_NODE=%s\n", path);
            return fd;
        }
    }
    for (int i = 0; i < 16; i++) {
        snprintf(path, sizeof(path), "/dev/dri/card%d", i);
        fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            printf("G6LC_NEG_DRM_NODE=%s\n", path);
            return fd;
        }
    }
    return -1;
}

static void report(const char *name, int rc, const char *detail)
{
    printf("G6LC_NEG_%s rc=%d errno=%d(%s)%s%s\n",
           name, rc, errno, strerror(errno),
           detail && *detail ? " " : "", detail ? detail : "");
}

static int getparam(int fd, uint64_t param, uint64_t *value)
{
    struct drm_virtgpu_getparam gp;

    memset(&gp, 0, sizeof(gp));
    *value = 0;
    gp.param = param;
    gp.value = (uintptr_t)value;
    return ioctl(fd, DRM_IOCTL_VIRTGPU_GETPARAM, &gp);
}

static void poll_fence(const char *name, int fd)
{
    struct pollfd pfd;
    int rc;

    if (fd < 0) {
        printf("G6LC_NEG_%s fence_fd=%d\n", name, fd);
        return;
    }
    memset(&pfd, 0, sizeof(pfd));
    pfd.fd = fd;
    pfd.events = POLLIN;
    rc = poll(&pfd, 1, 2000);
    printf("G6LC_NEG_%s fence_fd=%d poll_rc=%d revents=0x%x errno=%d(%s)\n",
           name, fd, rc, pfd.revents, errno, strerror(errno));
    close(fd);
}

int main(void)
{
    uint64_t value;
    uint32_t caps[512];
    struct drm_virtgpu_get_caps get_caps;
    struct drm_virtgpu_context_set_param ctx_param;
    struct drm_virtgpu_context_init ctx_init;
    struct drm_virtgpu_resource_create create;
    struct drm_virtgpu_resource_create bad_create;
    struct drm_virtgpu_3d_transfer_from_host bad_transfer;
    struct drm_virtgpu_execbuffer exec;
    struct drm_virtgpu_3d_wait wait;
    struct drm_virtgpu_resource_info info;
    uint32_t unknown_cmd;
    uint32_t short_len_cmd;
    int fd;
    int rc;
    int valid_bo = 0;
    int bad_bo = 0;
    int unknown_fence = -1;
    int short_fence = -1;
    char detail[128];

    fd = open_drm_node();
    if (fd < 0) {
        report("OPEN", -1, "");
        return 2;
    }

    rc = getparam(fd, VIRTGPU_PARAM_3D_FEATURES, &value);
    snprintf(detail, sizeof(detail), "value=%llu", (unsigned long long)value);
    report("GETPARAM_3D", rc, detail);

    rc = getparam(fd, VIRTGPU_PARAM_CONTEXT_INIT, &value);
    snprintf(detail, sizeof(detail), "value=%llu", (unsigned long long)value);
    report("GETPARAM_CONTEXT_INIT", rc, detail);

    rc = getparam(fd, VIRTGPU_PARAM_SUPPORTED_CAPSET_IDs, &value);
    snprintf(detail, sizeof(detail), "mask=0x%llx", (unsigned long long)value);
    report("GETPARAM_CAPSETS", rc, detail);

    memset(&get_caps, 0, sizeof(get_caps));
    memset(caps, 0, sizeof(caps));
    get_caps.cap_set_id = 0xdead;
    get_caps.addr = (uintptr_t)caps;
    get_caps.size = sizeof(caps);
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_GET_CAPS, &get_caps);
    report("GET_CAPS_BAD_ID", rc, "expected_local_error=EINVAL");

    memset(&ctx_param, 0, sizeof(ctx_param));
    memset(&ctx_init, 0, sizeof(ctx_init));
    ctx_param.param = VIRTGPU_CONTEXT_PARAM_CAPSET_ID;
    ctx_param.value = 2;
    ctx_init.num_params = 1;
    ctx_init.ctx_set_params = (uintptr_t)&ctx_param;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_CONTEXT_INIT, &ctx_init);
    report("CONTEXT_INIT_ABSENT", rc, "expected_local_error=EINVAL");

    memset(&create, 0, sizeof(create));
    create.target = 2;
    create.format = 2;
    create.bind = 0x10000a;
    create.width = 16;
    create.height = 16;
    create.depth = 1;
    create.array_size = 1;
    create.size = 16 * 16 * 4;
    create.stride = 64;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_RESOURCE_CREATE, &create);
    snprintf(detail, sizeof(detail), "bo=%u res=%u",
             create.bo_handle, create.res_handle);
    report("RESOURCE_CREATE_VALID", rc, detail);
    if (rc == 0)
        valid_bo = create.bo_handle;

    memset(&bad_create, 0, sizeof(bad_create));
    bad_create.target = 0xffff;
    bad_create.format = 0xffff;
    bad_create.bind = 0xffffffffu;
    bad_create.width = 16;
    bad_create.height = 16;
    bad_create.depth = 1;
    bad_create.array_size = 1;
    bad_create.size = 4096;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_RESOURCE_CREATE, &bad_create);
    snprintf(detail, sizeof(detail), "bo=%u res=%u",
             bad_create.bo_handle, bad_create.res_handle);
    report("RESOURCE_CREATE_BAD", rc, detail);
    if (rc == 0)
        bad_bo = bad_create.bo_handle;

    memset(&bad_transfer, 0, sizeof(bad_transfer));
    bad_transfer.bo_handle = 0xdead;
    bad_transfer.box.w = 1;
    bad_transfer.box.h = 1;
    bad_transfer.box.d = 1;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &bad_transfer);
    report("TRANSFER_BAD_BO", rc, "expected_local_error=ENOENT");

    if (valid_bo) {
        memset(&bad_transfer, 0, sizeof(bad_transfer));
        bad_transfer.bo_handle = valid_bo;
        bad_transfer.box.x = 15;
        bad_transfer.box.w = 2;
        bad_transfer.box.h = 1;
        bad_transfer.box.d = 1;
        errno = 0;
        rc = ioctl(fd, DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST, &bad_transfer);
        report("TRANSFER_BAD_BOX", rc, "queued_to_backend=1");

        memset(&wait, 0, sizeof(wait));
        wait.handle = valid_bo;
        errno = 0;
        rc = ioctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wait);
        report("WAIT_AFTER_BAD_BOX", rc, "bo_fence=1");
    }

    if (bad_bo) {
        memset(&wait, 0, sizeof(wait));
        wait.handle = bad_bo;
        errno = 0;
        rc = ioctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wait);
        report("WAIT_AFTER_BAD_CREATE", rc, "bo_fence=1");
    }

    unknown_cmd = 0x000000ffu;
    memset(&exec, 0, sizeof(exec));
    exec.flags = VIRTGPU_EXECBUF_FENCE_FD_OUT;
    exec.size = sizeof(unknown_cmd);
    exec.command = (uintptr_t)&unknown_cmd;
    exec.fence_fd = -1;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_EXECBUFFER, &exec);
    unknown_fence = exec.fence_fd;
    snprintf(detail, sizeof(detail), "fence_fd=%d", unknown_fence);
    report("EXEC_UNKNOWN_CMD", rc, detail);

    short_len_cmd = 0x00010000u;
    memset(&exec, 0, sizeof(exec));
    exec.flags = VIRTGPU_EXECBUF_FENCE_FD_OUT;
    exec.size = sizeof(short_len_cmd);
    exec.command = (uintptr_t)&short_len_cmd;
    exec.fence_fd = -1;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_EXECBUFFER, &exec);
    short_fence = exec.fence_fd;
    snprintf(detail, sizeof(detail), "fence_fd=%d", short_fence);
    report("EXEC_SHORT_BODY", rc, detail);

    memset(&wait, 0, sizeof(wait));
    wait.handle = 0xdead;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_WAIT, &wait);
    report("WAIT_BAD_BO", rc, "expected_local_error=ENOENT");

    memset(&info, 0, sizeof(info));
    info.bo_handle = 0xdead;
    errno = 0;
    rc = ioctl(fd, DRM_IOCTL_VIRTGPU_RESOURCE_INFO, &info);
    report("RESOURCE_INFO_BAD_BO", rc, "expected_local_error=ENOENT");

    poll_fence("EXEC_UNKNOWN_CMD", unknown_fence);
    poll_fence("EXEC_SHORT_BODY", short_fence);
    sleep(1);
    printf("G6LC_NEG_DONE\n");
    close(fd);
    return 0;
}
