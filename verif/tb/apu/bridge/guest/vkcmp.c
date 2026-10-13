// SPDX-License-Identifier: MIT
// vkcmp — G2c broad oracle: render identical scenes on the Venus
// device (the LibreCore APU RTL behind the bridge) and on Mesa
// lavapipe (llvmpipe) in the same guest, then compare the readback
// byte-for-byte within a per-scene tolerance + pixel budget.
//
// Every scene uses the same Vulkan code path on both devices: one
// VkDevice + queue per physical device, per-scene render pass,
// framebuffer, pipeline (dynamic viewport+scissor), command buffer,
// fence, host-visible vertex/staging/readback buffers, and a
// CopyImageToBuffer readback of a 64x64 color attachment.
//
//   ./vkcmp vs_passthru.spv fs_color.spv vs_pc.spv fs_vcol.spv \
//           vs_pos3.spv vs_inst.spv vs_tex.spv fs_mip.spv \
//           vs_clip.spv vs_uvc.spv fs_deriv2.spv
//
// Prints one SCENE line per scene and
//   G6LC_VKCMP_PASS scenes=K            on success, else
//   FAIL: <what>                        on failure (exit 1).
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define W   64
#define H   64
#define NPX (W * H)

/* shader file indices (argv order) */
enum {
    S_VPAS,   /* vs_passthru — scenes 1,7 */
    S_FCOL,   /* fs_color    — scenes 1,7 */
    S_VPC,    /* vs_pc       — scene 3    */
    S_FVCOL,  /* fs_vcol     — scenes 2,3,4,6 */
    S_VPOS3,  /* vs_pos3     — scene 2    */
    S_VINST,  /* vs_inst     — scene 4    */
    S_VTEX,   /* vs_tex      — scene 5    */
    S_FMIP,   /* fs_mip      — scene 5    */
    S_VCLIP,  /* vs_clip     — scene 6    */
    S_VUVC,   /* vs_uvc      — scene 8    */
    S_FDERIV, /* fs_deriv2   — scene 8    */
    S_N
};
static const char *spv_dflt[S_N] = {
    "vs_passthru.spv", "fs_color.spv", "vs_pc.spv", "fs_vcol.spv",
    "vs_pos3.spv", "vs_inst.spv", "vs_tex.spv", "fs_mip.spv",
    "vs_clip.spv", "vs_uvc.spv", "fs_deriv2.spv"};

typedef struct {
    uint32_t *w;
    long      n;
} spv_t;

static void chk(VkResult r, const char *what)
{
    if (r != VK_SUCCESS) {
        printf("FAIL: %s -> %d\n", what, (int)r);
        exit(1);
    }
}

static spv_t spv_load(const char *path)
{
    spv_t s;
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END);
    s.n = ftell(f);
    rewind(f);
    s.w = malloc(s.n);
    if (fread(s.w, 1, s.n, f) != (size_t)s.n) { perror("spv read"); exit(1); }
    fclose(f);
    return s;
}

static double wall(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* ---------------- device context + helpers ----------------------- */

typedef struct {
    VkPhysicalDevice              pd;
    VkDevice                      dev;
    VkQueue                       q;
    VkCommandPool                 cpool;
    VkPhysicalDeviceMemoryProperties mp;
    uint32_t                      mt_host;
    char                          name[256];
} vkdev;

/* memory type in `bits` preferring !HOST_VISIBLE, else first set */
static uint32_t mt_img(vkdev *d, uint32_t bits)
{
    for (uint32_t t = 0; t < d->mp.memoryTypeCount; t++)
        if ((bits & (1u << t)) &&
            !(d->mp.memoryTypes[t].propertyFlags &
              VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
            return t;
    return __builtin_ctz(bits);
}

static void mkbuf(vkdev *d, VkDeviceSize sz, VkFlags usage,
                  VkBuffer *b, VkDeviceMemory *m)
{
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        NULL, 0, sz, usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    chk(vkCreateBuffer(d->dev, &bci, NULL, b), "buffer");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(d->dev, *b, &mr);
    uint32_t mti = d->mt_host;
    if (!(mr.memoryTypeBits & (1u << mti)))
        mti = __builtin_ctz(mr.memoryTypeBits);
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        NULL, mr.size, mti};
    chk(vkAllocateMemory(d->dev, &mai, NULL, m), "buf mem");
    chk(vkBindBufferMemory(d->dev, *b, *m, 0), "buf bind");
}

static void upload(vkdev *d, VkDeviceMemory m, const void *src,
                   VkDeviceSize n)
{
    void *p;
    chk(vkMapMemory(d->dev, m, 0, n, 0, &p), "upload map");
    memcpy(p, src, n);
    vkUnmapMemory(d->dev, m);
}

static void mkimg(vkdev *d, VkFormat f, int w, int h, int mips,
                  VkFlags usage, VkImage *im, VkDeviceMemory *m)
{
    VkImageCreateInfo ic = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL,
        0, VK_IMAGE_TYPE_2D, f, {(uint32_t)w, (uint32_t)h, 1}, mips, 1,
        VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_TILING_OPTIMAL, usage,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL, VK_IMAGE_LAYOUT_UNDEFINED};
    chk(vkCreateImage(d->dev, &ic, NULL, im), "image");
    VkMemoryRequirements mr;
    vkGetImageMemoryRequirements(d->dev, *im, &mr);
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        NULL, mr.size, mt_img(d, mr.memoryTypeBits)};
    chk(vkAllocateMemory(d->dev, &mai, NULL, m), "img mem");
    chk(vkBindImageMemory(d->dev, *im, *m, 0), "img bind");
}

