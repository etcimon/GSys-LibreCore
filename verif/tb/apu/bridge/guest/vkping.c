// SPDX-License-Identifier: MIT
// vkping — minimal full-cycle Venus probe for wedge forensics.
//
// Each process performs the smallest lifecycle that exercises the
// per-process teardown path implicated in the post-vkmem wedge:
//   instance -> PD pick -> device+queue -> device-local alloc + bind
//   + map (DEVBACKED -> kernel MAP_BLOB) -> unmap -> free -> destroy
//   device -> destroy instance -> exit.
//
// The drive script runs it in a shell loop; every exit recreates the
// destroy-instance/DestroyRing/RESET_CTX window, so races there get
// dozens of chances per boot instead of one per full test suite.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int chk(VkResult r, const char *what) {
    if (r != VK_SUCCESS) { printf("FAIL: %s -> %d\n", what, (int)r); return 1; }
    return 0;
}

int main(int argc, char **argv) {
    int iter = argc > 1 ? atoi(argv[1]) : 0;
    setenv("VN_PERF", "no_async_mem_alloc", 1);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkping", 0, "vkping", 0, VK_API_VERSION_1_1};
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
        if (strstr(pp.deviceName, "Venus") || strstr(pp.deviceName, "LibreCore"))
            pdev = pdevs[i];
    }
    if (!pdev) { printf("FAIL: no Venus PD\n"); return 1; }

    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pdev, &mp);
    uint32_t mt_dev = UINT32_MAX;
    for (uint32_t t = 0; t < mp.memoryTypeCount; t++) {
        VkFlags fl = mp.memoryTypes[t].propertyFlags;
        if ((fl & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) &&
            !(fl & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) &&
            mt_dev == UINT32_MAX)
            mt_dev = t;
    }
    if (mt_dev == UINT32_MAX) { printf("FAIL: no dev-local type\n"); return 1; }

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
    (void)q;

    /* device-local buffer + bind + map: forces the DEVBACKED bind and
     * the kernel MAP_BLOB path that vkmem's teardown exercises. */
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                              NULL, 0, 65536,
                              VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                              VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                              VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkBuffer buf;
    chk(vkCreateBuffer(dev, &bci, NULL, &buf), "vkCreateBuffer");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, buf, &mr);
    uint32_t mti = mt_dev;
    if (!(mr.memoryTypeBits & (1u << mti)))
        mti = __builtin_ctz(mr.memoryTypeBits);
    VkDeviceMemory mdev;
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, mr.size, mti};
    chk(vkAllocateMemory(dev, &mai, NULL, &mdev), "alloc dev-local");
    chk(vkBindBufferMemory(dev, buf, mdev, 0), "bind");
    void *p = NULL;
    if (vkMapMemory(dev, mdev, 0, 65536, 0, &p) == VK_SUCCESS && p) {
        memset(p, 0xa5, 4096);
        vkUnmapMemory(dev, mdev);
    }
    vkDestroyBuffer(dev, buf, NULL);
    vkFreeMemory(dev, mdev, NULL);

    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(inst, NULL);
    printf("vkping %d OK\n", iter);
    return 0;
}
