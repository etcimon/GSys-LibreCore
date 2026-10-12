// SPDX-License-Identifier: MIT
// vktri — G1d guest proof: the first end-to-end triangle on the
// stock Venus path.  64x64 R8G8B8A8_UNORM color attachment, one
// render pass (CLEAR/STORE -> TRANSFER_SRC_OPTIMAL), a graphics
// pipeline (vs_passthru + fs_color SPIR-V, dynamic viewport+scissor),
// a 3-vertex Draw, CopyImageToBuffer readback, and a byte-compare
// against an in-file C reference rasterizer.
//
// The reference mirrors g6lc_apu_rast.sv's exact op sequence in f32
// (fpnew is correctly-rounded IEEE-754; -ffp-contract=off keeps the
// host fp ops at single precision): viewport FMADDs, F2I RNE to
// 16.8 fixed, 64-bit edge functions at pixel centers, the top-left
// rule, lambda = I2F(E)>>shf * rcp_area, p_i = lambda_i*rcp_w_i,
// s = p0+p1+p2, rcp_s = 1/s, varyings (p0*V0 + p1*V1 + p2*V2)*rcp_s,
// FS "vcol*0.5 + FragCoord.x*0.001", UNORM8 RNE.  Compare tolerance
// +-1 LSB per channel.
//
//   gcc -O2 -ffp-contract=off -fexcess-precision=standard -o vktri \
//       vktri.c -lvulkan -lm && ./vktri vs_passthru.spv fs_color.spv
//
// Exit 0 + "G6LC_VKTRI_PASS covered=N maxdiff=D" on success.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#define W   64
#define H   64
#define NPX (W * H)

static void chk(VkResult r, const char *what)
{
    if (r != VK_SUCCESS) {
        printf("FAIL: %s -> %d\n", what, (int)r);
        exit(1);
    }
}

static uint32_t *spv_load(const char *path, long *n)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    *n = ftell(f);
    rewind(f);
    uint32_t *w = malloc(*n);
    if (fread(w, 1, *n, f) != (size_t)*n) { perror("spv read"); exit(1); }
    fclose(f);
    return w;
}

/* ---------- reference rasterizer (mirrors g6lc_apu_rast.sv) ------- */

static float f_i2f(int64_t v)  { return (float)v; }
static int32_t f_f2i(float v)  { return (int32_t)lrintf(v); }
static uint8_t f_u8(float f)
{
    if (f != f || f >= 1.0f) return 255;
    if (f <= 0.0f)           return 0;
    return (uint8_t)lrintf(f * 255.0f);
}

/* vertex: pos.xy + color rgba (stride 24 = 6 floats); spec-CCW
   winding: negative framebuffer shoelace (Vulkan's signed area is the
   negated shoelace — frontFace=CCW means front iff that area > 0) */
static const float verts[3][6] = {
    {-0.5f, -0.5f, 1.0f, 0.0f, 0.0f, 1.0f},
    { 0.0f,  0.5f, 0.0f, 0.0f, 1.0f, 1.0f},
    { 0.5f, -0.5f, 0.0f, 1.0f, 0.0f, 1.0f},
};