static VkImageView mkview(vkdev *d, VkImage im, VkFormat f,
                          VkImageAspectFlags asp, int levels)
{
    VkImageViewCreateInfo vc = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        NULL, 0, im, VK_IMAGE_VIEW_TYPE_2D, f,
        {VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
         VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY},
        {asp, 0, (uint32_t)levels, 0, 1}};
    VkImageView v;
    chk(vkCreateImageView(d->dev, &vc, NULL, &v), "view");
    return v;
}

static VkShaderModule mksm(vkdev *d, const spv_t *s)
{
    VkShaderModuleCreateInfo ci = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0,
        (size_t)s->n, s->w};
    VkShaderModule m;
    chk(vkCreateShaderModule(d->dev, &ci, NULL, &m), "shader module");
    return m;
}

/* single-subpass render pass: color CLEAR/STORE -> TRANSFER_SRC,
   optional D32_SFLOAT depth CLEAR/STORE */
static VkRenderPass mkrp(vkdev *d, VkFormat cf, int depth)
{
    VkAttachmentDescription ads[2] = {
        {0, cf, VK_SAMPLE_COUNT_1_BIT,
         VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE,
         VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
         VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL},
        {0, VK_FORMAT_D32_SFLOAT, VK_SAMPLE_COUNT_1_BIT,
         VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE,
         VK_ATTACHMENT_LOAD_OP_DONT_CARE, VK_ATTACHMENT_STORE_OP_DONT_CARE,
         VK_IMAGE_LAYOUT_UNDEFINED,
         VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL}};
    VkAttachmentReference cref = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkAttachmentReference dref = {
        1, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sp = {0, VK_PIPELINE_BIND_POINT_GRAPHICS,
        0, NULL, 1, &cref, NULL, NULL, 0, NULL};
    if (depth)
        sp.pDepthStencilAttachment = &dref;
    VkRenderPassCreateInfo rpci = {
        VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, NULL, 0,
        depth ? 2 : 1, ads, 1, &sp, 0, NULL};
    VkRenderPass rp;
    chk(vkCreateRenderPass(d->dev, &rpci, NULL, &rp), "render pass");
    return rp;
}

typedef struct {
    VkShaderModule vs, fs;
    uint32_t       nbind;
    VkVertexInputBindingDescription   binds[4];
    uint32_t       natt;
    VkVertexInputAttributeDescription atts[8];
    VkPrimitiveTopology topo;
    int            depth;    /* depth test + write, VK_COMPARE_OP_LESS */
    int            blend;    /* SRC_ALPHA / ONE_MINUS_SRC_ALPHA ADD */
    uint8_t        wmask;
    VkPipelineLayout layout;
    VkRenderPass    rp;
} gp_t;

static VkPipeline mkgp(vkdev *d, const gp_t *g)
{
    VkPipelineShaderStageCreateInfo stages[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_VERTEX_BIT, g->vs, "main", NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_FRAGMENT_BIT, g->fs, "main", NULL}};
    VkPipelineVertexInputStateCreateInfo vin = {
        VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        NULL, 0, g->nbind, g->binds, g->natt, g->atts};
    VkPipelineInputAssemblyStateCreateInfo ia = {
        VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        NULL, 0, g->topo, VK_FALSE};
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
        (VkBool32)g->blend,
        VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        VK_BLEND_OP_ADD,
        VK_BLEND_FACTOR_SRC_ALPHA, VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        VK_BLEND_OP_ADD, g->wmask};
    VkPipelineColorBlendStateCreateInfo cbst = {
        VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        NULL, 0, VK_FALSE, VK_LOGIC_OP_COPY, 1, &cba, {0, 0, 0, 0}};
    VkPipelineDepthStencilStateCreateInfo ds = {
        VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        NULL, 0, (VkBool32)g->depth, (VkBool32)g->depth,
        VK_COMPARE_OP_LESS, VK_FALSE, VK_FALSE,
        {VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
         VK_COMPARE_OP_NEVER, 0, 0, 0},
        {VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP, VK_STENCIL_OP_KEEP,
         VK_COMPARE_OP_NEVER, 0, 0, 0},
        0.0f, 1.0f};
    VkDynamicState dyn[2] = {VK_DYNAMIC_STATE_VIEWPORT,
                             VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dyns = {
        VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        NULL, 0, 2, dyn};
    VkGraphicsPipelineCreateInfo gpci = {
        VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, NULL, 0,
        2, stages, &vin, &ia, NULL, &vps, &rast, &msaa,
        g->depth ? &ds : NULL, &cbst, &dyns, g->layout, g->rp, 0,
        VK_NULL_HANDLE, -1};
    VkPipeline p;
    chk(vkCreateGraphicsPipelines(d->dev, VK_NULL_HANDLE, 1, &gpci,
                                  NULL, &p), "graphics pipeline");
    return p;
}

/* per-scene resource bundle (leaked — process-scoped test) */
typedef struct {
    VkImage        cimg, dimg, tex;
    VkDeviceMemory cmem, dmem, texm;
    VkImageView    cview, dview, tv;
    VkRenderPass   rp;
    VkFramebuffer  fb;
    VkPipelineLayout pl;
    VkPipeline     pipe;
    VkBuffer       vb, vb2, ib, stage, rb;
    VkDeviceMemory vbm, vb2m, ibm, stagem, rbm;
    VkDescriptorSetLayout dsl;
    VkDescriptorPool pool;
    VkDescriptorSet  dset;
    VkSampler       samp;
    VkCommandBuffer cb;
} obj_t;

