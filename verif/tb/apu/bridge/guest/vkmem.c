// SPDX-License-Identifier: MIT
// vkmem — two-heap memory-model acceptance test for the G6LC Venus
// backend (§12 memory split).  The device advertises heap0 =
// DEVICE_LOCAL (private arena) and heap1 = DEVICE_LOCAL |
// HOST_VISIBLE | HOST_COHERENT (guest aperture); type-1 allocations
// are lazy until vkMapMemory establishes the blob backing.
//
//   gcc -O2 -o vkmem vkmem.c -lvulkan && ./vkmem
//
// Checks:
//   A  12 MiB on the HOST_VISIBLE type succeeds (> private arena —
//      only possible on the 24 MiB guest-span heap), maps, and a
//      strided write/read pattern verifies.
//   B  2 MiB on the DEVICE_LOCAL-only type + buffer bind succeeds.
//   C  12 MiB on the DEVICE_LOCAL-only type must fail
//      (heap0 < 12 MiB — heap separation is truthful, not pooled).
//
// Venus submits vkAllocateMemory asynchronously
// (vn_device_memory_alloc_simple): the guest-visible VK_SUCCESS is
// unconditional and the renderer-side result is only latched into the
// ring seqno status, surfaced lazily by vn_device_memory_wait_alloc()
// at first bo use.  Case C therefore forces Mesa's synchronous alloc
// path via VN_PERF=no_async_mem_alloc (same device command path; the
// reply is simply awaited), so a real renderer OOM is observable here.
// Exit 0 + "G6LC_VKMEM_PASS" when all three hold.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#define HOST_BYTES (12u * 1024u * 1024u)
#define PRIV_BYTES (2u * 1024u * 1024u)

static void chk(VkResult r, const char *what)
{
    if (r != VK_SUCCESS) {
        printf("FAIL: %s -> %d\n", what, (int)r);
        exit(1);
    }
}

int main(void)
{
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

    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(inst, NULL);
    printf("G6LC_VKMEM_PASS\n");
    return 0;
}