static int ref_raster(uint8_t fb[NPX][4])
{
    /* vs_passthru: Position={x,y,0.5,1.0}, varying = {rgb, VertexIndex} */
    float ndc[3][3], vz[3], vrw[3], var[3][4];
    int32_t xi[3], yi[3];
    for (int i = 0; i < 3; i++) {
        vrw[i] = 1.0f / 1.0f;                       /* rcp_w = 1/w */
        ndc[i][0] = verts[i][0] * vrw[i];
        ndc[i][1] = verts[i][1] * vrw[i];
        ndc[i][2] = 0.5f * vrw[i];
        var[i][0] = verts[i][2];
        var[i][1] = verts[i][3];
        var[i][2] = verts[i][4];
        var[i][3] = (float)i;                       /* gl_VertexIndex */
    }
    /* vp = {0,0,64,64,0,1}: vphw = w*0.5, vphh = h*0.5, vpdz = maxz-minz */
    const float vphw = 64.0f * 0.5f, vphh = 64.0f * 0.5f;
    const float vpdz = 1.0f - 0.0f;
    for (int i = 0; i < 3; i++) {
        float sx = fmaf(ndc[i][0] + 1.0f, vphw, 0.0f);
        float sy = fmaf(ndc[i][1] + 1.0f, vphh, 0.0f);
        vz[i]    = fmaf(ndc[i][2], vpdz, 0.0f);
        xi[i] = f_f2i(sx * 256.0f);
        yi[i] = f_f2i(sy * 256.0f);
    }
    /* signed area, cull BACK + front_ccw: drop !front or area==0 */
    int64_t area = (int64_t)(xi[1] - xi[0]) * (yi[2] - yi[0]) -
                   (int64_t)(xi[2] - xi[0]) * (yi[1] - yi[0]);
    int front = (area < 0) == 1;                    /* front_ccw */
    int covered0 = 0;
    if (area == 0 || !front)
        return 0;
    if (area < 0) {                                 /* swap v1/v2 */
        area = -area;
        int32_t t;
        t = xi[1]; xi[1] = xi[2]; xi[2] = t;
        t = yi[1]; yi[1] = yi[2]; yi[2] = t;
        float tf;
        tf = vz[1]; vz[1] = vz[2]; vz[2] = tf;
        tf = vrw[1]; vrw[1] = vrw[2]; vrw[2] = tf;
        for (int c = 0; c < 4; c++) {
            tf = var[1][c]; var[1][c] = var[2][c]; var[2][c] = tf;
        }
    }
    /* msb-based shift so I2F stays in range (RTL S_PR_SHF) */
    uint64_t ua = (uint64_t)area;
    int msb = 63 - __builtin_clzll(ua);
    int shf = msb > 28 ? msb - 28 : 0;
    float rcpa = 1.0f / f_i2f(area >> shf);
    /* edge geometry: E_k anchored at (k+1)%3 toward (k+2)%3 */
    int32_t ex[3], ey[3];
    int64_t edx[3], edy[3];
    int tl[3];
    ex[0] = xi[1]; ey[0] = yi[1];
    edx[0] = xi[2] - xi[1]; edy[0] = yi[2] - yi[1];
    ex[1] = xi[2]; ey[1] = yi[2];
    edx[1] = xi[0] - xi[2]; edy[1] = yi[0] - yi[2];
    ex[2] = xi[0]; ey[2] = yi[0];
    edx[2] = xi[1] - xi[0]; edy[2] = yi[1] - yi[0];
    for (int k = 0; k < 3; k++) {
        int a = (k + 1) % 3, b = (k + 2) % 3;
        tl[k] = (yi[a] > yi[b]) || (yi[a] == yi[b] && xi[a] < xi[b]);
    }
    /* bbox = floor(min)-ish, ceil(max-128)-ish, clamped to scissor */
    int32_t xmin = xi[0] < xi[1] ? (xi[0] < xi[2] ? xi[0] : xi[2])
                                 : (xi[1] < xi[2] ? xi[1] : xi[2]);
    int32_t xmax = xi[0] > xi[1] ? (xi[0] > xi[2] ? xi[0] : xi[2])
                                 : (xi[1] > xi[2] ? xi[1] : xi[2]);
    int32_t ymin = yi[0] < yi[1] ? (yi[0] < yi[2] ? yi[0] : yi[2])
                                 : (yi[1] < yi[2] ? yi[1] : yi[2]);
    int32_t ymax = yi[0] > yi[1] ? (yi[0] > yi[2] ? yi[0] : yi[2])
                                 : (yi[1] > yi[2] ? yi[1] : yi[2]);
    int32_t lo_x = xmin >> 8, hi_x = (xmax - 128) >> 8;
    int32_t lo_y = ymin >> 8, hi_y = (ymax - 128) >> 8;
    if (lo_x < 0) lo_x = 0;
    if (lo_y < 0) lo_y = 0;
    if (hi_x > W - 1) hi_x = W - 1;
    if (hi_y > H - 1) hi_y = H - 1;
    for (int32_t py = lo_y; py <= hi_y; py++) {
        for (int32_t px = lo_x; px <= hi_x; px++) {
            int64_t cpx = px * 256 + 128, cpy = py * 256 + 128;
            int64_t e[3];
            int in = 1;
            for (int k = 0; k < 3; k++) {
                e[k] = edx[k] * (cpy - ey[k]) - edy[k] * (cpx - ex[k]);
                if (!(e[k] > 0 || (e[k] == 0 && tl[k]))) in = 0;
            }
            if (!in) continue;
            float lam[3], pv[3];
            for (int k = 0; k < 3; k++) {
                lam[k] = f_i2f(e[k] >> shf);
                lam[k] = lam[k] * rcpa;
                pv[k]  = lam[k] * vrw[k];
            }
            float s = pv[0] + pv[1];
            s = s + pv[2];
            float rcp_s = 1.0f / s;
            float fz = fmaf(lam[0], vz[0], 0.0f);
            fz = fmaf(lam[1], vz[1], fz);
            fz = fmaf(lam[2], vz[2], fz);
            (void)fz;
            float fcx = f_i2f(2 * px + 1) * 0.5f;
            float vout[4];
            for (int c = 0; c < 4; c++) {
                float t = pv[0] * var[0][c];
                t = fmaf(pv[1], var[1][c], t);
                t = fmaf(pv[2], var[2][c], t);
                vout[c] = t * rcp_s;
            }
            /* fs_color: o = vcol*0.5 + FragCoord.x*0.001 */
            float fc01 = fcx * 0.001f;
            fb[py * W + px][0] = f_u8(vout[0] * 0.5f + fc01);
            fb[py * W + px][1] = f_u8(vout[1] * 0.5f + fc01);
            fb[py * W + px][2] = f_u8(vout[2] * 0.5f + fc01);
            fb[py * W + px][3] = f_u8(vout[3] * 0.5f + fc01);
            covered0++;
        }
    }
    return covered0;
}

