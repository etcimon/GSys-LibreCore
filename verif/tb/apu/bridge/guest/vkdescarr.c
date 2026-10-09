// vkdescarr — descriptor-array dynamic-indexing dispatch for the G6LC
// F5 proof (§12.1 F5).  Loads descarr.spv (o[i] = ins[i/8].v[i],
// 32 lanes over a 4-element SSBO array at set 0 binding 0), checks
// the two array-dynamic-indexing feature bits via
// vkGetPhysicalDeviceFeatures2, enables them on the device, runs the
// dispatch and verifies bit-exact against the embedded vectors
// (sh_vectors/descarr_1, computed by spirv_model.py).
//
//   gcc -O2 -o vkdescarr vkdescarr.c -lvulkan && ./vkdescarr descarr.spv
//
// Exit 0 + "G6LC_VKDESCARR_PASS" on bit-exact match.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#define NBUF 5   /* ins[0..3] + out */

static void chk(VkResult r, const char *what)
{
    if (r != VK_SUCCESS) {
        printf("FAIL: %s -> %d\n", what, (int)r);
        exit(1);
    }
}

/* descarr_1_in{0..4}.bin — in0..in3 are the four array elements,
 * in4 is the initial output-buffer content. */
static const uint32_t ins[4][32] = {
    {0x422bf64d, 0xc1b1621c, 0xc2601c33, 0xc228924c,
     0x41db8542, 0x419598be, 0xc0e3de06, 0x4240e5dd,
     0x41dc86bc, 0x42674fdd, 0x41dc8b04, 0xc20bfe11,
     0xc2202459, 0xc1a0b857, 0xc150cd94, 0x41192cd4,
     0x41723815, 0xc1c21069, 0xc22e10da, 0xc229bf12,
     0x41d3bbc3, 0xc0fb0183, 0x41eb8fe1, 0xc22d7955,
     0x40f1e276, 0x41f76fee, 0x4224813a, 0x41dc4731,
     0xc1dce8c0, 0x41493c64, 0xc24ca27f, 0x415f5ca7},
    {0x41c81bf3, 0xc225757d, 0xc0ad6049, 0x424ea6bc,
     0x412e1ce8, 0xc26ebd34, 0xc1b27ce7, 0xc25f5b2e,
     0x3ed18c4a, 0xc261e1e1, 0xc2742034, 0x427ca552,
     0xc2536642, 0xc23148db, 0x41df307a, 0x424fbda4,
     0x418eff7e, 0x41b9f120, 0xc249600a, 0xc22fad81,
     0x41f37be4, 0xc16aa433, 0x425acd7d, 0x40e421ee,
     0xc1bdfef5, 0x41c3ef75, 0xc08625ad, 0xc22687df,
     0xc10aaab0, 0xc22166be, 0xbf068dc6, 0xc26d895b},
    {0xc24de00b, 0x424f4be6, 0x41d58576, 0xc202fb0f,
     0x40460fff, 0xc1040445, 0x3f47ac0d, 0xc1eb15b6,
     0x4226a9a0, 0x4270efc2, 0xc279c9da, 0x41c1f401,
     0xc21fe288, 0x4268c0d8, 0xc0efaa16, 0x414e90a0,
     0xc2117b82, 0x425f6392, 0x41802d11, 0x423670df,
     0xc08019c2, 0x4248255d, 0xc277dd6b, 0xc23b894f,
     0x40e2eddd, 0x4084ac14, 0x413af725, 0x42204d6f,
     0x422d37f4, 0xc20bffaf, 0xc1804af9, 0x41d054bd},
    {0x420130a5, 0x421672c9, 0x422538cd, 0x40704a6a,
     0x42364145, 0x41b53cb9, 0xc1931787, 0xc248a490,
     0xc206b93e, 0x4132d05e, 0x425306a9, 0x4277b9c6,
     0xc227e993, 0xc1526c42, 0xc2686846, 0xc24c6a8a,
     0xc2740bbf, 0xc268f9d3, 0x4116fa5a, 0xbbd452ec,
     0x422b9ba5, 0x41bb562e, 0x424eb179, 0x41bc6453,
     0xc1f71603, 0xc275a17e, 0x41a3dbda, 0x41a74de8,
     0xc228b86c, 0x424ff1ae, 0x40c62ad2, 0xc11a0f4d},
};
static const uint32_t out_init[32] = {
    0xc2163c1b, 0xc22b55bd, 0xc25e7249, 0x421fbe67,
    0x41b98e5d, 0x4246ce6e, 0x422ed05f, 0x41c6e863,
    0x42169f49, 0x413b52f0, 0xc26db040, 0x42732e79,
    0x40cb1c26, 0xc1de9c01, 0x413401d6, 0x41a76d46,
    0x41d7cbf3, 0x4138287f, 0x4194e3ea, 0x3eef2b61,
    0xc246eff2, 0x425fc4f6, 0x4171c00d, 0xc24e5898,
    0xc240d457, 0x417a663e, 0xc1eb01a6, 0xc10b4a1e,
    0x41bd9a2d, 0xc1a30228, 0xc1381dba, 0x4277b25b,
};

