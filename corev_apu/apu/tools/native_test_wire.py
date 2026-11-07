# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Small deterministic Venus-wire fixture shared by native host tests."""
import random
import struct

from vn_native_execution import load_decoder


class NativeWire:
    INSTANCE = 0x400000001000
    PHYSICAL = 0x400010001001
    DEVICE = 0x400020001002
    MEMORY = 0x400030001003

    def __init__(self, native_timeline=False):
        self.golden, self.model, _ = load_decoder(native_timeline)
        self.generator = self.golden.ArgGen(self.model, random.Random(17))
        self.types = {ty.name: ty for ty in
                      self.model.gen.supported_types[self.golden.vkxml.VkType.COMMAND]}
        self.encoder = self.golden.Enc(self.model)

    def command(self, name, **kwargs):
        args = self.generator.gen_command(name)
        args.update(kwargs)
        if self.model.cmd_info[name]['act']['flags'] & 1:
            args['_flags'] = 1
        words = self.encoder.command(self.types[name], args)
        return struct.pack('<%dI' % len(words), *words)

    def structure(self, name, **kwargs):
        result = self.generator.gen_struct(self.model.reg.type_table[name])
        result.update(kwargs)
        return result

    def reply(self, resource=7, size=4096):
        return self.command('vkSetReplyCommandStreamMESA',
                            pStream={'_ty': None, 'resourceId': resource,
                                     'offset': 0, 'size': size})

    def allocate(self, size=5001, memory_type=1):
        return self.command(
            'vkAllocateMemory', device=self.DEVICE,
            pAllocateInfo=self.structure('VkMemoryAllocateInfo', pNext=[],
                                         allocationSize=size, memoryTypeIndex=memory_type),
            pMemory=self.MEMORY)

    def boot(self, size=5001, memory_type=1):
        return (self.reply() +
                self.command('vkCreateInstance', pInstance=self.INSTANCE) +
                self.command('vkEnumeratePhysicalDevices', instance=self.INSTANCE,
                             pPhysicalDeviceCount=1, pPhysicalDevices=[self.PHYSICAL]) +
                self.command(
                    'vkCreateDevice', physicalDevice=self.PHYSICAL,
                    pCreateInfo=self.structure(
                        'VkDeviceCreateInfo', pNext=[], queueCreateInfoCount=1,
                        pQueueCreateInfos=[self.structure(
                            'VkDeviceQueueCreateInfo', pNext=[], queueFamilyIndex=0,
                            queueCount=1, pQueuePriorities=[0x3F800000])],
                        pEnabledFeatures=None, enabledExtensionCount=0,
                        ppEnabledExtensionNames=[], enabledLayerCount=0,
                        ppEnabledLayerNames=[]), pDevice=self.DEVICE) +
                self.allocate(size, memory_type))

    def free(self):
        return self.command('vkFreeMemory', device=self.DEVICE, memory=self.MEMORY)

    def transfer_commands(self, buffer, pool, cb, queue, fence):
        commands = [
            self.command('vkCreateBuffer', device=self.DEVICE, pBuffer=buffer,
                         pCreateInfo=self.structure('VkBufferCreateInfo', pNext=[],
                             flags=0, size=4096, usage=3, sharingMode=0,
                             queueFamilyIndexCount=0, pQueueFamilyIndices=[])),
            self.command('vkBindBufferMemory', device=self.DEVICE, buffer=buffer,
                         memory=self.MEMORY, memoryOffset=0),
            self.command('vkCreateCommandPool', device=self.DEVICE, pCommandPool=pool,
                         pCreateInfo=self.structure('VkCommandPoolCreateInfo',
                                                   pNext=[], flags=2, queueFamilyIndex=0)),
            self.command('vkAllocateCommandBuffers', device=self.DEVICE,
                         pCommandBuffers=[cb], pAllocateInfo=self.structure(
                             'VkCommandBufferAllocateInfo', pNext=[], commandPool=pool,
                             level=0, commandBufferCount=1)),
            self.command('vkBeginCommandBuffer', commandBuffer=cb,
                         pBeginInfo=self.structure('VkCommandBufferBeginInfo',
                             pNext=[], flags=0, pInheritanceInfo=None))]
        barrier = self.command('vkCmdPipelineBarrier', commandBuffer=cb,
            srcStageMask=0x1000, dstStageMask=0x4000, dependencyFlags=0,
            memoryBarrierCount=1, pMemoryBarriers=[self.structure('VkMemoryBarrier',
                pNext=[], srcAccessMask=0x1000, dstAccessMask=0x4000)],
            bufferMemoryBarrierCount=0, pBufferMemoryBarriers=[],
            imageMemoryBarrierCount=0, pImageMemoryBarriers=[])
        commands += [
            barrier,
            self.command('vkCmdFillBuffer', commandBuffer=cb, dstBuffer=buffer,
                         dstOffset=0, size=4096, data=0x64636261),
            barrier, self.command('vkEndCommandBuffer', commandBuffer=cb),
            self.command('vkGetDeviceQueue', device=self.DEVICE,
                         queueFamilyIndex=0, queueIndex=0, pQueue=queue),
            self.command('vkCreateFence', device=self.DEVICE, pFence=fence,
                         pCreateInfo=self.structure('VkFenceCreateInfo', pNext=[], flags=0))]
        return b''.join(commands)

    def create_ring(self, handle=0x100, resource=8, **kwargs):
        values = dict(pNext=[], flags=0, resourceId=resource, offset=0, size=4096,
                      idleTimeout=1000000, headOffset=0, tailOffset=64, statusOffset=128,
                      bufferOffset=192, bufferSize=2048, extraOffset=2240, extraSize=64)
        values.update(kwargs)
        return self.command('vkCreateRingMESA', ring=handle,
                            pCreateInfo=self.structure('VkRingCreateInfoMESA', **values))