/* ---------------------------------------------------------------- */

int main(int argc, char **argv)
{
    long vs_n, fs_n;
    uint32_t *vs = spv_load(argc > 1 ? argv[1] : "vs_passthru.spv", &vs_n);
    uint32_t *fs = spv_load(argc > 2 ? argv[2] : "fs_color.spv", &fs_n);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vktri", 0, "vktri", 0, VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                NULL, 0, &ai, 0, NULL, 0, NULL};
    VkInstance inst;
    chk(vkCreateInstance(&ici, NULL, &inst), "vkCreateInstance");

    uint32_t npdev = 0;
    chk(vkEnumeratePhysicalDevices(inst, &npdev, NULL), "enum phys");
    if (!npdev) { printf("FAIL: no physical devices\n"); return 1; }
    VkPhysicalDevice pdevs[8];
    if (npdev > 8) npdev = 8;
    chk(vkEnumeratePhysicalDevices(inst, &npdev, pdevs), "enum phys2");
    VkPhysicalDevice pdev = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < npdev; i++) {
        VkPhysicalDeviceProperties pp;
        vkGetPhysicalDeviceProperties(pdevs[i], &pp);
        printf("pd%u: %s\n", i, pp.deviceName);
        if (strstr(pp.deviceName, "Venus") ||
            strstr(pp.deviceName, "LibreCore"))
            pdev = pdevs[i];
    }
    if (!pdev) { printf("FAIL: no Venus PD\n"); return 1; }

    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    uint32_t mt_host = UINT32_MAX;
    for (uint32_t t = 0; t < mp.memoryTypeCount; t++) {
        VkFlags fl = mp.memoryTypes[t].propertyFlags;
        if ((fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (fl & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) &&
            mt_host == UINT32_MAX)
            mt_host = t;
    }
    if (mt_host == UINT32_MAX) { printf("FAIL: no host-visible type\n"); return 1; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
    VkPhysicalDeviceFeatures en = {0};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL,
                              0, 1, &qci, 0, NULL, 0, NULL, &en};
    VkDevice dev;
    chk(vkCreateDevice(pdev, &dci, NULL, &dev), "vkCreateDevice");
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    /* ---- 64x64 RGBA8 color attachment --------------------------- */
    VkImage img;
    VkImageCreateInfo ic = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL,
        0, VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM,
        {W, H, 1}, 1, 1, VK_SAMPLE_COUNT_1_BIT,
        VK_IMAGE_TILING_OPTIMAL,
        VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL, VK_IMAGE_LAYOUT_UNDEFINED};
    chk(vkCreateImage(dev, &ic, NULL, &img), "create image");
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(dev, img, &mr);
    uint32_t mti = UINT32_MAX;
    for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
        if ((mr.memoryTypeBits & (1u << t)) &&
            !(mp.memoryTypes[t].propertyFlags &
              VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
            { mti = t; break; }
    if (mti == UINT32_MAX)
        mti = __builtin_ctz(mr.memoryTypeBits);
    VkDeviceMemory img_mem;
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, mr.size, mti};
    chk(vkAllocateMemory(dev, &mai, NULL, &img_mem), "img mem");
    chk(vkBindImageMemory(dev, img, img_mem, 0), "img bind");

    VkImageView view;
    VkImageViewCreateInfo vc = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        NULL, 0, img, VK_IMAGE_VIEW_TYPE_2D,
        VK_FORMAT_R8G8B8A8_UNORM,
        {VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
         VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY},
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    chk(vkCreateImageView(dev, &vc, NULL, &view), "view");

    /* ---- render pass + framebuffer ------------------------------ */
    VkAttachmentDescription ad = {0, VK_FORMAT_R8G8B8A8_UNORM,
        VK_SAMPLE_COUNT_1_BIT,
        VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE,
        VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
    VkAttachmentReference aref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp = {0, VK_PIPELINE_BIND_POINT_GRAPHICS,
        0, NULL, 1, &aref, NULL, NULL, 0, NULL};
    VkRenderPassCreateInfo rpci = {VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        NULL, 0, 1, &ad, 1, &sp, 0, NULL};
    VkRenderPass rp;
    chk(vkCreateRenderPass(dev, &rpci, NULL, &rp), "render pass");
    VkFramebufferCreateInfo fbci = {
        VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, NULL, 0, rp,
        1, &view, W, H, 1};
    VkFramebuffer fbh;
    chk(vkCreateFramebuffer(dev, &fbci, NULL, &fbh), "framebuffer");

    /* ---- pipeline layout (no descriptor sets) + shaders --------- */
    VkPipelineLayoutCreateInfo plci = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0,
        0, NULL, 0, NULL};
    VkPipelineLayout playout;
    chk(vkCreatePipelineLayout(dev, &plci, NULL, &playout), "playout");

    VkShaderModuleCreateInfo smci = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0,
        (size_t)vs_n, vs};
    VkShaderModule vsm;
    chk(vkCreateShaderModule(dev, &smci, NULL, &vsm), "vs module");
    smci.codeSize = (size_t)fs_n;
    smci.pCode = fs;
    VkShaderModule fsm;
    chk(vkCreateShaderModule(dev, &smci, NULL, &fsm), "fs module");

    /* ---- graphics pipeline -------------------------------------- */
    VkPipelineShaderStageCreateInfo stages[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_VERTEX_BIT, vsm, "main", NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_FRAGMENT_BIT, fsm, "main", NULL},
    };
    VkVertexInputBindingDescription vbind = {0, 24,
        VK_VERTEX_INPUT_RATE_VERTEX};
    VkVertexInputAttributeDescription vattr[2] = {
        {0, 0, VK_FORMAT_R32G32_SFLOAT, 0},
        {1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 8},
    };
    VkPipelineVertexInputStateCreateInfo vin = {
        VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        NULL, 0, 1, &vbind, 2, vattr};
    VkPipelineInputAssemblyStateCreateInfo ia = {
        VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        NULL, 0, VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, VK_FALSE};
    VkPipelineViewportStateCreateInfo vps = {
        VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        NULL, 0, 1, NULL, 1, NULL};
    VkPipelineRasterizationStateCreateInfo rast = {
        VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        NULL, 0, VK_FALSE, VK_FALSE, VK_POLYGON_MODE_FILL,
        VK_CULL_MODE_BACK_BIT, VK_FRONT_FACE_COUNTER_CLOCKWISE,
        VK_FALSE, 0.0f, 0.0f, 0.0f, 1.0f};
    VkPipelineMultisampleStateCreateInfo msaa = {
        VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        NULL, 0, VK_SAMPLE_COUNT_1_BIT, VK_FALSE, 0.0f, NULL,
        VK_FALSE, VK_FALSE};
    VkPipelineColorBlendAttachmentState cba = {
        VK_FALSE, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ZERO,
        VK_BLEND_OP_ADD, VK_BLEND_FACTOR_ONE, VK_BLEND_FACTOR_ZERO,
        VK_BLEND_OP_ADD, 0xF};
    VkPipelineColorBlendStateCreateInfo cbst = {
        VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        NULL, 0, VK_FALSE, VK_LOGIC_OP_COPY, 1, &cba, {0, 0, 0, 0}};
    VkDynamicState dyn[2] = {VK_DYNAMIC_STATE_VIEWPORT,
                             VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dyns = {
        VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        NULL, 0, 2, dyn};
    VkGraphicsPipelineCreateInfo gpci = {
        VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, NULL, 0,
        2, stages, &vin, &ia, NULL, &vps, &rast, &msaa,
        NULL, &cbst, &dyns, playout, rp, 0, VK_NULL_HANDLE, -1};
    VkPipeline pipe;
    chk(vkCreateGraphicsPipelines(dev, VK_NULL_HANDLE, 1, &gpci, NULL,
                                  &pipe), "graphics pipeline");

    /* ---- host-visible vertex + readback buffers ----------------- */
    VkBuffer vb, rb;
    VkDeviceMemory vb_mem, rb_mem;
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        NULL, 0, sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    chk(vkCreateBuffer(dev, &bci, NULL, &vb), "vb");
    vkGetBufferMemoryRequirements(dev, vb, &mr);
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mt_host;
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &vb_mem), "vb mem");
    chk(vkBindBufferMemory(dev, vb, vb_mem, 0), "vb bind");
    void *p;
    chk(vkMapMemory(dev, vb_mem, 0, sizeof(verts), 0, &p), "vb map");
    memcpy(p, verts, sizeof(verts));
    vkUnmapMemory(dev, vb_mem);

    bci.size = NPX * 4;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    chk(vkCreateBuffer(dev, &bci, NULL, &rb), "rb");
    vkGetBufferMemoryRequirements(dev, rb, &mr);
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mt_host;
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &rb_mem), "rb mem");
    chk(vkBindBufferMemory(dev, rb, rb_mem, 0), "rb bind");

    /* ---- command buffer ----------------------------------------- */
    VkCommandPoolCreateInfo cpci2 = {
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, 0};
    VkCommandPool cpool;
    chk(vkCreateCommandPool(dev, &cpci2, NULL, &cpool), "cmdpool");
    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, cpool,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    chk(vkAllocateCommandBuffers(dev, &cbai, &cb), "cmdbuf");
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    chk(vkBeginCommandBuffer(cb, &bbi), "begin cb");

    VkImageMemoryBarrier imb = {
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        0, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0,
                         0, NULL, 0, NULL, 1, &imb);

    VkClearValue clr = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    VkRenderPassBeginInfo rpb = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        NULL, rp, fbh, {{0, 0}, {W, H}}, 1, &clr};
    vkCmdBeginRenderPass(cb, &rpb, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, pipe);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(cb, 0, 1, &vb, &off);
    VkViewport vp = {0.0f, 0.0f, (float)W, (float)H, 0.0f, 1.0f};
    vkCmdSetViewport(cb, 0, 1, &vp);
    VkRect2D sc = {{0, 0}, {W, H}};
    vkCmdSetScissor(cb, 0, 1, &sc);
    vkCmdDraw(cb, 3, 1, 0, 0);
    vkCmdEndRenderPass(cb);

    VkBufferImageCopy bic = {0, 0, 0,
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {W, H, 1}};
    vkCmdCopyImageToBuffer(cb, img,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           rb, 1, &bic);

    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL,
        VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0,
                         1, &mb, 0, NULL, 0, NULL);
    chk(vkEndCommandBuffer(cb), "end cb");

    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                             NULL, 0};
    VkFence fence;
    chk(vkCreateFence(dev, &fci, NULL, &fence), "fence");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                       0, NULL, NULL, 1, &cb, 0, NULL};
    chk(vkQueueSubmit(q, 1, &si, fence), "submit");
    chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX),
        "fence wait");

    /* ---- reference + compare ------------------------------------ */
    static uint8_t exp[NPX][4];
    memset(exp, 0, sizeof(exp));
    for (int i = 0; i < NPX; i++)
        exp[i][0] = exp[i][1] = exp[i][2] = 0, exp[i][3] = 255;
    int covered = ref_raster(exp);

    uint8_t got[NPX][4];
    chk(vkMapMemory(dev, rb_mem, 0, bci.size, 0, &p), "rb map");
    memcpy(got, p, sizeof(got));
    vkUnmapMemory(dev, rb_mem);

    int bad = 0, maxd = 0;
    for (int i = 0; i < NPX; i++)
        for (int c = 0; c < 4; c++) {
            int d = abs((int)got[i][c] - (int)exp[i][c]);
            if (d > 1) {
                if (bad < 8)
                    printf("mismatch px(%d,%d) ch%d got=%u exp=%u\n",
                           i % W, i / W, c, got[i][c], exp[i][c]);
                bad++;
            }
            if (d > maxd) maxd = d;
        }
    printf("covered=%d mismatches(>1lsb)=%d maxdiff=%d\n",
           covered, bad, maxd);
    printf("vktri coverage (16x16 decimated):\n");
    for (int gy = 0; gy < 16; gy++) {
        printf("  ");
        for (int gx = 0; gx < 16; gx++) {
            int any = 0;
            for (int y = gy * 4; y < gy * 4 + 4; y++)
                for (int x = gx * 4; x < gx * 4 + 4; x++)
                    if (got[y * W + x][0] != 0 || got[y * W + x][1] != 0 ||
                        got[y * W + x][2] != 0)
                        any = 1;
            putchar(any ? '#' : '.');
        }
        putchar('\n');
    }
    if (bad) {
        printf("FAIL: %d pixel-channel mismatches beyond 1 LSB\n", bad);
        return 1;
    }
    printf("G6LC_VKTRI_PASS covered=%d maxdiff=%d\n", covered, maxd);
    return 0;
}
