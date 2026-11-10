// SPDX-License-Identifier: MIT
// vkmembig — >1 MiB buffer copy round-trip reproducer for the CTS
// memory.binding buffer_1048577 failure.  Mirrors the CTS path:
// host writes a pattern into a HOST_VISIBLE VkDeviceMemory-backed
// buffer, vkCmdCopyBuffer moves it buffer->buffer, and the host maps
// the destination and verifies every byte.  Sweeps sizes to find the
// exact boundary where the round-trip corrupts.
//
//   gcc -O2 -o vkmembig vkmembig.c -lvulkan && ./vkmembig
//
// For each size it reports PASS or FAIL:<first-bad-byte> so a
// truncated map / page-table / copy-chunk boundary shows up as an
// offset, not just a boolean.
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

/* deterministic byte pattern: byte i = (i*31 + (i>>8)) & 0xff —
 * position-dependent so a shifted/truncated copy shows a gradient,
 * not a constant. */
static uint8_t pat(uint64_t i) { return (uint8_t)((i * 31u + (i >> 8)) & 0xffu); }

struct bufmem { VkBuffer buf; VkDeviceMemory mem; VkDeviceSize size; };

static int roundtrip(VkDevice dev, VkQueue q, VkFence fence,
                     VkCommandBuffer cb,
                     VkBufferUsageFlags usage, uint32_t mtype,
                     VkDeviceSize size, int do_copy)
{
    struct bufmem a = {0}, b = {0};
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0,
                              size, usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    chk(vkCreateBuffer(dev, &bci, NULL, &a.buf), "create a");
    VkMemoryRequirements mr;
    vkGetBufferMemoryRequirements(dev, a.buf, &mr);
    VkDeviceSize asz = mr.size;
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, asz, mtype};
    if (!(mr.memoryTypeBits & (1u << mtype)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &a.mem), "alloc a");
    chk(vkBindBufferMemory(dev, a.buf, a.mem, 0), "bind a");

    void *p;
    chk(vkMapMemory(dev, a.mem, 0, asz, 0, &p), "map a");
    uint8_t *w = p;
    for (VkDeviceSize i = 0; i < asz; i++) w[i] = pat(i);
    VkMappedMemoryRange rng = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                               NULL, a.mem, 0, asz};
    vkFlushMappedMemoryRanges(dev, 1, &rng);

    if (do_copy) {
        /* second buffer+mem as copy destination */
        chk(vkCreateBuffer(dev, &bci, NULL, &b.buf), "create b");
        vkGetBufferMemoryRequirements(dev, b.buf, &mr);
        VkDeviceSize bsz = mr.size;
        VkMemoryAllocateInfo mai2 = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                     NULL, bsz, mtype};
        if (!(mr.memoryTypeBits & (1u << mtype)))
            mai2.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
        chk(vkAllocateMemory(dev, &mai2, NULL, &b.mem), "alloc b");
        chk(vkBindBufferMemory(dev, b.buf, b.mem, 0), "bind b");

        VkBufferCopy region = {0, 0, size};
        VkBufferMemoryBarrier bar = {
            VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
            VK_ACCESS_HOST_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
            a.buf, 0, size};
        VkBufferMemoryBarrier bar2 = {
            VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT,
            VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
            b.buf, 0, size};
        VkCommandBufferBeginInfo bbi = {
            VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
            VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
        vkResetCommandBuffer(cb, 0);
        chk(vkBeginCommandBuffer(cb, &bbi), "begin");
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_HOST_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL,
                             1, &bar, 0, NULL);
        vkCmdCopyBuffer(cb, a.buf, b.buf, 1, &region);
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL,
                             1, &bar2, 0, NULL);
        chk(vkEndCommandBuffer(cb), "end");
        VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL,
                           NULL, 1, &cb, 0, NULL};
        chk(vkQueueSubmit(q, 1, &si, fence), "submit");
        chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX), "fence");
        vkResetFences(dev, 1, &fence);

        /* verify on the DESTINATION map */
        chk(vkMapMemory(dev, b.mem, 0, bsz, 0, &p), "map b");
        rng.memory = b.mem; rng.size = bsz;
        vkInvalidateMappedMemoryRanges(dev, 1, &rng);
        w = p;
        VkDeviceSize bad = (VkDeviceSize)-1;
        uint64_t nbad = 0;
        for (VkDeviceSize i = 0; i < size; i++) {
            if (w[i] != pat(i)) { if (bad == (VkDeviceSize)-1) bad = i; nbad++; }
        }
        printf("  size=%llu copy: %s", (unsigned long long)size,
               nbad ? "FAIL" : "PASS");
        if (nbad)
            printf(" bad=%llu first@%llu (0x%llx) got=%02x exp=%02x",
                   (unsigned long long)nbad,
                   (unsigned long long)bad,
                   (unsigned long long)bad,
                   w[bad], pat(bad));
        printf("\n");
        vkUnmapMemory(dev, b.mem);
        vkDestroyBuffer(dev, b.buf, NULL);
        vkFreeMemory(dev, b.mem, NULL);
        vkUnmapMemory(dev, a.mem);
        vkDestroyBuffer(dev, a.buf, NULL);
        vkFreeMemory(dev, a.mem, NULL);
        return nbad ? 1 : 0;
    }

    /* no-copy control: host write -> host read on the same map */
    VkDeviceSize bad = (VkDeviceSize)-1;
    uint64_t nbad = 0;
    for (VkDeviceSize i = 0; i < asz; i++) {
        if (w[i] != pat(i)) { if (bad == (VkDeviceSize)-1) bad = i; nbad++; }
    }
    printf("  size=%llu nocopy: %s", (unsigned long long)size,
           nbad ? "FAIL" : "PASS");
    if (nbad)
        printf(" bad=%llu first@%llu got=%02x exp=%02x",
               (unsigned long long)nbad, (unsigned long long)bad,
               w[bad], pat(bad));
    printf("\n");
    vkUnmapMemory(dev, a.mem);
    vkDestroyBuffer(dev, a.buf, NULL);
    vkFreeMemory(dev, a.mem, NULL);
    return nbad ? 1 : 0;
}

