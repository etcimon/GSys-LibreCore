// vkcompute — minimal stock-API compute dispatch for the G6LC Venus
// proof (§11 row 3d-b).  Loads a SPIR-V module, runs bufcopy
// (dst[i]=src[i], 32 lanes) on two 128 B SSBOs, prints the output
// words and compares against the embedded expected vector
// (sh_vectors/bufcopy_1, computed by spirv_model.py).
//
//   gcc -O2 -o vkcompute vkcompute.c -lvulkan && ./vkcompute bufcopy.spv
//
// Exit 0 + "G6LC_VKCOMPUTE_PASS" on bit-exact match.
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

/* bufcopy_1_in0.bin (source) — the host vector input. */
static const uint32_t src_words[32] = {
    0xc0303e3e, 0xc26c2edc, 0xc261a379, 0xc22c97b9,
    0xc222b215, 0xc0ecff27, 0xc0e6b931, 0x42462bd0,
    0x41d596f8, 0x41b79fa1, 0xc21e133d, 0xc1bfd45d,
    0xc20561b1, 0x41207773, 0xc210a2e0, 0x4176525d,
    0xc22d08c6, 0x41446459, 0xc13da8ab, 0x426c292e,
    0xc0b57b13, 0xc13deaed, 0xc1d4a20b, 0x426008df,
    0x41827145, 0x421e037c, 0xc258bfea, 0xc2358387,
    0x4232d6b6, 0xc12ceb83, 0x40d1179c, 0xc1e7d6c0,
};

int main(int argc, char **argv)
{
    const char *spv_path = argc > 1 ? argv[1] : "bufcopy.spv";
    FILE *f = fopen(spv_path, "rb");
    if (!f) { perror(spv_path); return 1; }
    fseek(f, 0, SEEK_END);
    long spv_n = ftell(f);
    rewind(f);
    uint32_t *spv = malloc(spv_n);
    if (fread(spv, 1, spv_n, f) != (size_t)spv_n) { perror("spv read"); return 1; }
    fclose(f);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkcompute", 0, "vkcompute", 0,
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

    /* prefer a device that is not llvmpipe when one exists */
    VkPhysicalDevice pdev = pdevs[0];
    for (uint32_t i = 0; i < npdev; i++) {
        VkPhysicalDeviceProperties pp;
        vkGetPhysicalDeviceProperties(pdevs[i], &pp);
        printf("pd%u: %s (api %u.%u.%u driver %u)\n", i, pp.deviceName,
               VK_API_VERSION_MAJOR(pp.apiVersion),
               VK_API_VERSION_MINOR(pp.apiVersion),
               VK_API_VERSION_PATCH(pp.apiVersion), pp.driverVersion);
        if (strstr(pp.deviceName, "Venus") ||
            strstr(pp.deviceName, "LibreCore"))
            pdev = pdevs[i];
    }

    VkPhysicalDeviceMemoryProperties mprops;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mprops);
    uint32_t mt = UINT32_MAX;
    for (uint32_t t = 0; t < mprops.memoryTypeCount; t++) {
        VkFlags fl = mprops.memoryTypes[t].propertyFlags;
        if ((fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (fl & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))
            mt = t;
    }
    if (mt == UINT32_MAX)
        for (uint32_t t = 0; t < mprops.memoryTypeCount; t++)
            if (mprops.memoryTypes[t].propertyFlags &
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)
                mt = t;
    if (mt == UINT32_MAX) { printf("FAIL: no host-visible memory\n"); return 1; }
    printf("memory type %u of %u\n", mt, mprops.memoryTypeCount);

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

    /* two 128 B SSBOs: src (binding 0) and dst (binding 1) */
    VkBuffer bufs[2];
    VkDeviceMemory mems[2];
    for (int i = 0; i < 2; i++) {
        VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                  NULL, 0, 128,
                                  VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                  VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
        chk(vkCreateBuffer(dev, &bci, NULL, &bufs[i]), "vkCreateBuffer");
        VkMemoryRequirements mr;
        vkGetBufferMemoryRequirements(dev, bufs[i], &mr);
        VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                    NULL, mr.size, mt};
        if (!(mr.memoryTypeBits & (1u << mt))) {
            mt = __builtin_ctz(mr.memoryTypeBits);
            mai.memoryTypeIndex = mt;
        }
        chk(vkAllocateMemory(dev, &mai, NULL, &mems[i]), "vkAllocateMemory");
        chk(vkBindBufferMemory(dev, bufs[i], mems[i], 0), "vkBindBufferMemory");
    }
    void *p;
    chk(vkMapMemory(dev, mems[0], 0, 128, 0, &p), "map src");
    memcpy(p, src_words, 128);
    vkUnmapMemory(dev, mems[0]);
    chk(vkMapMemory(dev, mems[1], 0, 128, 0, &p), "map dst");
    memset(p, 0, 128);
    vkUnmapMemory(dev, mems[1]);

    VkDescriptorSetLayoutBinding lb[2] = {
        {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
    };
    VkDescriptorSetLayoutCreateInfo dlci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0,
        2, lb};
    VkDescriptorSetLayout dset_layout;
    chk(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dset_layout), "dslayout");

    VkDescriptorPoolSize psz = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2};
    VkDescriptorPoolCreateInfo pci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1, &psz};
    VkDescriptorPool pool;
    chk(vkCreateDescriptorPool(dev, &pci, NULL, &pool), "dpool");

    VkDescriptorSetAllocateInfo dsai = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, pool,
        1, &dset_layout};
    VkDescriptorSet dset;
    chk(vkAllocateDescriptorSets(dev, &dsai, &dset), "dset alloc");

    VkDescriptorBufferInfo bi[2] = {{bufs[0], 0, 128},
                                    {bufs[1], 0, 128}};
    VkWriteDescriptorSet wr[2];
    for (int i = 0; i < 2; i++)
        wr[i] = (VkWriteDescriptorSet){
            VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dset, i, 0, 1,
            VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &bi[i], NULL};
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
    chk(vkMapMemory(dev, mems[1], 0, 128, 0, &p), "map out");
    memcpy(out, p, 128);
    vkUnmapMemory(dev, mems[1]);

    int bad = 0;
    for (int i = 0; i < 32; i++)
        if (out[i] != src_words[i]) bad++;
    printf("out[0..7]: %08x %08x %08x %08x %08x %08x %08x %08x\n",
           out[0], out[1], out[2], out[3], out[4], out[5], out[6], out[7]);
    if (bad) {
        printf("G6LC_VKCOMPUTE_FAIL mismatches=%d\n", bad);
        return 1;
    }
    printf("G6LC_VKCOMPUTE_PASS words=32\n");
    vkDeviceWaitIdle(dev);
    return 0;
}