static void barrier_img(VkCommandBuffer cb, VkImage im,
                        VkImageAspectFlags asp, uint32_t levels,
                        VkImageLayout from, VkImageLayout to,
                        VkAccessFlags sa, VkAccessFlags da,
                        VkPipelineStageFlags ss, VkPipelineStageFlags ds2)
{
    VkImageMemoryBarrier imb = {
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, sa, da, from, to,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, im,
        {asp, 0, levels, 0, 1}};
    vkCmdPipelineBarrier(cb, ss, ds2, 0, 0, NULL, 0, NULL, 1, &imb);
}

/* frame prologue shared by every scene: alloc cb, transition the
   color image, begin the render pass, set viewport+scissor */
static void frame_begin(vkdev *d, obj_t *o, const VkClearValue *clrs,
                        int nclr)
{
    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, d->cpool,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    chk(vkAllocateCommandBuffers(d->dev, &cbai, &o->cb), "cmdbuf");
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    chk(vkBeginCommandBuffer(o->cb, &bbi), "begin cb");
    barrier_img(o->cb, o->cimg, VK_IMAGE_ASPECT_COLOR_BIT, 1,
                VK_IMAGE_LAYOUT_UNDEFINED,
                VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, 0,
                VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT);
    if (o->dimg)
        barrier_img(o->cb, o->dimg, VK_IMAGE_ASPECT_DEPTH_BIT, 1,
                    VK_IMAGE_LAYOUT_UNDEFINED,
                    VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL, 0,
                    VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                    VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT);
    VkRenderPassBeginInfo rpb = {VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        NULL, o->rp, o->fb, {{0, 0}, {W, H}}, nclr, clrs};
    vkCmdBeginRenderPass(o->cb, &rpb, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(o->cb, VK_PIPELINE_BIND_POINT_GRAPHICS, o->pipe);
    VkViewport vp = {0.0f, 0.0f, (float)W, (float)H, 0.0f, 1.0f};
    vkCmdSetViewport(o->cb, 0, 1, &vp);
    VkRect2D sc = {{0, 0}, {W, H}};
    vkCmdSetScissor(o->cb, 0, 1, &sc);
}

/* end cb, submit, wait — standalone (upload submissions) */
static void submit_cb(vkdev *d, VkCommandBuffer cb)
{
    chk(vkEndCommandBuffer(cb), "end cb");
    VkFence f;
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                             NULL, 0};
    chk(vkCreateFence(d->dev, &fci, NULL, &f), "fence");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                       0, NULL, NULL, 1, &cb, 0, NULL};
    chk(vkQueueSubmit(d->q, 1, &si, f), "submit");
    chk(vkWaitForFences(d->dev, 1, &f, VK_TRUE, UINT64_MAX),
        "fence wait");
    vkDestroyFence(d->dev, f, NULL);
    /* the device keeps only CbBufs(16) command-buffer slots — hand the
       slot back once the submission completes (same W3.5 residency
       bound as the 8 shader-module slots below) */
    vkFreeCommandBuffers(d->dev, d->cpool, 1, &cb);
}

/* submit + readback into out (NPX*4 bytes) */
static void frame_end(vkdev *d, obj_t *o, uint8_t *out)
{
    vkCmdEndRenderPass(o->cb);
    VkBufferImageCopy bic = {0, 0, 0,
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {W, H, 1}};
    vkCmdCopyImageToBuffer(o->cb, o->cimg,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           o->rb, 1, &bic);
    VkMemoryBarrier mb = {VK_STRUCTURE_TYPE_MEMORY_BARRIER, NULL,
        VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(o->cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0,
                         1, &mb, 0, NULL, 0, NULL);
    chk(vkEndCommandBuffer(o->cb), "end cb");
    VkFence f;
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                             NULL, 0};
    chk(vkCreateFence(d->dev, &fci, NULL, &f), "fence");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                       0, NULL, NULL, 1, &o->cb, 0, NULL};
    chk(vkQueueSubmit(d->q, 1, &si, f), "submit");
    chk(vkWaitForFences(d->dev, 1, &f, VK_TRUE, UINT64_MAX),
        "fence wait");
    void *p;
    chk(vkMapMemory(d->dev, o->rbm, 0, NPX * 4, 0, &p), "rb map");
    memcpy(out, p, NPX * 4);
    vkUnmapMemory(d->dev, o->rbm);
    vkDestroyFence(d->dev, f, NULL);
    vkFreeCommandBuffers(d->dev, d->cpool, 1, &o->cb);
}

static void mk_rp_fb(vkdev *d, obj_t *o, VkFormat cfmt, int depth)
{
    o->rp = mkrp(d, cfmt, depth);
    VkImageView atts[2] = {o->cview, o->dview};
    VkFramebufferCreateInfo fbci = {
        VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, NULL, 0, o->rp,
        depth ? 2 : 1, atts, W, H, 1};
    chk(vkCreateFramebuffer(d->dev, &fbci, NULL, &o->fb), "framebuffer");
}

static void mk_pl(vkdev *d, obj_t *o, VkDescriptorSetLayout dsl)
{
    VkPipelineLayoutCreateInfo plci = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0,
        dsl ? 1 : 0, dsl ? &dsl : NULL, 0, NULL};
    chk(vkCreatePipelineLayout(d->dev, &plci, NULL, &o->pl), "playout");
}

/* ---------------- scenes ---------------------------------------- */