/* CTS-faithful two-hop: pattern lives in a HOST_VISIBLE src buffer,
 * vkCmdCopyBuffer moves it into a DEVICE_LOCAL mid buffer, then out
 * to a HOST_VISIBLE dst buffer which the host maps and verifies.
 * Mirrors memory.binding regular.*: src/dst pick MemoryHostVisible
 * (type1) while the bound target picks deCtz32(memoryTypeBits) ->
 * type0 device-local.  Returns 0 pass / 1 fail. */
static int roundtrip2(VkDevice dev, VkQueue q, VkFence fence,
                      VkCommandBuffer cb,
                      VkBufferUsageFlags usage, uint32_t mt_host,
                      uint32_t mt_dev, VkDeviceSize size)
{
    struct bufmem a = {0}, b = {0}, c = {0};
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0,
                              size, usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkMemoryRequirements mr;
    VkDeviceSize asz = 0, bsz = 0, csz = 0;

    /* A: host-visible source */
    chk(vkCreateBuffer(dev, &bci, NULL, &a.buf), "2 create a");
    vkGetBufferMemoryRequirements(dev, a.buf, &mr); asz = mr.size;
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, asz, mt_host};
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &a.mem), "2 alloc a");
    chk(vkBindBufferMemory(dev, a.buf, a.mem, 0), "2 bind a");

    /* B: device-local middle (the CTS bound target) */
    chk(vkCreateBuffer(dev, &bci, NULL, &b.buf), "2 create b");
    vkGetBufferMemoryRequirements(dev, b.buf, &mr); bsz = mr.size;
    VkMemoryAllocateInfo mai2 = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 NULL, bsz, mt_dev};
    if (!(mr.memoryTypeBits & (1u << mt_dev)))
        mai2.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai2, NULL, &b.mem), "2 alloc b");
    chk(vkBindBufferMemory(dev, b.buf, b.mem, 0), "2 bind b");

    /* C: host-visible destination */
    chk(vkCreateBuffer(dev, &bci, NULL, &c.buf), "2 create c");
    vkGetBufferMemoryRequirements(dev, c.buf, &mr); csz = mr.size;
    VkMemoryAllocateInfo mai3 = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 NULL, csz, mt_host};
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai3.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai3, NULL, &c.mem), "2 alloc c");
    chk(vkBindBufferMemory(dev, c.buf, c.mem, 0), "2 bind c");

    /* host writes the pattern into A */
    void *p;
    chk(vkMapMemory(dev, a.mem, 0, asz, 0, &p), "2 map a");
    uint8_t *w = p;
    for (VkDeviceSize i = 0; i < asz; i++) w[i] = pat(i);
    VkMappedMemoryRange rng = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                               NULL, a.mem, 0, asz};
    vkFlushMappedMemoryRanges(dev, 1, &rng);

    VkBufferCopy r1 = {0, 0, size}, r2 = {0, 0, size};
    VkBufferMemoryBarrier bars[4] = {
        {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
         VK_ACCESS_HOST_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, a.buf, 0, size},
        {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, b.buf, 0, size},
        {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, c.buf, 0, size},
        {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL, 0, 0, 0, 0, 0, 0, 0},
    };
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    vkResetCommandBuffer(cb, 0);
    chk(vkBeginCommandBuffer(cb, &bbi), "2 begin");
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_HOST_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL,
                         1, &bars[0], 0, NULL);
    vkCmdCopyBuffer(cb, a.buf, b.buf, 1, &r1);
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL,
                         1, &bars[1], 0, NULL);
    vkCmdCopyBuffer(cb, b.buf, c.buf, 1, &r2);
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL,
                         1, &bars[2], 0, NULL);
    chk(vkEndCommandBuffer(cb), "2 end");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL,
                       NULL, 1, &cb, 0, NULL};
    chk(vkQueueSubmit(q, 1, &si, fence), "2 submit");
    chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX), "2 fence");
    vkResetFences(dev, 1, &fence);

    chk(vkMapMemory(dev, c.mem, 0, csz, 0, &p), "2 map c");
    rng.memory = c.mem; rng.size = csz;
    vkInvalidateMappedMemoryRanges(dev, 1, &rng);
    w = p;
    VkDeviceSize bad = (VkDeviceSize)-1;
    uint64_t nbad = 0;
    for (VkDeviceSize i = 0; i < size; i++) {
        if (w[i] != pat(i)) { if (bad == (VkDeviceSize)-1) bad = i; nbad++; }
    }
    printf("  size=%llu xdom2hop: %s", (unsigned long long)size,
           nbad ? "FAIL" : "PASS");
    if (nbad)
        printf(" bad=%llu first@%llu (0x%llx) got=%02x exp=%02x",
               (unsigned long long)nbad, (unsigned long long)bad,
               (unsigned long long)bad, w[bad], pat(bad));
    printf("\n");

    vkUnmapMemory(dev, c.mem);
    vkDestroyBuffer(dev, c.buf, NULL); vkFreeMemory(dev, c.mem, NULL);
    vkUnmapMemory(dev, a.mem);
    vkDestroyBuffer(dev, a.buf, NULL); vkFreeMemory(dev, a.mem, NULL);
    vkDestroyBuffer(dev, b.buf, NULL); vkFreeMemory(dev, b.mem, NULL);
    return nbad ? 1 : 0;
}

