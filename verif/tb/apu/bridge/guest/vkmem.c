// SPDX-License-Identifier: MIT
// vkmem — two-heap memory-model acceptance test for the G6LC Venus
// backend (§12 memory split).  The device advertises heap0 =
// DEVICE_LOCAL (private arena) and heap1 = DEVICE_LOCAL |
// HOST_VISIBLE | HOST_COHERENT (guest aperture).  Since 3d-d a type-1
// allocation is lazy at vkAllocateMemory but backed at first *bind*
// on a device-chosen extent (DEVBACKED); the kernel's MAP_BLOB then
// relocates it to the guest offset, contents carried.
//
//   gcc -O2 -o vkmem vkmem.c -lvulkan && ./vkmem bufcopy.spv
//
// Checks:
//   A  12 MiB on the HOST_VISIBLE type succeeds (> private arena —
//      only possible on the 24 MiB guest-span heap), maps, and a
//      strided write/read pattern verifies.
//   B  2 MiB on the DEVICE_LOCAL-only type + buffer bind succeeds.
//   C  12 MiB on the DEVICE_LOCAL-only type must fail
//      (heap0 < 12 MiB — heap separation is truthful, not pooled).
//   D  3d-d: alloc 1 MiB host-visible -> bind -> vkCmdFillBuffer ->
//      fence -> vkMapMemory -> verify (GPU write before the kernel
//      picks the offset; the map relocates the filled extent).
//   E  3d-d: alloc -> bind -> vkUpdateDescriptorSets -> map -> write
//      -> dispatch -> readback (the descriptor record rides the
//      memory handle through the relocation).
//
// Venus submits vkAllocateMemory asynchronously
// (vn_device_memory_alloc_simple): the guest-visible VK_SUCCESS is
// unconditional and the renderer-side result is only latched into the
// ring seqno status, surfaced lazily by vn_device_memory_wait_alloc()
// at first bo use.  Case C therefore forces Mesa's synchronous alloc
// path via VN_PERF=no_async_mem_alloc (same device command path; the
// reply is simply awaited), so a real renderer OOM is observable here.
// Exit 0 + "G6LC_VKMEM_PASS" when all checks hold.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#define HOST_BYTES (12u * 1024u * 1024u)
#define PRIV_BYTES (2u * 1024u * 1024u)
#define FILL_BYTES (1u * 1024u * 1024u)
#define FILL_WORD  0xCAFEF00Du

static void chk(VkResult r, const char *what)
{
    if (r != VK_SUCCESS) {
        printf("FAIL: %s -> %d\n", what, (int)r);
        exit(1);
    }
}

