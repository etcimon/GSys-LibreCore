// SPDX-License-Identifier: MIT
// vk_compute_oracle — independent SPIR-V execution oracle for the
// ShaderCore increment-4a vectors (architecture doc 7a).  Runs a
// compute module on lavapipe (Mesa llvmpipe ICD, selected via
// VK_DRIVER_FILES) and writes back the post-dispatch buffer bytes.
//
// Usage:
//   vk_compute_oracle <module.spv> <desc.json> <out.bin>
//
// desc.json (produced by shader_vectors.py):
//   { "gx":N, "gy":N, "gz":N,
//     "push": [w0,w1,...],              // <=32 words, may be absent
//     "dyn_off": [o0,o1,...],           // pDynamicOffsets, may be absent
//     "bindings": [ {"set":0,"binding":0,"size":N,"init":"in0.bin",
//                    "idx":0,"dyn":0}, ...] }
// "idx" is the descriptor-array element; "dyn" selects
// STORAGE_BUFFER_DYNAMIC for that binding's set-layout row.
//
// Writes <out.bin>: for each binding in order, the buffer's `size`
// result bytes (raw, little-endian).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static void die(const char *m, VkResult r) {
    fprintf(stderr, "oracle: %s (VkResult %d)\n", m, r);
    exit(2);
}

/* --- minimal JSON scraping: the generator emits a fixed shape, so
 *   a permissive scanner is enough and avoids a dependency. ---------*/
static char *slurp(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); exit(2); }
    fseek(f, 0, SEEK_END); long s = ftell(f); rewind(f);
    char *b = malloc(s + 1);
    fread(b, 1, s, f); fclose(f); b[s] = 0;
    if (n) *n = (size_t)s;
    return b;
}

#define MAXBIND 16
#define MAXSET 4
struct bind { unsigned set, binding, size, idx, dyn; char init[512]; };
static unsigned gx = 1, gy = 1, gz = 1;
static unsigned pushw[32]; static int npush = 0;
static unsigned dynw[32]; static int ndyn = 0;
static struct bind binds[MAXBIND]; static int nbind = 0;

/* find "key":value inside [lo,hi) and return the numeric value, or
 * `dflt` when absent. */
static unsigned jnum(const char *lo, const char *hi, const char *key,
                     unsigned dflt) {
    char pat[64];
    snprintf(pat, sizeof(pat), "\"%s\"", key);
    const char *s = strstr(lo, pat);
    if (!s || (hi && s >= hi)) return dflt;
    const char *c = strchr(s + strlen(pat), ':');
    if (!c || (hi && c >= hi)) return dflt;
    return (unsigned)strtoul(c + 1, NULL, 0);
}