/* One CTS-style copy submission: HOST->TRANSFER barrier on src,
 * vkCmdCopyBuffer, TRANSFER->HOST barrier on dst, submit + fence wait.
 * Mirrors fillUpResource/readUpResource (each is its own submit). */
static void do_copy_submit(VkDevice dev, VkQueue q, VkFence fence,
                           VkCommandBuffer cb, VkBuffer s, VkBuffer d,
                           VkDeviceSize size)
{
    VkBufferMemoryBarrier bars[2] = {
        {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
         VK_ACCESS_HOST_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, s, 0, size},
        {VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, NULL,
         VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_HOST_READ_BIT,
         VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, d, 0, size},
    };
    VkBufferCopy cp = {0, 0, size};
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    vkResetCommandBuffer(cb, 0);
    chk(vkBeginCommandBuffer(cb, &bbi), "3 begin");
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_HOST_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL,
                         1, &bars[0], 0, NULL);
    vkCmdCopyBuffer(cb, s, d, 1, &cp);
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL,
                         1, &bars[1], 0, NULL);
    chk(vkEndCommandBuffer(cb), "3 end");
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL,
                       NULL, 1, &cb, 0, NULL};
    chk(vkQueueSubmit(q, 1, &si, fence), "3 submit");
    chk(vkWaitForFences(dev, 1, &fence, VK_TRUE, UINT64_MAX), "3 fence");
    vkResetFences(dev, 1, &fence);
}

/* Faithful CTS memory.binding regular.suballocated reproduction:
 * ntargets DEVICE_LOCAL buffers allocated up-front and bound with
 * vkBindBufferMemory2; a HOST_VISIBLE src is filled once, then per
 * target src->target and target->dst are SEPARATE submits and dst is
 * verified after each (like checkData).  This exercises device-local
 * persistence across submissions and multi-allocation addressing,
 * which the single-buffer roundtrip2 does not. */
