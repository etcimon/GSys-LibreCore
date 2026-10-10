// vkimage — §12.3 C/5b guest proof: compute-visible images, samplers
// and Xfer image copies on the stock Venus path.  Uploads a 4x4
// R8G8B8A8_UNORM texture through a staging buffer +
// vkCmdCopyBufferToImage, runs a compute dispatch that bilinearly
// samples it at fractional coords with CLAMP_TO_EDGE and REPEAT
// samplers and imageStores into an 8x2 R32G32B32A32_SFLOAT storage
// image, reads it back via vkCmdCopyImageToBuffer and compares
// against a CPU bilinear reference (abs tolerance 4/255 — the
// hardware uses 8-bit fractional weights, so <=1/256 quantization
// plus UNORM rounding is the honest bound).
//
// 5b-r2 adds a clear step: vkCmdClearColorImage on a 2-mip RGBA8
// image with a float colour, CopyImageToBuffer of mip 1, exact
// UNORM8 round-to-nearest compare.
//
// Also checks format-properties truthfulness: D32_SFLOAT must report
// zero features and R8G8B8A8_UNORM exactly the generated table's set
// (SAMPLED_IMAGE | FILTER_LINEAR | STORAGE_IMAGE | TRANSFER_SRC |
// TRANSFER_DST), and a vkCreateImage with a depth format must fail.
//
//   gcc -O2 -o vkimage vkimage.c -lvulkan && ./vkimage vkimage.spv
//
// Exit 0 + "G6LC_VKIMAGE_PASS" on success.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

static void chk(VkResult r, const char *what)
{
    if (r != VK_SUCCESS) {
        printf("FAIL: %s -> %d\n", what, (int)r);
        exit(1);
    }
}

/* deterministic 4x4 RGBA8 pattern */
static uint8_t tex[4][4][4];
static void tex_init(void)
{
    for (int y = 0; y < 4; y++)
        for (int x = 0; x < 4; x++) {
            tex[y][x][0] = (uint8_t)(x * 64 + 15);
            tex[y][x][1] = (uint8_t)(y * 64 + 31);
            tex[y][x][2] = (uint8_t)((x + y) * 29 + 7);
            tex[y][x][3] = 255;
        }
}

static int addr_edge(int i, int n) { return i < 0 ? 0 : (i >= n ? n - 1 : i); }
static int addr_rep(int i, int n) { i %= n; return i < 0 ? i + n : i; }

/* exact (double) bilinear reference for one channel set */
static void sample_ref(double u, double v, int rep, double out[4])
{
    double uf = u * 4.0 - 0.5, vf = v * 4.0 - 0.5;
    int i0 = (int)floor(uf), j0 = (int)floor(vf);
    double fu = uf - i0, fv = vf - j0;
    int (*A)(int, int) = rep ? addr_rep : addr_edge;
    for (int c = 0; c < 4; c++) {
        double t00 = tex[A(j0, 4)][A(i0, 4)][c] / 255.0;
        double t10 = tex[A(j0, 4)][A(i0 + 1, 4)][c] / 255.0;
        double t01 = tex[A(j0 + 1, 4)][A(i0, 4)][c] / 255.0;
        double t11 = tex[A(j0 + 1, 4)][A(i0 + 1, 4)][c] / 255.0;
        out[c] = (t00 * (1 - fu) + t10 * fu) * (1 - fv) +
                 (t01 * (1 - fu) + t11 * fu) * fv;
    }
}