static void parse_desc(const char *txt) {
    gx = jnum(txt, NULL, "gx", 1);
    gy = jnum(txt, NULL, "gy", 1);
    gz = jnum(txt, NULL, "gz", 1);
    const char *q = strstr(txt, "\"push\"");
    if (q) {
        const char *a = strchr(q, '[');
        if (a) {
            a++;
            while (*a && *a != ']' && npush < 32) {
                while (*a == ' ' || *a == ',') a++;
                if (*a == ']') break;
                pushw[npush++] = strtoul(a, (char **)&a, 0);
            }
        }
    }
    const char *d = strstr(txt, "\"dyn_off\"");
    if (d) {
        const char *a = strchr(d, '[');
        if (a) {
            a++;
            while (*a && *a != ']' && ndyn < 32) {
                while (*a == ' ' || *a == ',') a++;
                if (*a == ']') break;
                dynw[ndyn++] = strtoul(a, (char **)&a, 0);
            }
        }
    }
    const char *b = strstr(txt, "\"bindings\"");
    if (!b) return;
    b = strchr(b, '['); if (!b) return;
    while (*b && nbind < MAXBIND) {
        const char *o = strchr(b, '{');
        if (!o) break;
        const char *e = strchr(o, '}');
        if (!e) break;
        struct bind *bd = &binds[nbind];
        bd->set = jnum(o, e, "set", 0);
        bd->binding = jnum(o, e, "binding", 0);
        bd->size = jnum(o, e, "size", 0);
        bd->idx = jnum(o, e, "idx", 0);
        bd->dyn = jnum(o, e, "dyn", 0);
        const char *s = strstr(o, "\"init\"");
        if (s && s < e) {
            const char *c = strchr(s + 6, ':');
            const char *q0 = c ? strchr(c, '"') : 0;
            const char *q1 = q0 ? strchr(q0 + 1, '"') : 0;
            if (q0 && q1 && q1 < e && (q1 - q0 - 1) < 500) {
                memcpy(bd->init, q0 + 1, q1 - q0 - 1);
                bd->init[q1 - q0 - 1] = 0;
            }
        }
        nbind++;
        b = e + 1;
    }
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s module.spv desc.json out.bin\n",
                argv[0]);
        return 2;
    }
    size_t spv_n;
    char *spv = slurp(argv[1], &spv_n);
    char *desc = slurp(argv[2], NULL);
    parse_desc(desc);

    VkResult r;
    VkApplicationInfo ai = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL,
                            "sh_oracle", 0, "sh", 0,
                            VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                                NULL, 0, &ai, 0, NULL, 0, NULL};
    VkInstance inst;
    if ((r = vkCreateInstance(&ici, NULL, &inst)) != VK_SUCCESS)
        die("vkCreateInstance", r);

    uint32_t npd = 0;
    vkEnumeratePhysicalDevices(inst, &npd, NULL);
    if (!npd) die("no physical devices", VK_ERROR_INITIALIZATION_FAILED);
    VkPhysicalDevice pds[16];
    if (npd > 16) npd = 16;
    vkEnumeratePhysicalDevices(inst, &npd, pds);
    VkPhysicalDevice pd = pds[0];

    VkPhysicalDeviceFeatures feat;
    vkGetPhysicalDeviceFeatures(pd, &feat);
    if (!feat.robustBufferAccess)
        fprintf(stderr, "oracle: robustBufferAccess not supported\n");

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {
        VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, 0, 1, &prio};
    VkPhysicalDeviceFeatures en = {0};
    en.robustBufferAccess = VK_TRUE;
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL,
                              0, 1, &qci, 0, NULL, 0, NULL, &en};
    VkDevice dev;
    if ((r = vkCreateDevice(pd, &dci, NULL, &dev)) != VK_SUCCESS)
        die("vkCreateDevice", r);
    VkQueue q;
    vkGetDeviceQueue(dev, 0, 0, &q);

    VkShaderModuleCreateInfo smi = {
        VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, NULL, 0,
        spv_n, (const uint32_t *)spv};
    VkShaderModule sm;
    if ((r = vkCreateShaderModule(dev, &smi, NULL, &sm)) != VK_SUCCESS)
        die("vkCreateShaderModule", r);

    /* unique sets in first-occurrence order -> one DSL per set; a
     * set-layout row's count is its binding's largest idx + 1. */
    unsigned sets[MAXSET]; int nsets = 0;
    for (int i = 0; i < nbind; i++) {
        int k;
        for (k = 0; k < nsets; k++)
            if (sets[k] == binds[i].set) break;
        if (k == nsets && nsets < MAXSET) sets[nsets++] = binds[i].set;
    }
    VkDescriptorSetLayout dsl[MAXSET];
    for (int s = 0; s < nsets; s++) {
        VkDescriptorSetLayoutBinding lbd[MAXBIND];
        int nl = 0;
        for (int i = 0; i < nbind; i++) {
            if (binds[i].set != sets[s]) continue;
            int k;
            for (k = 0; k < nl; k++)
                if (lbd[k].binding == binds[i].binding) break;
            unsigned cnt = binds[i].idx + 1;
            if (k < nl) {
                if (cnt > lbd[k].descriptorCount)
                    lbd[k].descriptorCount = cnt;
            } else {
                lbd[nl++] = (VkDescriptorSetLayoutBinding){
                    binds[i].binding,
                    binds[i].dyn
                        ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
                        : VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                    cnt, VK_SHADER_STAGE_COMPUTE_BIT, NULL};
            }
        }
        VkDescriptorSetLayoutCreateInfo dli = {
            VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            NULL, 0, nl, lbd};
        if ((r = vkCreateDescriptorSetLayout(dev, &dli, NULL,
                                             &dsl[s])) != VK_SUCCESS)
            die("vkCreateDescriptorSetLayout", r);
    }

    VkPushConstantRange pr = {VK_SHADER_STAGE_COMPUTE_BIT, 0,
                              npush * 4};
    VkPipelineLayoutCreateInfo pli = {
        VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, NULL, 0,
        nsets, dsl, npush ? 1 : 0, npush ? &pr : NULL};
    VkPipelineLayout pl;
    if ((r = vkCreatePipelineLayout(dev, &pli, NULL, &pl)) != VK_SUCCESS)
        die("vkCreatePipelineLayout", r);

    VkComputePipelineCreateInfo cpi = {
        VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, NULL, 0,
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
         VK_SHADER_STAGE_COMPUTE_BIT, sm, "main", NULL},
        pl, VK_NULL_HANDLE, 0};
    VkPipeline pipe;
    if ((r = vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpi,
                                    NULL, &pipe)) != VK_SUCCESS)
        die("vkCreateComputePipelines", r);

    /* pool covers every element of every row, both kinds */
    unsigned nstor = 0, ndynb = 0;
    for (int i = 0; i < nbind; i++) {
        if (binds[i].dyn) ndynb++;
        else nstor++;
    }
    VkDescriptorPoolSize ps[2];
    int nps = 0;
    if (nstor)
        ps[nps++] = (VkDescriptorPoolSize){
            VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, nstor};
    if (ndynb)
        ps[nps++] = (VkDescriptorPoolSize){
            VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, ndynb};
    VkDescriptorPoolCreateInfo dpi = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, NULL, 0,
        nsets, nps, ps};
    VkDescriptorPool dp;
    if ((r = vkCreateDescriptorPool(dev, &dpi, NULL, &dp)) != VK_SUCCESS)
        die("vkCreateDescriptorPool", r);
    VkDescriptorSetAllocateInfo dai = {
        VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, NULL, dp,
        nsets, dsl};
    VkDescriptorSet dsets[MAXSET];
    if ((r = vkAllocateDescriptorSets(dev, &dai, dsets)) != VK_SUCCESS)
        die("vkAllocateDescriptorSets", r);

    /* buffers + host-visible memory (one allocation per buffer) */
    VkBuffer buf[MAXBIND];
    VkDeviceMemory mem[MAXBIND];
    void *map[MAXBIND];
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (int i = 0; i < nbind; i++) {
        VkBufferCreateInfo bci = {VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                                  NULL, 0, binds[i].size,
                                  VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                                  VK_SHARING_MODE_EXCLUSIVE, 0, NULL};
        if ((r = vkCreateBuffer(dev, &bci, NULL, &buf[i])) != VK_SUCCESS)
            die("vkCreateBuffer", r);
        VkMemoryRequirements mr;
        vkGetBufferMemoryRequirements(dev, buf[i], &mr);
        uint32_t mt = UINT32_MAX;
        for (uint32_t t = 0; t < mp.memoryTypeCount; t++)
            if ((mr.memoryTypeBits & (1u << t)) &&
                (mp.memoryTypes[t].propertyFlags &
                 VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) ==
                    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) {
                mt = t;
                break;
            }
        if (mt == UINT32_MAX)
            die("no host-visible memory type",
                VK_ERROR_INITIALIZATION_FAILED);
        VkMemoryAllocateInfo mai = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                    NULL, mr.size, mt};
        if ((r = vkAllocateMemory(dev, &mai, NULL, &mem[i]))
            != VK_SUCCESS)
            die("vkAllocateMemory", r);
        vkBindBufferMemory(dev, buf[i], mem[i], 0);
        vkMapMemory(dev, mem[i], 0, binds[i].size, 0, &map[i]);
        if (binds[i].init[0]) {
            size_t n;
            char *init = slurp(binds[i].init, &n);
            memcpy(map[i], init, n < binds[i].size ? n : binds[i].size);
            free(init);
        } else {
            memset(map[i], 0, binds[i].size);
        }
        vkUnmapMemory(dev, mem[i]);

        unsigned dsidx = 0;
        for (int s = 0; s < nsets; s++)
            if (sets[s] == binds[i].set) dsidx = s;
        VkDescriptorBufferInfo dbi = {buf[i], 0, binds[i].size};
        VkWriteDescriptorSet wds = {
            VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, NULL, dsets[dsidx],
            binds[i].binding, binds[i].idx, 1,
            binds[i].dyn
                ? VK_DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC
                : VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            NULL, &dbi, NULL};
        vkUpdateDescriptorSets(dev, 1, &wds, 0, NULL);
    }

    VkCommandPoolCreateInfo cpci = {
        VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
        VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, 0};
    VkCommandPool cp;
    vkCreateCommandPool(dev, &cpci, NULL, &cp);
    VkCommandBufferAllocateInfo cbai = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, cp,
        VK_COMMAND_BUFFER_LEVEL_PRIMARY, 1};
    VkCommandBuffer cb;
    vkAllocateCommandBuffers(dev, &cbai, &cb);
    VkCommandBufferBeginInfo bbi = {
        VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
        VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
    vkBeginCommandBuffer(cb, &bbi);
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0,
                            nsets, dsets, ndyn, dynw);
    if (npush)
        vkCmdPushConstants(cb, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0,
                           npush * 4, pushw);
    vkCmdDispatch(cb, gx, gy, gz);
    vkEndCommandBuffer(cb);
    VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 0, NULL,
                       NULL, 1, &cb, 0, NULL};
    if ((r = vkQueueSubmit(q, 1, &si, VK_NULL_HANDLE)) != VK_SUCCESS)
        die("vkQueueSubmit", r);
    if ((r = vkQueueWaitIdle(q)) != VK_SUCCESS)
        die("vkQueueWaitIdle", r);

    FILE *out = fopen(argv[3], "wb");
    if (!out) { perror(argv[3]); return 2; }
    for (int i = 0; i < nbind; i++) {
        vkMapMemory(dev, mem[i], 0, binds[i].size, 0, &map[i]);
        fwrite(map[i], 1, binds[i].size, out);
        vkUnmapMemory(dev, mem[i]);
    }
    fclose(out);
    vkDeviceWaitIdle(dev);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(inst, NULL);
    return 0;
}