/* scene 1+7: the vktri scene (UNORM and SRGB attachments) */
static void scene_gradient(vkdev *d, const spv_t *spv, uint8_t *out,
                           VkFormat cfmt)
{
    /* spec-CCW: negative framebuffer shoelace */
    static const float verts[3][6] = {
        {-0.5f, -0.5f, 1.0f, 0.0f, 0.0f, 1.0f},
        { 0.0f,  0.5f, 0.0f, 0.0f, 1.0f, 1.0f},
        { 0.5f, -0.5f, 0.0f, 1.0f, 0.0f, 1.0f}};
    obj_t o = {0};
    mkimg(d, cfmt, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, cfmt, VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mk_rp_fb(d, &o, cfmt, 0);
    mk_pl(d, &o, VK_NULL_HANDLE);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VPAS]);  g.fs = mksm(d, &spv[S_FCOL]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 24, VK_VERTEX_INPUT_RATE_VERTEX};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 8};
    g.nbind = 1;  g.natt = 2;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, verts, sizeof(verts));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clr = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    frame_begin(d, &o, &clr, 1);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(o.cb, 0, 1, &o.vb, &off);
    vkCmdDraw(o.cb, 3, 1, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* scene 2: two overlapping triangles + D32 depth, LESS, near second */
static void scene_depth(vkdev *d, const spv_t *spv, uint8_t *out)
{
    /* pos.xyz + col rgba, stride 28 */
    static const float verts[6][7] = {
        /* far triangle z=0.8 green, drawn first (spec-CCW) */
        {-0.9f, -0.9f, 0.8f, 0.0f, 0.8f, 0.0f, 1.0f},
        { 0.0f,  0.9f, 0.8f, 0.0f, 0.8f, 0.0f, 1.0f},
        { 0.9f, -0.9f, 0.8f, 0.0f, 0.8f, 0.0f, 1.0f},
        /* near triangle z=0.25 red, drawn second (spec-CCW) */
        {-0.4f, -0.4f, 0.25f, 0.9f, 0.1f, 0.1f, 1.0f},
        { 0.1f,  0.5f, 0.25f, 0.9f, 0.1f, 0.1f, 1.0f},
        { 0.5f, -0.4f, 0.25f, 0.9f, 0.1f, 0.1f, 1.0f}};
    obj_t o = {0};
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, VK_FORMAT_R8G8B8A8_UNORM,
                     VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mkimg(d, VK_FORMAT_D32_SFLOAT, W, H, 1,
          VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
          &o.dimg, &o.dmem);
    o.dview = mkview(d, o.dimg, VK_FORMAT_D32_SFLOAT,
                     VK_IMAGE_ASPECT_DEPTH_BIT, 1);
    mk_rp_fb(d, &o, VK_FORMAT_R8G8B8A8_UNORM, 1);
    mk_pl(d, &o, VK_NULL_HANDLE);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VPOS3]);  g.fs = mksm(d, &spv[S_FVCOL]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 28, VK_VERTEX_INPUT_RATE_VERTEX};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 12};
    g.nbind = 1;  g.natt = 2;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.depth = 1;  g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, verts, sizeof(verts));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clrs[2] = {
        {{{0.05f, 0.05f, 0.15f, 1.0f}}},
        {{{0}}}};
    clrs[1].depthStencil.depth = 1.0f;
    clrs[1].depthStencil.stencil = 0;
    frame_begin(d, &o, clrs, 2);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(o.cb, 0, 1, &o.vb, &off);
    vkCmdDraw(o.cb, 6, 1, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* scene 3: three SRC_ALPHA-blended quads over a clear colour */
static void scene_blend(vkdev *d, const spv_t *spv, uint8_t *out)
{
    /* 3 overlapping quads, 2 tris each; alpha 0.25/0.5/0.75 */
    static const float rects[3][8] = {
        {-0.9f, -0.5f, -0.2f, -0.5f, -0.2f, 0.6f, -0.9f, 0.6f},
        {-0.45f, -0.3f, 0.35f, -0.3f, 0.35f, 0.7f, -0.45f, 0.7f},
        { 0.05f, -0.6f, 0.85f, -0.6f, 0.85f, 0.4f,  0.05f, 0.4f}};
    static const float cols[3][3] = {
        {0.9f, 0.15f, 0.15f}, {0.15f, 0.9f, 0.15f}, {0.15f, 0.15f, 0.9f}};
    static const float as_[3] = {0.25f, 0.5f, 0.75f};
    float verts[18][6];
    int n = 0;
    for (int q = 0; q < 3; q++) {
        const float *r = rects[q], *c = cols[q];
        float a = as_[q];
        int order[6] = {0, 2, 1, 0, 3, 2};   /* spec-CCW */
        for (int t = 0; t < 6; t++) {
            verts[n][0] = r[order[t] * 2];
            verts[n][1] = r[order[t] * 2 + 1];
            verts[n][2] = c[0];  verts[n][3] = c[1];
            verts[n][4] = c[2];  verts[n][5] = a;
            n++;
        }
    }
    obj_t o = {0};
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, VK_FORMAT_R8G8B8A8_UNORM,
                     VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mk_rp_fb(d, &o, VK_FORMAT_R8G8B8A8_UNORM, 0);
    mk_pl(d, &o, VK_NULL_HANDLE);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VPC]);  g.fs = mksm(d, &spv[S_FVCOL]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 24, VK_VERTEX_INPUT_RATE_VERTEX};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 8};
    g.nbind = 1;  g.natt = 2;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.blend = 1;  g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, verts, sizeof(verts));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clr = {{{0.05f, 0.05f, 0.10f, 1.0f}}};
    frame_begin(d, &o, &clr, 1);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(o.cb, 0, 1, &o.vb, &off);
    vkCmdDraw(o.cb, 18, 1, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* scene 4: UINT16 indexed quad x4 instances, instance-rate colour */
static void scene_indexed(vkdev *d, const spv_t *spv, uint8_t *out)
{
    static const float quad[4][2] = {
        {-0.15f, -0.5f}, {0.15f, -0.5f},
        { 0.15f,  0.5f}, {-0.15f, 0.5f}};
    static const uint16_t idx[6] = {2, 1, 0, 3, 2, 0};   /* spec-CCW */
    static const float icol[4][4] = {
        {0.9f, 0.1f, 0.1f, 1.0f}, {0.1f, 0.9f, 0.1f, 1.0f},
        {0.1f, 0.1f, 0.9f, 1.0f}, {0.9f, 0.9f, 0.1f, 1.0f}};
    obj_t o = {0};
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, VK_FORMAT_R8G8B8A8_UNORM,
                     VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mk_rp_fb(d, &o, VK_FORMAT_R8G8B8A8_UNORM, 0);
    mk_pl(d, &o, VK_NULL_HANDLE);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VINST]);  g.fs = mksm(d, &spv[S_FVCOL]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 8, VK_VERTEX_INPUT_RATE_VERTEX};
    g.binds[1] = (VkVertexInputBindingDescription){
        1, 16, VK_VERTEX_INPUT_RATE_INSTANCE};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 1, VK_FORMAT_R32G32B32A32_SFLOAT, 0};
    g.nbind = 2;  g.natt = 2;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(quad), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, quad, sizeof(quad));
    mkbuf(d, sizeof(icol), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb2, &o.vb2m);
    upload(d, o.vb2m, icol, sizeof(icol));
    mkbuf(d, sizeof(idx), VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
          &o.ib, &o.ibm);
    upload(d, o.ibm, idx, sizeof(idx));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clr = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    frame_begin(d, &o, &clr, 1);
    VkBuffer vbs[2] = {o.vb, o.vb2};
    VkDeviceSize offs[2] = {0, 0};
    vkCmdBindVertexBuffers(o.cb, 0, 2, vbs, offs);
    vkCmdBindIndexBuffer(o.cb, o.ib, 0, VK_INDEX_TYPE_UINT16);
    vkCmdDrawIndexed(o.cb, 6, 4, 0, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* scene 5: 4-mip 8x8 texture, implicit LOD ramps mips 0->3 across x */
static void scene_tex(vkdev *d, const spv_t *spv, uint8_t *out)
{
    /* fullscreen quad; uv.y=0.5 constant (fs uses FragCoord for u) */
    static const float verts[6][4] = {
        {-1.0f, -1.0f, 0.0f, 0.5f}, { 1.0f,  1.0f, 0.0f, 0.5f},
        { 1.0f, -1.0f, 0.0f, 0.5f},
        {-1.0f, -1.0f, 0.0f, 0.5f}, {-1.0f,  1.0f, 0.0f, 0.5f},
        { 1.0f,  1.0f, 0.0f, 0.5f}};
    /* 4 mips, flat colours: red, green, blue, white */
    static const uint8_t mipcol[4][4] = {
        {255, 0, 0, 255}, {0, 255, 0, 255},
        {0, 0, 255, 255}, {255, 255, 255, 255}};
    uint8_t texdata[8 * 8 * 4 + 4 * 4 * 4 + 2 * 2 * 4 + 1 * 4];
    memset(texdata, 0, sizeof(texdata));
    for (int m = 0, off = 0; m < 4; m++) {
        int dim = 8 >> m;
        for (int i = 0; i < dim * dim; i++)
            memcpy(texdata + off + i * 4, mipcol[m], 4);
        off += dim * dim * 4;
    }
    obj_t o = {0};
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, VK_FORMAT_R8G8B8A8_UNORM,
                     VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, 8, 8, 4,
          VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
          &o.tex, &o.texm);
    o.tv = mkview(d, o.tex, VK_FORMAT_R8G8B8A8_UNORM,
                  VK_IMAGE_ASPECT_COLOR_BIT, 4);
    VkSamplerCreateInfo sci = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        NULL, 0, VK_FILTER_NEAREST, VK_FILTER_NEAREST,
        VK_SAMPLER_MIPMAP_MODE_NEAREST,
        VK_SAMPLER_ADDRESS_MODE_REPEAT, VK_SAMPLER_ADDRESS_MODE_REPEAT,
        VK_SAMPLER_ADDRESS_MODE_REPEAT,
        0.0f, VK_FALSE, 1.0f, VK_FALSE, VK_COMPARE_OP_NEVER,
        0.0f, 3.0f, VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK, VK_FALSE};
    chk(vkCreateSampler(d->dev, &sci, NULL, &o.samp), "sampler");
    VkDescriptorSetLayoutBinding lb = {
        0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1,
        VK_SHADER_STAGE_FRAGMENT_BIT, NULL};
    VkDescriptorSetLayoutCreateInfo dlci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0,
        1, &lb};
    chk(vkCreateDescriptorSetLayout(d->dev, &dlci, NULL, &o.dsl),
        "dslayout");
    VkDescriptorPoolSize psz = {
        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1};
    VkDescriptorPoolCreateInfo pci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1,
        1, &psz};
    chk(vkCreateDescriptorPool(d->dev, &pci, NULL, &o.pool), "dpool");
    VkDescriptorSetAllocateInfo dsai = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, o.pool,
        1, &o.dsl};
    chk(vkAllocateDescriptorSets(d->dev, &dsai, &o.dset), "dset alloc");
    VkDescriptorImageInfo dii = {
        o.samp, o.tv, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
    VkWriteDescriptorSet wr = {
        VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, o.dset, 0, 0, 1,
        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &dii, NULL, NULL};
    vkUpdateDescriptorSets(d->dev, 1, &wr, 0, NULL);
    mk_rp_fb(d, &o, VK_FORMAT_R8G8B8A8_UNORM, 0);
    mk_pl(d, &o, o.dsl);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VTEX]);  g.fs = mksm(d, &spv[S_FMIP]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 16, VK_VERTEX_INPUT_RATE_VERTEX};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 0, VK_FORMAT_R32G32_SFLOAT, 8};
    g.nbind = 1;  g.natt = 2;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, verts, sizeof(verts));
    mkbuf(d, sizeof(texdata), VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
          &o.stage, &o.stagem);
    upload(d, o.stagem, texdata, sizeof(texdata));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clr = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    /* texture upload in its own submission so a stall localizes */
    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, d->cpool,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    chk(vkAllocateCommandBuffers(d->dev, &cbai, &o.cb), "cmdbuf");
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    chk(vkBeginCommandBuffer(o.cb, &bbi), "begin cb");
    barrier_img(o.cb, o.tex, VK_IMAGE_ASPECT_COLOR_BIT, 4,
                VK_IMAGE_LAYOUT_UNDEFINED,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0,
                VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy regs[4];
    for (int m = 0, off = 0; m < 4; m++) {
        int dim = 8 >> m;
        regs[m] = (VkBufferImageCopy){(VkDeviceSize)off, 0, 0,
            {VK_IMAGE_ASPECT_COLOR_BIT, (uint32_t)m, 0, 1},
            {0, 0, 0}, {(uint32_t)dim, (uint32_t)dim, 1}};
        off += dim * dim * 4;
    }
    vkCmdCopyBufferToImage(o.cb, o.stage, o.tex,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                           4, regs);
    barrier_img(o.cb, o.tex, VK_IMAGE_ASPECT_COLOR_BIT, 4,
                VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                VK_ACCESS_TRANSFER_WRITE_BIT,
                VK_ACCESS_SHADER_READ_BIT,
                VK_PIPELINE_STAGE_TRANSFER_BIT,
                VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    printf("s4: tex upload submit\n"); fflush(stdout);
    submit_cb(d, o.cb);
    printf("s4: tex upload done; render\n"); fflush(stdout);
    frame_begin(d, &o, &clr, 1);
    vkCmdBindDescriptorSets(o.cb, VK_PIPELINE_BIND_POINT_GRAPHICS,
                          o.pl, 0, 1, &o.dset, 0, NULL);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(o.cb, 0, 1, &o.vb, &off);
    vkCmdDraw(o.cb, 6, 1, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* scene 6: one vertex behind the camera (w<0), gradient colour */
static void scene_clip(vkdev *d, const spv_t *spv, uint8_t *out)
{
    /* vs_clip: gl_Position = (x, y, 0.5z+0.5, -z) — v2 lands w<0 */
    static const float verts[3][7] = {
        {-0.7f, -0.7f, -0.8f, 1.0f, 0.0f, 0.0f, 1.0f},
        { 0.0f,  0.8f,  0.3f, 0.0f, 0.0f, 1.0f, 1.0f},
        { 0.7f, -0.7f, -0.8f, 0.0f, 1.0f, 0.0f, 1.0f}};
    obj_t o = {0};
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, VK_FORMAT_R8G8B8A8_UNORM,
                     VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mk_rp_fb(d, &o, VK_FORMAT_R8G8B8A8_UNORM, 0);
    mk_pl(d, &o, VK_NULL_HANDLE);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VCLIP]);  g.fs = mksm(d, &spv[S_FVCOL]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 28, VK_VERTEX_INPUT_RATE_VERTEX};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32B32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 0, VK_FORMAT_R32G32B32A32_SFLOAT, 12};
    g.nbind = 1;  g.natt = 2;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(verts), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, verts, sizeof(verts));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clr = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    frame_begin(d, &o, &clr, 1);
    VkDeviceSize off = 0;
    vkCmdBindVertexBuffers(o.cb, 0, 1, &o.vb, &off);
    vkCmdDraw(o.cb, 3, 1, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* scene 8: derivatives — fwidth(uv)*8 | dFdx(c.r)*4+0.5 */
static void scene_derivs(vkdev *d, const spv_t *spv, uint8_t *out)
{
    /* fullscreen quad: uv ramps 0..1 across x, c.r = uv.x */
    static const float pos[6][2] = {
        {-1.0f, -1.0f}, { 1.0f,  1.0f}, { 1.0f, -1.0f},
        {-1.0f, -1.0f}, {-1.0f,  1.0f}, { 1.0f,  1.0f}};
    static const float uv[6][2] = {
        {0.0f, 0.0f}, {1.0f, 1.0f}, {1.0f, 0.0f},
        {0.0f, 0.0f}, {0.0f, 1.0f}, {1.0f, 1.0f}};
    static const float cc[6][4] = {
        {0, 0, 0, 1}, {1, 0, 0, 1}, {1, 0, 0, 1},
        {0, 0, 0, 1}, {0, 0, 0, 1}, {1, 0, 0, 1}};
    obj_t o = {0};
    mkimg(d, VK_FORMAT_R8G8B8A8_UNORM, W, H, 1,
          VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
          VK_IMAGE_USAGE_TRANSFER_SRC_BIT, &o.cimg, &o.cmem);
    o.cview = mkview(d, o.cimg, VK_FORMAT_R8G8B8A8_UNORM,
                     VK_IMAGE_ASPECT_COLOR_BIT, 1);
    mk_rp_fb(d, &o, VK_FORMAT_R8G8B8A8_UNORM, 0);
    mk_pl(d, &o, VK_NULL_HANDLE);
    gp_t g = {0};
    g.vs = mksm(d, &spv[S_VUVC]);  g.fs = mksm(d, &spv[S_FDERIV]);
    g.binds[0] = (VkVertexInputBindingDescription){
        0, 8, VK_VERTEX_INPUT_RATE_VERTEX};
    g.binds[1] = (VkVertexInputBindingDescription){
        1, 8, VK_VERTEX_INPUT_RATE_VERTEX};
    g.binds[2] = (VkVertexInputBindingDescription){
        2, 16, VK_VERTEX_INPUT_RATE_VERTEX};
    g.atts[0] = (VkVertexInputAttributeDescription){
        0, 0, VK_FORMAT_R32G32_SFLOAT, 0};
    g.atts[1] = (VkVertexInputAttributeDescription){
        1, 1, VK_FORMAT_R32G32_SFLOAT, 0};
    g.atts[2] = (VkVertexInputAttributeDescription){
        2, 2, VK_FORMAT_R32G32B32A32_SFLOAT, 0};
    g.nbind = 3;  g.natt = 3;
    g.topo = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    g.wmask = 0xF;  g.layout = o.pl;  g.rp = o.rp;
    o.pipe = mkgp(d, &g);
    mkbuf(d, sizeof(pos), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb, &o.vbm);
    upload(d, o.vbm, pos, sizeof(pos));
    mkbuf(d, sizeof(uv), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.vb2, &o.vb2m);
    upload(d, o.vb2m, uv, sizeof(uv));
    mkbuf(d, sizeof(cc), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
          &o.stage, &o.stagem);
    upload(d, o.stagem, cc, sizeof(cc));
    mkbuf(d, NPX * 4, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &o.rb, &o.rbm);
    VkClearValue clr = {{{0.0f, 0.0f, 0.0f, 1.0f}}};
    frame_begin(d, &o, &clr, 1);
    VkBuffer vbs[3] = {o.vb, o.vb2, o.stage};
    VkDeviceSize offs[3] = {0, 0, 0};
    vkCmdBindVertexBuffers(o.cb, 0, 3, vbs, offs);
    vkCmdDraw(o.cb, 6, 1, 0, 0);
    frame_end(d, &o, out);
    /* the device keeps only 8 shader-module slots — release the
       pipeline's refs and the module objects per scene (Venus
       forwards these in-order on the primary ring) */
    vkDestroyPipeline(d->dev, o.pipe, NULL);
    vkDestroyShaderModule(d->dev, g.vs, NULL);
    vkDestroyShaderModule(d->dev, g.fs, NULL);
}

/* ---------------- compare + report ------------------------------- */

static int compare(const uint8_t *a, const uint8_t *b, int tol,
                   int *maxd, uint16_t map[16])
{
    int bad = 0;
    memset(map, 0, sizeof(uint16_t) * 16);
    *maxd = 0;
    for (int y = 0; y < H; y++)
        for (int x = 0; x < W; x++) {
            int pxbad = 0;
            for (int c = 0; c < 4; c++) {
                int av = a[(y * W + x) * 4 + c];
                int bv = b[(y * W + x) * 4 + c];
                int dv = abs(av - bv);
                if (dv > *maxd) *maxd = dv;
                if (dv > tol) {
                    if (bad < 8)
                        printf("  mismatch px(%d,%d) ch%d venus=%u "
                               "llvmpipe=%u\n", x, y, c, av, bv);
                    pxbad = 1;
                }
            }
            if (pxbad) {
                bad++;
                map[y / 4] |= 1u << (15 - x / 4);
            }
        }
    return bad;
}

int main(int argc, char **argv)
{
    spv_t spv[S_N];
    for (int i = 0; i < S_N; i++)
        spv[i] = spv_load(argc > i + 1 ? argv[i + 1] : spv_dflt[i]);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkcmp", 0, "vkcmp", 0, VK_API_VERSION_1_1};
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

    vkdev venus = {0}, lava = {0};
    int have_v = 0, have_l = 0;
    for (uint32_t i = 0; i < npdev; i++) {
        VkPhysicalDeviceDriverProperties dp = {
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
        VkPhysicalDeviceProperties2 p2 = {
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, &dp};
        vkGetPhysicalDeviceProperties2(pdevs[i], &p2);
        printf("pd%u: deviceName=%s driverName=%s\n", i,
               p2.properties.deviceName, dp.driverName);
        if (!have_l &&
            strstr(p2.properties.deviceName, "llvmpipe")) {
            lava.pd = pdevs[i];  have_l = 1;
            snprintf(lava.name, sizeof(lava.name), "%s",
                     p2.properties.deviceName);
        } else if (!have_v &&
                   (strstr(dp.driverName, "venus") ||
                    strstr(p2.properties.deviceName, "Venus") ||
                    strstr(p2.properties.deviceName, "LibreCore"))) {
            venus.pd = pdevs[i];  have_v = 1;
            snprintf(venus.name, sizeof(venus.name), "%s",
                     p2.properties.deviceName);
        }
    }
    if (!have_v && !getenv("VKCMP_NO_VENUS")) {
        printf("FAIL: no Venus physical device\n"); return 1;
    }
    if (!have_l) { printf("FAIL: no llvmpipe physical device\n"); return 1; }
    int vstandin = 0;
    if (!have_v) {
        venus.pd = lava.pd;
        snprintf(venus.name, sizeof(venus.name), "%s", lava.name);
        have_v = 1;
        vstandin = 1;
    }
    printf("venus pd: %s%s\nllvmpipe pd: %s\n",
           venus.name, vstandin ? " (llvmpipe stand-in)" : "",
           lava.name);

    vkdev *ds[2] = {&venus, &lava};
    for (int k = 0; k < 2; k++) {
        vkdev *d = ds[k];
        vkGetPhysicalDeviceMemoryProperties(d->pd, &d->mp);
        d->mt_host = UINT32_MAX;
        for (uint32_t t = 0; t < d->mp.memoryTypeCount; t++) {
            VkFlags fl = d->mp.memoryTypes[t].propertyFlags;
            if ((fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
                (fl & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) &&
                d->mt_host == UINT32_MAX)
                d->mt_host = t;
        }
        if (d->mt_host == UINT32_MAX) {
            printf("FAIL: %s has no host-visible coherent type\n",
                   d->name);
            return 1;
        }
        float prio = 1.0f;
        VkDeviceQueueCreateInfo qci = {
            VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1,
            &prio};
        VkPhysicalDeviceFeatures en = {0};
        VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            NULL, 0, 1, &qci, 0, NULL, 0, NULL, &en};
        chk(vkCreateDevice(d->pd, &dci, NULL, &d->dev), "vkCreateDevice");
        vkGetDeviceQueue(d->dev, 0, 0, &d->q);
        VkCommandPoolCreateInfo cpci = {
            VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, 0};
        chk(vkCreateCommandPool(d->dev, &cpci, NULL, &d->cpool),
            "cmdpool");
    }

    /* name, tolerance (LSB), budget (fraction of NPX) */
    struct { const char *name; int tol; float budget; } sc[8] = {
        {"tri_gradient",       2, 0.005f},
        {"depth_less",         2, 0.005f},
        {"blend_layers",       2, 0.010f},
        {"indexed_instanced",  2, 0.005f},
        {"tex_mip_nearest",    2, 0.030f},
        {"clip_near",          3, 0.020f},
        {"srgb_gradient",      2, 0.005f},
        {"derivs",             2, 0.010f},
    };
    static uint8_t va[NPX * 4], la[NPX * 4];
    const char *only = getenv("VKCMP_ONLY");
    int npass = 0, nrun = 0;
    for (int k = 0; k < 8; k++) {
        if (only && atoi(only) != k) continue;
        nrun++;
        double t0 = wall();
        printf("SCENE %d %s venus...\n", k, sc[k].name);
        fflush(stdout);
        switch (k) {
        case 0: scene_gradient(&venus, spv, va,
                               VK_FORMAT_R8G8B8A8_UNORM); break;
        case 1: scene_depth(&venus, spv, va); break;
        case 2: scene_blend(&venus, spv, va); break;
        case 3: scene_indexed(&venus, spv, va); break;
        case 4: scene_tex(&venus, spv, va); break;
        case 5: scene_clip(&venus, spv, va); break;
        case 6: scene_gradient(&venus, spv, va,
                               VK_FORMAT_B8G8R8A8_SRGB); break;
        case 7: scene_derivs(&venus, spv, va); break;
        }
        double t1 = wall();
        printf("SCENE %d llvmpipe...\n", k);
        fflush(stdout);
        switch (k) {
        case 0: scene_gradient(&lava, spv, la,
                               VK_FORMAT_R8G8B8A8_UNORM); break;
        case 1: scene_depth(&lava, spv, la); break;
        case 2: scene_blend(&lava, spv, la); break;
        case 3: scene_indexed(&lava, spv, la); break;
        case 4: scene_tex(&lava, spv, la); break;
        case 5: scene_clip(&lava, spv, la); break;
        case 6: scene_gradient(&lava, spv, la,
                               VK_FORMAT_B8G8R8A8_SRGB); break;
        case 7: scene_derivs(&lava, spv, la); break;
        }
        double t2 = wall();
        if (getenv("VKCMP_DUMP")) {
            char fn[64];
            snprintf(fn, sizeof(fn), "vkcmp_s%d_venus.bin", k);
            FILE *f = fopen(fn, "wb");
            if (f) { fwrite(va, 1, sizeof(va), f); fclose(f); }
            snprintf(fn, sizeof(fn), "vkcmp_s%d_llvmpipe.bin", k);
            f = fopen(fn, "wb");
            if (f) { fwrite(la, 1, sizeof(la), f); fclose(f); }
        }
        int maxd = 0;
        uint16_t map[16];
        int bad = compare(va, la, sc[k].tol, &maxd, map);
        double pct = 100.0 * bad / NPX;
        int pass = bad <= (int)(NPX * sc[k].budget);
        printf("SCENE %d %s venus=%.1fs llvmpipe=%.1fs maxdiff=%d "
               "bad=%d/4096 (%.2f%%) -> %s\n", k, sc[k].name,
               t1 - t0, t2 - t1, maxd, bad, pct,
               pass ? "PASS" : "FAIL");
        if (bad) {
            printf("  mismatch map (16x16, # = cell with >tol diff):\n");
            for (int gy = 0; gy < 16; gy++) {
                printf("  ");
                for (int gx = 0; gx < 16; gx++)
                    putchar((map[gy] >> (15 - gx)) & 1 ? '#' : '.');
                putchar('\n');
            }
        }
        npass += pass;
    }
    if (npass != nrun) {
        printf("FAIL: vkcmp %d/%d scenes within budget\n", npass, nrun);
        return 1;
    }
    printf("G6LC_VKCMP_PASS scenes=%d\n", npass);
    return 0;
}