static int roundtrip3(VkDevice dev, VkQueue q, VkFence fence,
                      VkCommandBuffer cb, VkBufferUsageFlags usage,
                      uint32_t mt_host, uint32_t mt_dev,
                      VkDeviceSize size, int ntargets)
{
    struct bufmem src = {0}, dst = {0};
    VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, NULL, 0,
                              size, usage, VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
    VkMemoryRequirements mr;

    /* src: host-visible */
    chk(vkCreateBuffer(dev, &bci, NULL, &src.buf), "3 create src");
    vkGetBufferMemoryRequirements(dev, src.buf, &mr);
    VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                NULL, mr.size, mt_host};
    if (!(mr.memoryTypeBits & (1u << mt_host)))
        mai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
    chk(vkAllocateMemory(dev, &mai, NULL, &src.mem), "3 alloc src");
    chk(vkBindBufferMemory(dev, src.buf, src.mem, 0), "3 bind src");

    /* dst: host-visible */
    chk(vkCreateBuffer(dev, &bci, NULL, &dst.buf), "3 create dst");
    vkGetBufferMemoryRequirements(dev, dst.buf, &mr);
    mai.allocationSize = mr.size;
    chk(vkAllocateMemory(dev, &mai, NULL, &dst.mem), "3 alloc dst");
    chk(vkBindBufferMemory(dev, dst.buf, dst.mem, 0), "3 bind dst");

    /* fill src with the pattern (host write + flush) */
    void *p;
    chk(vkMapMemory(dev, src.mem, 0, mr.size, 0, &p), "3 map src");
    uint8_t *w = p;
    for (VkDeviceSize i = 0; i < mr.size; i++) w[i] = pat(i);
    VkMappedMemoryRange rng = {VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                               NULL, src.mem, 0, mr.size};
    vkFlushMappedMemoryRanges(dev, 1, &rng);

    /* ntargets device-local buffers + memories, bound via bindBufferMemory2 */
    VkBuffer *tb = calloc(ntargets, sizeof(VkBuffer));
    VkDeviceMemory *tm = calloc(ntargets, sizeof(VkDeviceMemory));
    VkBindBufferMemoryInfo *binds = calloc(ntargets, sizeof(*binds));
    int nbad_total = 0;
    for (int i = 0; i < ntargets; i++) {
        chk(vkCreateBuffer(dev, &bci, NULL, &tb[i]), "3 create tgt");
        vkGetBufferMemoryRequirements(dev, tb[i], &mr);
        VkMemoryAllocateInfo tmai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                     NULL, mr.size, mt_dev};
        if (!(mr.memoryTypeBits & (1u << mt_dev)))
            tmai.memoryTypeIndex = __builtin_ctz(mr.memoryTypeBits);
        chk(vkAllocateMemory(dev, &tmai, NULL, &tm[i]), "3 alloc tgt");
        binds[i].sType = VK_STRUCTURE_TYPE_BIND_BUFFER_MEMORY_INFO;
        binds[i].buffer = tb[i];
        binds[i].memory = tm[i];
        binds[i].memoryOffset = 0;
    }
    chk(vkBindBufferMemory2(dev, ntargets, binds), "3 bindBufferMemory2");

    for (int i = 0; i < ntargets; i++) {
        do_copy_submit(dev, q, fence, cb, src.buf, tb[i], size);   /* fill */
        do_copy_submit(dev, q, fence, cb, tb[i], dst.buf, size);   /* read  */

        chk(vkMapMemory(dev, dst.mem, 0, mr.size, 0, &p), "3 map dst");
        rng.memory = dst.mem; rng.size = mr.size;
        vkInvalidateMappedMemoryRanges(dev, 1, &rng);
        w = p;
        VkDeviceSize bad = (VkDeviceSize)-1;
        uint64_t nbad = 0;
        for (VkDeviceSize k = 0; k < size; k++) {
            if (w[k] != pat(k)) { if (bad == (VkDeviceSize)-1) bad = k; nbad++; }
        }
        printf("  tgt%02d: %s", i, nbad ? "FAIL" : "PASS");
        if (nbad) {
            printf(" bad=%llu first@0x%llx got=%02x exp=%02x",
                   (unsigned long long)nbad, (unsigned long long)bad,
                   w[bad], pat(bad));
            nbad_total += (int)nbad;
        }
        printf("\n");
        vkUnmapMemory(dev, dst.mem);
    }

    vkUnmapMemory(dev, src.mem);
    for (int i = 0; i < ntargets; i++) {
        vkDestroyBuffer(dev, tb[i], NULL); vkFreeMemory(dev, tm[i], NULL);
    }
    free(tb); free(tm); free(binds);
    vkDestroyBuffer(dev, src.buf, NULL); vkFreeMemory(dev, src.mem, NULL);
    vkDestroyBuffer(dev, dst.buf, NULL); vkFreeMemory(dev, dst.mem, NULL);
    printf("  xdom_cts size=%llu ntargets=%d: %s\n",
           (unsigned long long)size, ntargets,
           nbad_total ? "FAIL" : "PASS");
    return nbad_total ? 1 : 0;
}