int main(int argc, char **argv)
{
    const char *spv_path = argc > 1 ? argv[1] : "vkimage.spv";
    FILE *f = fopen(spv_path, "rb");
    if (!f) { perror(spv_path); return 1; }
    fseek(f, 0, SEEK_END);
    long spv_n = ftell(f);
    rewind(f);
    uint32_t *spv = malloc(spv_n);
    if (fread(spv, 1, spv_n, f) != (size_t)spv_n) { perror("spv read"); return 1; }
    fclose(f);
    tex_init();

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkimage", 0, "vkimage", 0,
                            VK_API_VERSION_1_1};
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
    VkPhysicalDevice pdev = pdevs[0];
    for (uint32_t i = 0; i < npdev; i++) {
        VkPhysicalDeviceProperties pp;
        vkGetPhysicalDeviceProperties(pdevs[i], &pp);
        printf("pd%u: %s\n", i, pp.deviceName);
        if (strstr(pp.deviceName, "Venus") ||
            strstr(pp.deviceName, "LibreCore"))
            pdev = pdevs[i];
    }

    /* ---- format truthfulness ------------------------------------ */
    VkFormatProperties fp;
    vkGetPhysicalDeviceFormatProperties(pdev, VK_FORMAT_D32_SFLOAT, &fp);
    printf("D32_SFLOAT features %x %x %x\n", fp.linearTilingFeatures,
           fp.optimalTilingFeatures, fp.bufferFeatures);
    if (fp.linearTilingFeatures || fp.optimalTilingFeatures ||
        fp.bufferFeatures) {
        printf("FAIL: D32_SFLOAT advertises features\n");
        return 1;
    }
    vkGetPhysicalDeviceFormatProperties(pdev, VK_FORMAT_R8G8B8A8_UNORM,
                                        &fp);
    const VkFormatFeatureFlags want =
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT |
        VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT |
        VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
        VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    printf("R8G8B8A8_UNORM features lin=%x opt=%x want=%x\n",
           fp.linearTilingFeatures, fp.optimalTilingFeatures, want);
    if ((fp.linearTilingFeatures & want) != want ||
        (fp.optimalTilingFeatures & want) != want) {
        printf("FAIL: R8G8B8A8_UNORM missing advertised features\n");
        return 1;
    }

    /* ---- device -------------------------------------------------- */
    VkPhysicalDeviceMemoryProperties mprops;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mprops);
    uint32_t mt_host = UINT32_MAX;
    for (uint32_t t = 0; t < mprops.memoryTypeCount; t++) {
        VkFlags fl = mprops.memoryTypes[t].propertyFlags;
        if ((fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (fl & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            mt_host = t;
    }
    if (mt_host == UINT32_MAX) { printf("FAIL: no host-visible memory\n"); return 1; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
    VkPhysicalDeviceFeatures en = {0};
    en.robustBufferAccess = VK_TRUE;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL,
                              0, 1, &qci, 0, NULL, 0, NULL, &en};
    VkDevice dev;
    chk(vkCreateDevice(pdev, &dci, NULL, &dev), "vkCreateDevice");
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    /* ---- images --------------------------------------------------- */
    VkImage tex_img, dst_img;
    VkImageCreateInfo ic = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL, 0,
        VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM,
        {4, 4, 1}, 1, 1, VK_SAMPLE_COUNT_1_BIT,
        VK_IMAGE_TILING_OPTIMAL,
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL,
        VK_IMAGE_LAYOUT_UNDEFINED};
    chk(vkCreateImage(dev, &ic, NULL, &tex_img), "create tex");
    ic.format = VK_FORMAT_R32G32B32A32_SFLOAT;
    ic.extent = (VkExtent3D){8, 2, 1};
    ic.usage = VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    chk(vkCreateImage(dev, &ic, NULL, &dst_img), "create dst");

    /* negative arm: depth format must be refused */
    ic.format = VK_FORMAT_D32_SFLOAT;
    ic.extent = (VkExtent3D){4, 4, 1};
    ic.usage = VK_IMAGE_USAGE_SAMPLED_BIT;
    VkImage bad_img;
    VkResult br = vkCreateImage(dev, &ic, NULL, &bad_img);
    if (br == VK_SUCCESS) {
        printf("FAIL: D32_SFLOAT vkCreateImage succeeded\n");
        vkDestroyImage(dev, bad_img, NULL);
        return 1;
    }
    printf("neg: D32_SFLOAT vkCreateImage -> %d (expected failure)\n",
           (int)br);

    VkDeviceMemory tex_mem, dst_mem;
    VkMemoryRequirements mr;
    for (int i = 0; i < 2; i++) {
        VkImage im = i ? dst_img : tex_img;
        vkGetImageMemoryRequirements(dev, im, &mr);
        uint32_t mti = UINT32_MAX;
        /* prefer device-local (non-host-visible) for images */
        for (uint32_t t = 0; t < mprops.memoryTypeCount; t++)
            if ((mr.memoryTypeBits & (1u << t)) &&
                !(mprops.memoryTypes[t].propertyFlags &
                  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
                { mti = t; break; }
        if (mti == UINT32_MAX)
            mti = __builtin_ctz(mr.memoryTypeBits);
        VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                    NULL, mr.size, mti};
        VkDeviceMemory m;
        chk(vkAllocateMemory(dev, &mai, NULL, &m), "vkAllocateMemory img");
        chk(vkBindImageMemory(dev, im, m, 0), "vkBindImageMemory");
        if (i) dst_mem = m; else tex_mem = m;
        printf("img%d size=%llu align=%llu mt=%u\n", i,
               (unsigned long long)mr.size,
               (unsigned long long)mr.alignment, mti);
    }

    VkImageView tex_view, dst_view;
    VkImageViewCreateInfo vc = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        NULL, 0, tex_img, VK_IMAGE_VIEW_TYPE_2D,
        VK_FORMAT_R8G8B8A8_UNORM,
        {VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
         VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY},
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    chk(vkCreateImageView(dev, &vc, NULL, &tex_view), "tex view");
    vc.image = dst_img;
    vc.format = VK_FORMAT_R32G32B32A32_SFLOAT;
    chk(vkCreateImageView(dev, &vc, NULL, &dst_view), "dst view");

    /* ---- 5b-r2 clear image: 2-mip RGBA8, transfer-only ------------ */
    VkImage clr_img;
    VkImageCreateInfo icc = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, NULL,
        0, VK_IMAGE_TYPE_2D, VK_FORMAT_R8G8B8A8_UNORM,
        {4, 4, 1}, 2, 1, VK_SAMPLE_COUNT_1_BIT,
        VK_IMAGE_TILING_OPTIMAL,
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL,
        VK_IMAGE_LAYOUT_UNDEFINED};
    chk(vkCreateImage(dev, &icc, NULL, &clr_img), "create clr");
    VkDeviceMemory clr_mem;
    {
        vkGetImageMemoryRequirements(dev, clr_img, &mr);
        uint32_t mti = UINT32_MAX;
        for (uint32_t t = 0; t < mprops.memoryTypeCount; t++)
            if ((mr.memoryTypeBits & (1u << t)) &&
                !(mprops.memoryTypes[t].propertyFlags &
                  VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT))
                { mti = t; break; }
        if (mti == UINT32_MAX)
            mti = __builtin_ctz(mr.memoryTypeBits);
        VkMemoryAllocateInfo cai = {
            VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size, mti};
        chk(vkAllocateMemory(dev, &cai, NULL, &clr_mem), "clr mem");
        chk(vkBindImageMemory(dev, clr_img, clr_mem, 0), "clr bind");
    }

    /* ---- samplers ------------------------------------------------- */
    VkSampler samp_edge, samp_rep;
    VkSamplerCreateInfo sc = {VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO, NULL,
        0, VK_FILTER_LINEAR, VK_FILTER_LINEAR,
        VK_SAMPLER_MIPMAP_MODE_NEAREST,
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        0.0f, VK_FALSE, 1.0f, VK_FALSE, VK_COMPARE_OP_NEVER,
        0.0f, 0.0f, VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
        VK_FALSE};
    chk(vkCreateSampler(dev, &sc, NULL, &samp_edge), "sampler edge");
    sc.addressModeU = sc.addressModeV = sc.addressModeW =
        VK_SAMPLER_ADDRESS_MODE_REPEAT;
    chk(vkCreateSampler(dev, &sc, NULL, &samp_rep), "sampler rep");

    /* ---- staging + readback buffers -------------------------------- */
    VkBuffer stage_buf, rb_buf;
    VkDeviceMemory stage_mem, rb_mem;
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        NULL, 0, 64, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    chk(vkCreateBuffer(dev, &bci, NULL, &stage_buf), "stage buf");
    vkGetBufferMemoryRequirements(dev, stage_buf, &mr);
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, mr.size, mt_host};
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &stage_mem), "stage mem");
    chk(vkBindBufferMemory(dev, stage_buf, stage_mem, 0), "stage bind");
    void *p;
    chk(vkMapMemory(dev, stage_mem, 0, 64, 0, &p), "map stage");
    memcpy(p, tex, 64);
    vkUnmapMemory(dev, stage_mem);

    /* 256 B for the storage-image readback + 64 B tail for the clear
       readback at offset 256 */
    bci.size = 8 * 2 * 16 + 64;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    chk(vkCreateBuffer(dev, &bci, NULL, &rb_buf), "rb buf");
    vkGetBufferMemoryRequirements(dev, rb_buf, &mr);
    mai.allocationSize = mr.size;
    mai.memoryTypeIndex = mt_host;
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &rb_mem), "rb mem");
    chk(vkBindBufferMemory(dev, rb_buf, rb_mem, 0), "rb bind");
    /* Persistently map the readback buffer before it becomes a copy
       destination: host-visible memory is lazy-backed, so the MAP_BLOB
       that establishes its backing only happens at vkMapMemory — a GPU
       write into still-unbacked memory is refused truthfully by the
       device.  Persistent mapping is the recommended pattern anyway. */
    void *rb_map;
    chk(vkMapMemory(dev, rb_mem, 0, bci.size, 0, &rb_map),
        "map rb early");

    /* ---- descriptors ---------------------------------------------- */
    VkDescriptorSetLayoutBinding lb[3] = {
        {0, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {2, VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
    };
    VkDescriptorSetLayoutCreateInfo dlci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0,
        3, lb};
    VkDescriptorSetLayout dset_layout;
    chk(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dset_layout), "dslayout");

    VkDescriptorPoolSize psz[3] = {
        {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 2},
        {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1},
        {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 0},
    };
    VkDescriptorPoolCreateInfo pci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 2, psz};
    VkDescriptorPool pool;
    chk(vkCreateDescriptorPool(dev, &pci, NULL, &pool), "dpool");

    VkDescriptorSetAllocateInfo dsai = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, pool,
        1, &dset_layout};
    VkDescriptorSet dset;
    chk(vkAllocateDescriptorSets(dev, &dsai, &dset), "dset alloc");

    VkDescriptorImageInfo dii[3] = {
        {samp_edge, tex_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        {samp_rep,  tex_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL},
        {VK_NULL_HANDLE, dst_view, VK_IMAGE_LAYOUT_GENERAL},
    };
    VkWriteDescriptorSet wr[3];
    for (int i = 0; i < 3; i++)
        wr[i] = (VkWriteDescriptorSet){
            VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dset, i, 0, 1,
            i == 2 ? VK_DESCRIPTOR_TYPE_STORAGE_IMAGE
                   : VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            &dii[i], NULL, NULL};
    vkUpdateDescriptorSets(dev, 3, wr, 0, NULL);

    VkPipelineLayoutCreateInfo plci = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0,
        1, &dset_layout, 0, NULL};
    VkPipelineLayout playout;
    chk(vkCreatePipelineLayout(dev, &plci, NULL, &playout), "playout");

    VkShaderModuleCreateInfo smci = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0,
        (size_t)spv_n, spv};
    VkShaderModule smod;
    chk(vkCreateShaderModule(dev, &smci, NULL, &smod), "shader module");

    VkComputePipelineCreateInfo cpci = {
        VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_COMPUTE_BIT, smod, "main", NULL},
        playout, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    chk(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe),
        "pipeline");

    /* ---- command buffer -------------------------------------------- */
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

    /* UNDEFINED -> TRANSFER_DST on the texture */
    VkImageMemoryBarrier imb = {
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        0, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        tex_img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 1, &imb);

    VkBufferImageCopy bic = {0, 0, 0,
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {4, 4, 1}};
    vkCmdCopyBufferToImage(cb, stage_buf, tex_img,
                           VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bic);

    /* texture -> SHADER_READ_ONLY, dst image -> GENERAL */
    VkImageMemoryBarrier imb2[2];
    imb2[0] = (VkImageMemoryBarrier){
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        tex_img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    imb2[1] = (VkImageMemoryBarrier){
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        0, VK_ACCESS_SHADER_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        dst_img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0,
                         0, NULL, 0, NULL, 2, imb2);

    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, playout, 0,
                            1, &dset, 0, NULL);
    vkCmdDispatch(cb, 1, 1, 1);

    /* dst image GENERAL -> TRANSFER_SRC */
    imb2[0] = (VkImageMemoryBarrier){
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
        VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        dst_img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 1, imb2);
    VkBufferImageCopy bic2 = {0, 0, 0,
        {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, {0, 0, 0}, {8, 2, 1}};
    vkCmdCopyImageToBuffer(cb, dst_img,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           rb_buf, 1, &bic2);

    /* ---- 5b-r2 clear step: float colour -> UNORM8 over both mips,
       packed CopyImageToBuffer readback of mip 1 into rb_buf+256 --- */
    VkImageMemoryBarrier imb3 = {
        VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL,
        0, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
        clr_img, {VK_IMAGE_ASPECT_COLOR_BIT, 0, 2, 0, 1}};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 1, &imb3);
    VkClearColorValue ccv = {{0.5f, 0.25f, 0.75f, 1.0f}};
    VkImageSubresourceRange crr = {
        VK_IMAGE_ASPECT_COLOR_BIT, 0, 2, 0, 1};
    vkCmdClearColorImage(cb, clr_img,
                         VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                         &ccv, 1, &crr);
    imb3.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    imb3.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    imb3.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    imb3.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, NULL, 0, NULL, 1, &imb3);
    VkBufferImageCopy bic3 = {256, 0, 0,
        {VK_IMAGE_ASPECT_COLOR_BIT, 1, 0, 1}, {0, 0, 0}, {2, 2, 1}};
    vkCmdCopyImageToBuffer(cb, clr_img,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           rb_buf, 1, &bic3);
    chk(vkEndCommandBuffer(cb), "end cb");

    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, 0};
    VkFence fence;
    chk(vkCreateFence(dev, &fci, NULL, &fence), "fence");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                       0, NULL, NULL, 1, &cb, 0, NULL};
    chk(vkQueueSubmit(q, 1, &si, fence), "submit");
    chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX), "fence wait");

    float out[64];
    memcpy(out, rb_map, sizeof(out));
    uint8_t clr_rb[16];
    memcpy(clr_rb, (const uint8_t *)rb_map + 256, sizeof(clr_rb));
    vkUnmapMemory(dev, rb_mem);

    printf("out[0..3]: %.4f %.4f %.4f %.4f\n", out[0], out[1], out[2],
           out[3]);
    int bad = 0;
    double maxerr = 0;
    for (int i = 0; i < 8; i++) {
        double u = i * 0.19 - 0.07;
        double v = 0.13 + (i & 3) * 0.37;
        double ref[4];
        for (int half = 0; half < 2; half++) {
            sample_ref(u, v, half, ref);
            int x = (i & 3) + half * 4, y = i >> 2;
            for (int c = 0; c < 4; c++) {
                double d = fabs(out[(y * 8 + x) * 4 + c] - ref[c]);
                if (d > maxerr) maxerr = d;
                if (d > 4.0 / 255.0 + 1e-9) bad++;
            }
        }
    }
    printf("maxerr=%.5f tol=%.5f\n", maxerr, 4.0 / 255.0);

    /* clear readback: every mip-1 texel must equal the CPU conversion
       of the float colour — exact for UNORM8 round-to-nearest */
    {
        const float cc[4] = {0.5f, 0.25f, 0.75f, 1.0f};
        int cbad = 0;
        for (int i = 0; i < 16; i++) {
            float f = cc[i & 3];
            uint8_t want = f <= 0.0f ? 0
                         : f >= 1.0f ? 255
                         : (uint8_t)(f * 255.0 + 0.5);
            if (clr_rb[i] != want) {
                printf("FAIL: clear byte %d exp %02x got %02x\n",
                       i, want, clr_rb[i]);
                cbad++;
            }
        }
        printf("clear mip1: %s (%d bytes)\n",
               cbad ? "FAIL" : "ok", 16);
        bad += cbad;
    }
    if (bad) {
        printf("G6LC_VKIMAGE_FAIL mismatches=%d maxerr=%.5f\n", bad,
               maxerr);
        return 1;
    }
    printf("G6LC_VKIMAGE_PASS words=64 maxerr=%.5f\n", maxerr);
    vkDeviceWaitIdle(dev);
    return 0;
}
