# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""vkCreateBufferView/vkDestroyBufferView golden-model coverage.

Drives FrontModel.step through the generated VnDec ROM for type 52/53:
buffer bound-extent resolution, VK_WHOLE_SIZE, format/geometry refusal
and kind-agnostic retire.  The RTL StBufVwCk mirror lands separately —
these vectors define the behaviour it must match.
"""
import random
import sys
import tomllib
import unittest
from pathlib import Path

_TOOLS = Path(__file__).resolve().parent
for _p in (str(_TOOLS), str(_TOOLS / 'shader')):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import vn_golden as V
import vkxml
VK_OK = 0
VK_ERR_UNKNOWN = 0xFFFFFFF3
VK_ERR_FMTNS = 0xFFFFFFF5
WHOLE = 0xFFFFFFFFFFFFFFFF


class _Wire:
    """Minimal session: one device, one bound buffer, one unbound."""

    @classmethod
    def build(cls):
        profile = tomllib.loads(
            (_TOOLS / 'vn_device_profile.toml').read_text(encoding='utf-8'))
        m = V.G.Model(profile)
        m.run(m.read_command_set(_TOOLS / 'vn_command_set.txt'))
        model, asm = V.build_assembly(m)
        w = cls()
        w.m, w.model, w.asm = m, model, asm
        w.sim, w.enc = V.Sim(model, asm), V.Enc(model)
        w.rng = random.Random(1)
        w.gen = V.ArgGen(model, w.rng)
        w.rep_sim = V.ReplySim(model, asm)
        w.fm = V.FrontModel(model, asm)
        w.T = {n: i['type_id'] for n, i in m.cmd_info.items()}
        for t in m.reg.type_table.values():
            if t.category == vkxml.VkType.HANDLE:
                V.KIND[t.name] = m.kind(t.name)
        w.ses = {'T': w.T}
        w._nid = [0x1000_0000_0000]
        w._setup()
        return w

    def _newid(self):
        self._nid[0] += 0x1000_0001
        return self._nid[0]

    def struct(self, ty, **kw):
        d = self.gen.gen_struct(self.m.reg.type_table[ty])
        d.update(kw)
        return d

    def cmd(self, name, **over):
        ty = next(t for t in
                  self.m.gen.supported_types[vkxml.VkType.COMMAND]
                  if t.name == name)
        a = self.gen.gen_command(name)
        a.update(over)
        if self.m.cmd_info[name]['act']['flags'] & 1:
            a['_flags'] = 1
        words = self.enc.command(ty, a)
        rec = self.sim.run(words)
        return self.fm.step(name, ty, words, rec, self.rep_sim, self.ses)

    def _setup(self):
        P = {k: self._newid() for k in
             ('inst', 'pd', 'dev', 'mem', 'buf', 'buf2')}
        self.P = P
        self.cmd('vkCreateInstance', pInstance=P['inst'])
        self.cmd('vkEnumeratePhysicalDevices', instance=P['inst'],
                 pPhysicalDeviceCount=1, pPhysicalDevices=[P['pd']])
        self.cmd('vkCreateDevice', physicalDevice=P['pd'],
                 pCreateInfo=self.struct('VkDeviceCreateInfo'),
                 pDevice=P['dev'])
        self.cmd('vkAllocateMemory', device=P['dev'],
                 pAllocateInfo=self.struct(
                     'VkMemoryAllocateInfo', allocationSize=0x10000,
                     memoryTypeIndex=1, pNext=[]),
                 pMemory=P['mem'])
        for tag in ('buf', 'buf2'):
            self.cmd('vkCreateBuffer', device=P['dev'],
                     pCreateInfo=self.struct(
                         'VkBufferCreateInfo', size=0x8000, usage=0x61,
                         sharingMode=0, queueFamilyIndexCount=0,
                         pQueueFamilyIndices=[]),
                     pBuffer=P[tag])
        self.cmd('vkBindBufferMemory', device=P['dev'], buffer=P['buf'],
                 memory=P['mem'], memoryOffset=0)
        # descriptor set with one UNIFORM_TEXEL_BUFFER(4) binding so the
        # pTexelBufferView staging path is exercised
        P.update({k: self._newid() for k in ('dsl', 'pool', 'dset')})
        self.P = P
        self.cmd('vkCreateDescriptorSetLayout', device=P['dev'],
                 pCreateInfo=self.struct(
                     'VkDescriptorSetLayoutCreateInfo', flags=0,
                     bindingCount=1,
                     pBindings=[self.struct(
                         'VkDescriptorSetLayoutBinding', binding=0,
                         descriptorType=4, descriptorCount=1,
                         stageFlags=0x20, pImmutableSamplers=[])]),
                 pSetLayout=P['dsl'])
        self.cmd('vkCreateDescriptorPool', device=P['dev'],
                 pCreateInfo=self.struct(
                     'VkDescriptorPoolCreateInfo', flags=0, maxSets=1,
                     poolSizeCount=1,
                     pPoolSizes=[self.struct('VkDescriptorPoolSize',
                                             type=4, descriptorCount=1)]),
                 pDescriptorPool=P['pool'])
        self.cmd('vkAllocateDescriptorSets', device=P['dev'],
                 pAllocateInfo=self.struct(
                     'VkDescriptorSetAllocateInfo',
                     descriptorPool=P['pool'], descriptorSetCount=1,
                     pSetLayouts=[P['dsl']]),
                 pDescriptorSets=[P['dset']])

    def bv(self, buf, fmt, off, rng):
        view = self._newid()
        out = self.cmd('vkCreateBufferView', device=self.P['dev'],
                       pCreateInfo=self.struct(
                           'VkBufferViewCreateInfo', buffer=buf,
                           format=fmt, offset=off, range=rng),
                       pView=view)
        return out, view

    def view_ent(self, view):
        slot = self.fm.idmap.get(view)
        return self.fm.ent[slot] if slot is not None else None


class BufferViewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.w = _Wire.build()

    def test_whole_size_resolves_to_bound_extent(self):
        out, view = self.w.bv(self.w.P['buf'], 37, 0, WHOLE)
        self.assertEqual(out['result'], VK_OK)
        e = self.w.view_ent(view)
        self.assertEqual(e['size'] & 0xFFFFFFFF, 0)          # offset
        self.assertEqual((e['size'] >> 32) & 0xFFFFFFFF, 0x8000)  # range

    def test_explicit_offset_and_range(self):
        out, view = self.w.bv(self.w.P['buf'], 37, 256, 512)
        self.assertEqual(out['result'], VK_OK)
        e = self.w.view_ent(view)
        self.assertEqual(e['size'] & 0xFFFFFFFF, 256)
        self.assertEqual((e['size'] >> 32) & 0xFFFFFFFF, 512)

    def test_range_past_buffer_refused(self):
        out, _ = self.w.bv(self.w.P['buf'], 37, 0, 0x9000)
        self.assertEqual(out['result'], VK_ERR_FMTNS)

    def test_offset_plus_range_escapes_refused(self):
        out, _ = self.w.bv(self.w.P['buf'], 37, 0x7F00, 0x200)
        self.assertEqual(out['result'], VK_ERR_FMTNS)

    def test_unsupported_format_refused(self):
        out, _ = self.w.bv(self.w.P['buf'], 0, 0, 0x100)
        self.assertEqual(out['result'], VK_ERR_FMTNS)

    def test_unbound_buffer_refused(self):
        out, _ = self.w.bv(self.w.P['buf2'], 37, 0, 0x100)
        self.assertEqual(out['result'], VK_ERR_UNKNOWN)

    def test_unaligned_offset_refused(self):
        out, _ = self.w.bv(self.w.P['buf'], 37, 2, 0x100)
        self.assertEqual(out['result'], VK_ERR_FMTNS)

    def test_zero_range_refused(self):
        out, _ = self.w.bv(self.w.P['buf'], 37, 0, 0)
        self.assertEqual(out['result'], VK_ERR_FMTNS)

    def _texel_write(self, view, dtype=4):
        return self.w.cmd('vkUpdateDescriptorSets', device=self.w.P['dev'],
                          descriptorWriteCount=1, descriptorCopyCount=0,
                          pDescriptorCopies=[],
                          pDescriptorWrites=[self.w.struct(
                              'VkWriteDescriptorSet', pNext=[],
                              dstSet=self.w.P['dset'], dstBinding=0,
                              dstArrayElement=0, descriptorCount=1,
                              descriptorType=dtype, pImageInfo=[],
                              pTexelBufferView=[view], pBufferInfo=[])])

    def _record(self, out):
        """-> {byte_offset: value} of the 32-byte descriptor record.
        The lowest aperture write is the record base (word0); each field's
        key is its byte offset within the record (0,4,8,12,...,28)."""
        base = min(a for a, _ in out['apw'])
        return {a - base: w & 0xFFFFFFFF for a, w in out['apw']}

    def test_texel_descriptor_record_uniform(self):
        out, view = self.w.bv(self.w.P['buf'], 37, 0, WHOLE)
        self.assertEqual(out['result'], VK_OK)
        w = self._texel_write(view, dtype=4)
        self.assertEqual(w['result'], VK_OK)
        rec = self._record(w)
        # word0 mem handle {gen,slot}, word1 extent, word2
        # (elok<<8)|dtype=4, word3 texdid=fmt, word7 byte offset
        self.assertEqual(rec[8] & 0xFF, 4)            # dtype UNIFORM_TEXEL
        self.assertEqual(rec[8] >> 8, 1)              # elok
        self.assertNotEqual(rec[0], 0)                # bound mem handle
        self.assertEqual(rec[4], 0x8000)              # view range
        self.assertEqual(rec[28], 0)                  # byte offset
        self.assertNotEqual(rec[12], 0)               # texdid present

    def test_texel_descriptor_record_offset(self):
        out, view = self.w.bv(self.w.P['buf'], 37, 256, 512)
        self.assertEqual(out['result'], VK_OK)
        w = self._texel_write(view, dtype=4)
        self.assertEqual(w['result'], VK_OK)
        rec = self._record(w)
        self.assertEqual(rec[4], 512)                 # range
        self.assertEqual(rec[28], 256)                # bind_off+view_off

    def test_texel_descriptor_bad_view_refused(self):
        # an unresolvable view handle stages a poisoned (dead) record
        w = self._texel_write(self.w._newid(), dtype=4)
        rec = self._record(w)
        self.assertEqual(rec.get(8, 0) & 0xFF, 4)      # dtype still written
        self.assertEqual(rec.get(8, 0) >> 8, 0)        # elok clear

    def test_destroy_retires_view(self):
        out, view = self.w.bv(self.w.P['buf'], 37, 0, 0x100)
        self.assertEqual(out['result'], VK_OK)
        slot = self.w.fm.idmap.get(view)
        self.assertIsNotNone(self.w.fm.ent[slot])
        out = self.w.cmd('vkDestroyBufferView', device=self.w.P['dev'],
                         bufferView=view)
        self.assertEqual(out['result'], VK_OK)
        self.assertIsNone(self.w.fm.ent[slot])


if __name__ == '__main__':
    unittest.main()