int main(void)
{
    setenv("VN_PERF", "no_async_mem_alloc", 1);

    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "vkmembig", 0, "vkmembig", 0,
                            VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                NULL, 0, &ai, 0, NULL, 0, NULL};
    VkInstance inst;
    chk(vkCreateInstance(&ici, NULL, &inst), "vkCreateInstance");

    uint32_t npdev = 0;
    chk(vkEnumeratePhysicalDevices(inst, &npdev, NULL), "enum phys");
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
    VkCommandPoolCreateInfo cpci = {
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, 0};
    VkCommandPool cpool;
    chk(vkCreateCommandPool(dev, &cpci, NULL, &cpool), "cmdpool");
    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, cpool,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    chk(vkAllocateCommandBuffers(dev, &cbai, &cb), "cmdbuf");
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, 0};
    VkFence fence;
    chk(vkCreateFence(dev, &fci, NULL, &fence), "fence");

    const VkBufferUsageFlags usage =
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    int fails = 0;

    /* CTS-faithful cross-domain tests FIRST — the host-vis ladder's
     * large copies can hit a virtio ring fatal error and abort before
     * reaching these, so the decisive CTS path must run early. */
    if (mt_dev != UINT32_MAX) {
        /* single device-local buffer, combined CB two-hop */
        const VkDeviceSize xsizes[] = {
            4096, 65536, 1024*1024, 1024*1024+1, 1024*1024+4096,
            2*1024*1024,
        };
        printf("cross-domain two-hop (type%u -> type%u -> type%u):\n",
               mt_host, mt_dev, mt_host);
        for (uint32_t s = 0; s < sizeof(xsizes)/sizeof(xsizes[0]); s++) {
            printf("size %llu:\n", (unsigned long long)xsizes[s]);
            fails += roundtrip2(dev, q, fence, cb, usage, mt_host,
                                mt_dev, xsizes[s]);
        }
        /* CTS-faithful: 10 dev-local targets, bindBufferMemory2,
         * separate submits per copy direction.  Focus on the CTS
         * size and just below/above the 1 MiB boundary. */
        const VkDeviceSize csizes[] = {
            1024*1024, 1024*1024+1, 1024*1024+4096,
        };
        for (uint32_t s = 0; s < sizeof(csizes)/sizeof(csizes[0]); s++) {
            printf("size %llu:\n", (unsigned long long)csizes[s]);
            fails += roundtrip3(dev, q, fence, cb, usage, mt_host,
                                mt_dev, csizes[s], /*ntargets=*/10);
        }
    } else {
        printf("no pure device-local type — skipping cross-domain\n");
    }

    /* host-vis->host-vis ladder (baseline; large copies may hit the
     * virtio ring fatal error seen at 8 MiB — run last). */
    const VkDeviceSize sizes[] = {
        33, 257, 4096, 65536,
        1024*1024, 1024*1024+1, 1024*1024+4096,
        2*1024*1024, 4*1024*1024,
    };
    for (uint32_t s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++) {
        printf("size %llu:\n", (unsigned long long)sizes[s]);
        fails += roundtrip(dev, q, fence, cb, usage, mt_host,
                           sizes[s], /*do_copy=*/0);
        fails += roundtrip(dev, q, fence, cb, usage, mt_host,
                           sizes[s], /*do_copy=*/1);
    }
    vkDestroyFence(dev, fence, NULL);
    vkFreeCommandBuffers(dev, cpool, 1, &cb);
    vkDestroyCommandPool(dev, cpool, NULL);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(inst, NULL);
    if (fails) { printf("G6LC_VKMEMBIG_FAIL fails=%d\n", fails); return 1; }
    printf("G6LC_VKMEMBIG_PASS\n");
    return 0;
}