/* bufcopy_1_in0.bin — same embedded vector as vkcompute.c */
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

    /* Force synchronous vkAllocateMemory so renderer errors reach the
     * caller (see header comment); must precede any Vulkan call. */
    setenv("VN_PERF", "no_async_mem_alloc", 1);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkmem", 0, "vkmem", 0, VK_API_VERSION_1_1};
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
    for (uint32_t h = 0; h < mp.memoryHeapCount; h++)
        printf("heap%u: size=%llu flags=0x%x\n", h,
               (unsigned long long)mp.memoryHeaps[h].size,
               mp.memoryHeaps[h].flags);
    uint32_t mt_host = UINT32_MAX, mt_dev = UINT32_MAX;
    for (uint32_t t = 0; t < mp.memoryTypeCount; t++) {
        VkFlags fl = mp.memoryTypes[t].propertyFlags;
        printf("type%u: heap%u flags=0x%x\n", t,
               mp.memoryTypes[t].heapIndex, fl);
        if ((fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            (fl & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) &&
            mt_host == UINT32_MAX)
            mt_host = t;
        if ((fl & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
            !(fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            mt_dev == UINT32_MAX)
            mt_dev = t;
    }
    if (mt_host == UINT32_MAX) { printf("FAIL: no host-visible type\n"); return 1; }
    if (mt_dev == UINT32_MAX)  { printf("FAIL: no device-local-only type\n"); return 1; }

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

    /* A: 12 MiB host-visible — larger than the private arena, so it
     * can only live on the guest-span heap.  Lazy: the backing is
     * established by vkMapMemory (MAP_BLOB), so the map itself is
     * the coverage point. */
    VkDeviceMemory mhost;
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, HOST_BYTES, mt_host};
    chk(vkAllocateMemory(dev, &mai, NULL, &mhost), "alloc 12MiB host-vis");
    void *p;
    chk(vkMapMemory(dev, mhost, 0, HOST_BYTES, 0, &p), "map 12MiB");
    uint32_t *w = p;
    uint32_t nw = HOST_BYTES / 4096;   /* one word per 4 KiB page */
    for (uint32_t i = 0; i < nw; i++)
        w[i * 1024] = i ^ 0x5a5a0000u;
    w[HOST_BYTES / 4 - 1] = 0xdeadbeefu;
    uint32_t bad = 0;
    for (uint32_t i = 0; i < nw; i++)
        if (w[i * 1024] != (i ^ 0x5a5a0000u)) bad++;
    if (w[HOST_BYTES / 4 - 1] != 0xdeadbeefu) bad++;
    if (bad) { printf("FAIL: host-vis pattern mismatches=%u\n", bad); return 1; }
    vkUnmapMemory(dev, mhost);
    vkFreeMemory(dev, mhost, NULL);
    printf("host-visible 12MiB alloc+map+verify PASS\n");

    /* B: 2 MiB device-local (eager private-arena backing) + bind. */
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                              NULL, 0, PRIV_BYTES,
                              VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                              VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                              VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkBuffer buf;
    chk(vkCreateBuffer(dev, &bci, NULL, &buf), "vkCreateBuffer 2MiB");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, buf, &mr);
    uint32_t mti = mt_dev;
    if (!(mr.memoryTypeBits & (1u << mti)))
        mti = __builtin_ctz(mr.memoryTypeBits);
    VkDeviceMemory mdev;
    VkMemoryAllocateInfo mai2 = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 NULL, mr.size, mti};
    chk(vkAllocateMemory(dev, &mai2, NULL, &mdev), "alloc 2MiB dev-local");
    chk(vkBindBufferMemory(dev, buf, mdev, 0), "bind 2MiB");
    vkDestroyBuffer(dev, buf, NULL);
    vkFreeMemory(dev, mdev, NULL);
    printf("device-local 2MiB alloc+bind PASS\n");

    /* C: 12 MiB on the private-arena type must fail — the heaps are
     * separate, so >8 MiB cannot be satisfied from heap0. */
    VkDeviceMemory mneg;
    VkMemoryAllocateInfo mai3 = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 NULL, HOST_BYTES, mt_dev};
    VkResult r = vkAllocateMemory(dev, &mai3, NULL, &mneg);
    if (r == VK_SUCCESS) {
        printf("FAIL: 12MiB device-local alloc unexpectedly succeeded\n");
        vkFreeMemory(dev, mneg, NULL);
        return 1;
    }
    printf("private-arena overflow refused (%d) PASS\n", (int)r);

    /* shared cbuf scaffolding for arms D and E */
    VkCommandPoolCreateInfo cpci2 = {
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL, 0, 0};
    VkCommandPool cpool;
    chk(vkCreateCommandPool(dev, &cpci2, NULL, &cpool), "cmdpool");
    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, cpool,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    chk(vkAllocateCommandBuffers(dev, &cbai, &cb), "cmdbuf");
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                             NULL, 0};
    VkFence fence;
    chk(vkCreateFence(dev, &fci, NULL, &fence), "fence");
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                       0, NULL, NULL, 1, &cb, 0, NULL};

    /* D (3d-d): alloc 1 MiB host-visible -> bind -> FillBuffer ->
     * fence -> vkMapMemory -> verify.  The fill lands on the
     * device-chosen DEVBACKED extent; MAP_BLOB relocates it to the
     * kernel offset with the pattern carried. */
    VkDeviceMemory mfill;
    VkBuffer fbuf;
    bci.size = FILL_BYTES;
    bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    chk(vkCreateBuffer(dev, &bci, NULL, &fbuf), "D fill buf");
    vkGetBufferMemoryRequirements(dev, fbuf, &mr);
    VkMemoryAllocateInfo mai4 = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 NULL, mr.size, mt_host};
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai4.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai4, NULL, &mfill), "D alloc 1MiB");
    chk(vkBindBufferMemory(dev, fbuf, mfill, 0), "D bind");
    chk(vkBeginCommandBuffer(cb, &bbi), "D begin");
    vkCmdFillBuffer(cb, fbuf, 0, FILL_BYTES, FILL_WORD);
    chk(vkEndCommandBuffer(cb), "D end");
    chk(vkQueueSubmit(q, 1, &si, fence), "D submit");
    chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX),
        "D fence wait");
    chk(vkMapMemory(dev, mfill, 0, FILL_BYTES, 0, &p), "D map");
    w = p;
    bad = 0;
    for (uint32_t i = 0; i < FILL_BYTES / 4; i++)
        if (w[i] != FILL_WORD) bad++;
    vkUnmapMemory(dev, mfill);
    if (bad) {
        printf("FAIL: 1MiB fill-then-map mismatches=%u\n", bad);
        return 1;
    }
    vkDestroyBuffer(dev, fbuf, NULL);
    vkFreeMemory(dev, mfill, NULL);
    printf("3d-d fill->fence->map 1MiB PASS\n");

    /* E (3d-d): two 128 B SSBOs on host-visible memory.  Bind + the
     * descriptor update both run while src is still unmapped
     * (DEVBACKED); the map relocates it, the guest writes the input
     * image at the kernel offset, the dispatch resolves the record's
     * memory handle, and the dst readback maps after the fence. */
    VkBuffer ebuf[2];
    VkDeviceMemory emem[2];
    for (int i = 0; i < 2; i++) {
        bci.size = 128;
        bci.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        chk(vkCreateBuffer(dev, &bci, NULL, &ebuf[i]), "E buf");
        vkGetBufferMemoryRequirements(dev, ebuf[i], &mr);
        VkMemoryAllocateInfo mai5 = {
            VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, NULL, mr.size,
            mt_host};
        if (!(mr.memoryTypeBits & (1u << mt_host)))
            mai5.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
        chk(vkAllocateMemory(dev, &mai5, NULL, &emem[i]), "E alloc");
        chk(vkBindBufferMemory(dev, ebuf[i], emem[i], 0), "E bind");
    }
    VkDescriptorSetLayoutBinding lb[2] = {
        {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1,
         VK_SHADER_STAGE_COMPUTE_BIT, NULL},
    };
    VkDescriptorSetLayoutCreateInfo dlci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, NULL, 0,
        2, lb};
    VkDescriptorSetLayout dsl;
    chk(vkCreateDescriptorSetLayout(dev, &dlci, NULL, &dsl), "E dsl");
    VkDescriptorPoolSize psz = {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2};
    VkDescriptorPoolCreateInfo pci = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0, 1, 1,
        &psz};
    VkDescriptorPool dpool;
    chk(vkCreateDescriptorPool(dev, &pci, NULL, &dpool), "E dpool");
    VkDescriptorSetAllocateInfo dsai = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dpool,
        1, &dsl};
    VkDescriptorSet dset;
    chk(vkAllocateDescriptorSets(dev, &dsai, &dset), "E dset");
    VkDescriptorBufferInfo bi[2] = {{ebuf[0], 0, 128},
                                    {ebuf[1], 0, 128}};
    VkWriteDescriptorSet wr[2];
    for (int i = 0; i < 2; i++)
        wr[i] = (VkWriteDescriptorSet){
            VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dset, i, 0,
            1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, NULL, &bi[i], NULL};
    vkUpdateDescriptorSets(dev, 2, wr, 0, NULL);

    /* src's first map happens here — after bind AND after the
     * descriptor update — the kernel's MAP_BLOB relocates the
     * bind-time extent; the input image lands at the new offset */
    chk(vkMapMemory(dev, emem[0], 0, 128, 0, &p), "E map src");
    memcpy(p, src_words, 128);
    vkUnmapMemory(dev, emem[0]);

    VkPipelineLayoutCreateInfo plci = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0,
        1, &dsl, 0, NULL};
    VkPipelineLayout playout;
    chk(vkCreatePipelineLayout(dev, &plci, NULL, &playout), "E playout");
    VkShaderModuleCreateInfo smci = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0,
        (size_t)spv_n, spv};
    VkShaderModule smod;
    chk(vkCreateShaderModule(dev, &smci, NULL, &smod), "E shader");
    VkComputePipelineCreateInfo cpci = {
        VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_COMPUTE_BIT, smod, "main", NULL},
        playout, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    chk(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL,
                                 &pipe), "E pipeline");

    /* E gets its own cb+fence: re-beginning the EXECUTABLE cb without a
     * reset violates VUID-vkBeginCommandBuffer-commandBuffer-00050 (the
     * pool lacks RESET_COMMAND_BUFFER_BIT) and the renderer rejects it. */
    VkCommandBuffer cb_e;
    chk(vkAllocateCommandBuffers(dev, &cbai, &cb_e), "E cmdbuf");
    VkFence fence_e;
    chk(vkCreateFence(dev, &fci, NULL, &fence_e), "E fence");
    VkSubmitInfo si_e = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL,
                         0, NULL, NULL, 1, &cb_e, 0, NULL};

    chk(vkBeginCommandBuffer(cb_e, &bbi), "E begin");
    vkCmdBindPipeline(cb_e, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb_e, VK_PIPELINE_BIND_POINT_COMPUTE, playout,
                            0, 1, &dset, 0, NULL);
    vkCmdDispatch(cb_e, 4, 1, 1);
    chk(vkEndCommandBuffer(cb_e), "E end");
    chk(vkQueueSubmit(q, 1, &si_e, fence_e), "E submit");
    chk(vkWaitForFences(dev, 1, &fence_e, VK_TRUE, UINT64_MAX),
        "E fence wait");

    /* dst's first map — after the fence; the device-chosen extent is
     * relocated with the dispatch's output words carried */
    uint32_t out[32];
    chk(vkMapMemory(dev, emem[1], 0, 128, 0, &p), "E map dst");
    memcpy(out, p, 128);
    vkUnmapMemory(dev, emem[1]);
    bad = 0;
    for (int i = 0; i < 32; i++)
        if (out[i] != src_words[i]) bad++;
    printf("E out[0..7]: %08x %08x %08x %08x %08x %08x %08x %08x\n",
           out[0], out[1], out[2], out[3], out[4], out[5], out[6],
           out[7]);
    if (bad) {
        printf("FAIL: bind->update->map->dispatch mismatches=%d\n", bad);
        return 1;
    }
    printf("3d-d bind->update->map->dispatch PASS\n");

    vkDestroyFence(dev, fence_e, NULL);
    vkFreeCommandBuffers(dev, cpool, 1, &cb_e);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(inst, NULL);
    printf("G6LC_VKMEM_PASS\n");
    return 0;
}