int main(int argc, char **argv)
{
    const char *spv_path = argc > 1 ? argv[1] : "descarr.spv";
    FILE *f = fopen(spv_path, "rb");
    if (!f) { perror(spv_path); return 1; }
    fseek(f, 0, SEEK_END);
    long spv_n = ftell(f);
    rewind(f);
    uint32_t *spv = malloc(spv_n);
    if (fread(spv, 1, spv_n, f) != (size_t)spv_n) { perror("spv read"); return 1; }
    fclose(f);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkdescarr", 0, "vkdescarr", 0,
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

    /* feature check runs on every PD; the Venus device must report
     * both array-dynamic-indexing bits */
    VkPhysicalDevice pdev = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < npdev; i++) {
        VkPhysicalDeviceFeatures2 f2 = {
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, NULL};
        vkGetPhysicalDeviceFeatures2(pdevs[i], &f2);
        VkPhysicalDeviceProperties pp;
        vkGetPhysicalDeviceProperties(pdevs[i], &pp);
        printf("pd%u: %s ssboArrDyn=%u uboArrDyn=%u\n", i, pp.deviceName,
               f2.features.shaderStorageBufferArrayDynamicIndexing,
               f2.features.shaderUniformBufferArrayDynamicIndexing);
        if ((strstr(pp.deviceName, "Venus") ||
             strstr(pp.deviceName, "LibreCore")) &&
            f2.features.shaderStorageBufferArrayDynamicIndexing)
            pdev = pdevs[i];
    }
    if (!pdev) { printf("FAIL: no Venus PD with SSBO array dyn indexing\n");
                 return 1; }

    VkPhysicalDeviceMemoryProperties mprops;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mprops);
    uint32_t mt = UINT32_MAX;
    for (uint32_t t = 0; t < mprops.memoryTypeCount; t++) {
        VkFlags fl = mprops.memoryTypes[t].propertyFlags;
        if ((fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (fl & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            mt = t;
    }
    if (mt == UINT32_MAX) { printf("FAIL: no host-visible memory\n"); return 1; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
    VkPhysicalDeviceFeatures en = {0};
    en.robustBufferAccess = VK_TRUE;
    en.shaderStorageBufferArrayDynamicIndexing = VK_TRUE;
    en.shaderUniformBufferArrayDynamicIndexing = VK_TRUE;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL,
                              0, 1, &qci, 0, NULL, 0, NULL, &en};
    VkDevice dev;
    chk(vkCreateDevice(pdev, &dci, NULL, &dev), "vkCreateDevice");
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    /* 5 × 128 B buffers: ins[0..3] then out */
    VkBuffer bufs[NBUF];
    VkDeviceMemory mems[NBUF];
    for (int i = 0; i < NBUF; i++) {
        VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                  NULL, 0, 128,
                                  VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                  VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
        chk(vkCreateBuffer(dev, &bci, NULL, &bufs[i]), "vkCreateBuffer");
        VkMemoryRequirements mr;
        vkGetBufferMemoryRequirements(dev, bufs[i], &mr);
        uint32_t mti = mt;
        if (!(mr.memoryTypeBits & (1u << mti)))
            mti = __builtin_ctz(mr.memoryTypeBits);
        VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                    NULL, mr.size, mti};
        chk(vkAllocateMemory(dev, &mai, NULL, &mems[i]), "vkAllocateMemory");
        chk(vkBindBufferMemory(dev, bufs[i], mems[i], 0), "vkBindBufferMemory");
    }
    for (int i = 0; i < 4; i++) {
        void *p;
        chk(vkMapMemory(dev, mems[i], 0, 128, 0, &p), "map ins");
        memcpy(p, ins[i], 128);
        vkUnmapMemory(dev, mems[i]);
    }
    void *p;
    chk(vkMapMemory(dev, mems[4], 0, 128, 0, &p), "map out init");
    memcpy(p, out_init, 128);
    vkUnmapMemory(dev, mems[4]);

    /* binding 0: array of 4 SSBOs; binding 1: output SSBO */
    VkDescriptorSetLayoutBinding lb[2] = {
        {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 4,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
    };
    VkDescriptorSetLayoutCreateInfo dlci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0,
        2, lb};
    VkDescriptorSetLayout dset_layout;
    chk(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dset_layout), "dslayout");

    VkDescriptorPoolSize psz = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 5};
    VkDescriptorPoolCreateInfo pci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &psz};
    VkDescriptorPool pool;
    chk(vkCreateDescriptorPool(dev, &pci, NULL, &pool), "dpool");

    VkDescriptorSetAllocateInfo dsai = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, pool,
        1, &dset_layout};
    VkDescriptorSet dset;
    chk(vkAllocateDescriptorSets(dev, &dsai, &dset), "dset alloc");

    VkDescriptorBufferInfo bi[NBUF];
    for (int i = 0; i < NBUF; i++)
        bi[i] = (VkDescriptorBufferInfo){bufs[i], 0, 128};
    VkWriteDescriptorSet wr[2] = {
        {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dset, 0, 0, 4,
         VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, bi, NULL},
        {VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dset, 1, 0, 1,
         VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &bi[4], NULL},
    };
    vkUpdateDescriptorSets(dev, 2, wr, 0, NULL);

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
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, playout, 0,
                            1, &dset, 0, NULL);
    vkCmdDispatch(cb, 4, 1, 1);
    chk(vkEndCommandBuffer(cb), "end cb");

    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, 0};
    VkFence fence;
    chk(vkCreateFence(dev, &fci, NULL, &fence), "fence");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                       0, NULL, NULL, 1, &cb, 0, NULL};
    chk(vkQueueSubmit(q, 1, &si, fence), "submit");
    chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX), "fence wait");

    uint32_t out[32];
    chk(vkMapMemory(dev, mems[4], 0, 128, 0, &p), "map out");
    memcpy(out, p, 128);
    vkUnmapMemory(dev, mems[4]);

    int bad = 0;
    for (int i = 0; i < 32; i++)
        if (out[i] != ins[i / 8][i]) bad++;
    printf("out[0..7]: %08x %08x %08x %08x %08x %08x %08x %08x\n",
           out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7]);
    printf("out[8..15]: %08x %08x %08x %08x %08x %08x %08x %08x\n",
           out[8], out[9], out[10], out[11],
           out[12], out[13], out[14], out[15]);
    if (bad) {
        printf("G6LC_VKDESCARR_FAIL mismatches=%d\n", bad);
        return 1;
    }
    printf("G6LC_VKDESCARR_PASS words=32\n");
    vkDeviceWaitIdle(dev);
    return 0;
}
