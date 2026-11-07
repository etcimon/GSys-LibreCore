# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Graphics resource requirements must fit retained layouts before allocation."""
import unittest

import test_vn_graphics_pipelines as graphics_fixture
from vn_native_execution import StreamFault


def resource_program(em, *, storage=2, count=1, descriptor_set=0, binding=0,
                     decorated=True, image_kind=None, push_offsets=(0,), vector=False,
                     legacy=False, second_binding=None, spec=False, push_array=False,
                     block_decoration=2):
    original = graphics_fixture.stage_program(em)
    result, position = list(original[:5]), 5
    result[3] = 40
    if image_kind is not None:
        storage = 0

    def emit(op, *values):
        result.extend(((len(values) + 1) << 16 | op, *values))

    while position < len(original):
        length, opcode = original[position] >> 16, original[position] & 0xFFFF
        values = original[position + 1:position + length]
        position += length
        if opcode == 19:
            if storage != 9 and decorated:
                for identifier, slot in ((14, binding), (15, second_binding)):
                    if slot is not None:
                        emit(71, identifier, 34, descriptor_set)
                        emit(71, identifier, 33, slot)
            if image_kind is None:
                emit(71, 18, 3 if legacy else block_decoration)
                for i, offset in enumerate(push_offsets):
                    emit(72, 18, i, 35, offset)
            if spec:
                emit(71, 21, 1, 7)
        if opcode == 54:
            if count != 1 or push_array:
                emit(21, 20, 32, 0)
                emit(50 if spec else 43, 20, 21, count if not push_array else 2)
            if image_kind is not None:
                if image_kind == 0:
                    emit(26, 18)
                else:
                    emit(25, 17, 3, 1, 0, 0, 0, 2 if image_kind == 3 else 1, 0)
                    if image_kind == 1:
                        emit(27, 18, 17)
                element = 18 if image_kind in (0, 1) else 17
            else:
                member = 4 if vector else 3
                if push_array:
                    emit(28, 23, member, 21)
                    member = 23
                emit(30, 18, *([member] * len(push_offsets)))
                element = 18
                if count != 1 and not push_array:
                    emit(28 if count else 29, 22, 18, *([21] if count else []))
                    element = 22
            emit(32, 19, storage, element)
            emit(59, 19, 14, storage)
            if second_binding is not None:
                emit(59, 19, 15, storage)
        emit(opcode, *values)
    return tuple(result)


class ResourceTests(unittest.TestCase):
    DSL = 0x760000001000

    def setUp(self):
        self.g = graphics_fixture.GraphicsPipelineTests()
        self.g.setUp()
        self.f, self.e, self.w = self.g.f, self.g.e, self.g.w

    def layout(self, rows=(), push=()):
        self.f.command('vkDestroyPipelineLayout', device=self.w.DEVICE,
                       pipelineLayout=self.g.PL)
        if self.DSL in self.f.front.idmap:
            self.f.command('vkDestroyDescriptorSetLayout', device=self.w.DEVICE,
                           descriptorSetLayout=self.DSL)
        sets = []
        if rows:
            self.f.command('vkCreateDescriptorSetLayout', device=self.w.DEVICE, pSetLayout=self.DSL,
                pCreateInfo=self.w.structure('VkDescriptorSetLayoutCreateInfo', pNext=[], flags=0,
                    bindingCount=len(rows), pBindings=[self.w.structure(
                        'VkDescriptorSetLayoutBinding', binding=binding, descriptorType=kind,
                        descriptorCount=count, stageFlags=stages, pImmutableSamplers=[])
                        for binding, kind, count, stages in rows]))
            sets.append(self.DSL)
        self.f.command('vkCreatePipelineLayout', device=self.w.DEVICE, pPipelineLayout=self.g.PL,
            pCreateInfo=self.w.structure('VkPipelineLayoutCreateInfo', pNext=[], flags=0,
                setLayoutCount=len(sets), pSetLayouts=sets, pushConstantRangeCount=len(push),
                pPushConstantRanges=[self.w.structure('VkPushConstantRange',
                    stageFlags=stage, offset=offset, size=size) for stage, offset, size in push]))

    def module(self, em=0, **kwargs):
        handle = self.g.VS if em == 0 else self.g.FS
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=handle)
        code = resource_program(em, **kwargs)
        self.f.command('vkCreateShaderModule', device=self.w.DEVICE, pShaderModule=handle,
            pCreateInfo=self.w.structure('VkShaderModuleCreateInfo', pNext=[], flags=0,
                codeSize=len(code) * 4, pCode=list(code)))

    def refuses(self, rows, *, push=(), em=0, **kwargs):
        case = ResourceTests()
        case.setUp()
        case.layout(rows, push)
        case.module(em, **kwargs)
        with self.assertRaisesRegex(StreamFault, 'graphics resource'):
            case.g.pipeline()
        self.assertNotIn(case.g.PIPE, case.f.front.idmap)
        self.assertEqual((case.f.entry(case.g.VS)['pins'], case.f.entry(case.g.FS)['pins']), (0, 0))
        self.assertEqual(case.f.owner.work_refs, 0)

    def test_descriptor_free_stages_have_empty_requirements(self):
        snapshot = self.g.pipeline()
        self.assertEqual(tuple((r.stage, r.bindings, r.push_words) for r in snapshot.resources),
                         ((1, (), ()), (16, (), ())))

    def test_shared_uniform_binding_keeps_both_stage_requirements(self):
        self.layout(((0, 6, 1, 17),))
        self.module(0)
        self.module(4)
        snapshot = self.g.pipeline()
        self.assertEqual(tuple(r.stage for r in snapshot.resources), (1, 16))
        for stage in snapshot.resources:
            resource, = stage.bindings
            self.assertEqual((resource.descriptor_set, resource.binding, resource.kind,
                              resource.count, resource.layout_kind), (0, 0, 6, 1, 6))
        self.assertFalse(self.e.transfers.active)

    def test_fixed_buffer_arrays_keep_dynamic_layout_kind(self):
        for storage, kind in ((2, 8), (12, 9)):
            with self.subTest(storage=storage):
                case = ResourceTests()
                case.setUp()
                case.layout(((0, kind, 3, 1),))
                case.module(storage=storage, count=3)
                resource, = case.g.pipeline().resources[0].bindings
                self.assertEqual((resource.kind, resource.layout_kind, resource.count),
                                 (6 if storage == 2 else 7, kind, 3))

    def test_scalar_image_and_sampler_classes_match_layout(self):
        for kind in range(4):
            with self.subTest(kind=kind):
                case = ResourceTests()
                case.setUp()
                case.layout(((0, kind, 1, 16),))
                case.module(4, image_kind=kind)
                self.assertEqual(case.g.pipeline().resources[1].bindings[0].kind, kind)

    def test_wrong_type_count_visibility_binding_or_set_refuses(self):
        for rows, kwargs in ((((0, 7, 1, 1),), {}), (((0, 6, 1, 16),), {}),
                             (((0, 6, 1, 1),), dict(count=2)),
                             (((1, 6, 1, 1),), {}), (((0, 6, 1, 1),), dict(descriptor_set=1))):
            with self.subTest(rows=rows, kwargs=kwargs):
                self.refuses(rows, **kwargs)

    def test_missing_explicit_decorations_do_not_default_to_binding_zero(self):
        self.refuses(((0, 6, 1, 1),), decorated=False)

    def test_push_words_respect_nonzero_offsets_and_stage_coverage(self):
        self.layout(push=((17, 16, 16),))
        self.module(0, storage=9, push_offsets=(16,), vector=True)
        self.module(4, storage=9, push_offsets=(16,), vector=True)
        snapshot = self.g.pipeline()
        self.assertEqual(tuple(r.push_words for r in snapshot.resources), ((4, 5, 6, 7),) * 2)

    def test_push_gaps_do_not_require_undefined_padding_words(self):
        self.layout(push=((1, 0, 20),))
        self.module(storage=9, push_offsets=(0, 16))
        self.assertEqual(self.g.pipeline().resources[0].push_words, (0, 4))

    def test_push_missing_visibility_overlap_and_array_shapes_refuse(self):
        for push, kwargs in (((), {}), (((16, 0, 4),), {}),
                             (((1, 4, 4),), {}), (((1, 0, 16),), dict(push_offsets=(0, 0))),
                             (((1, 0, 16),), dict(push_array=True))):
            with self.subTest(push=push, kwargs=kwargs):
                self.refuses((), push=push, storage=9, **kwargs)

    def test_legacy_buffer_block_is_not_mistaken_for_uniform_buffer(self):
        self.layout(((0, 7, 1, 1),))
        self.module(legacy=True)
        self.assertEqual(self.g.pipeline().resources[0].bindings[0].kind, 7)
        self.refuses(((0, 6, 1, 1),), legacy=True)

    def test_stage_descriptor_element_budget_is_bounded(self):
        self.refuses(((0, 6, 16, 1), (1, 6, 16, 1)), count=16, second_binding=1)

    def test_runtime_descriptor_arrays_refuse(self):
        self.refuses(((0, 6, 1, 1),), count=0)

    def test_specialized_array_length_is_used_for_requirements(self):
        self.layout(((0, 6, 3, 1),))
        self.module(count=2, spec=True)
        snapshot = self.g.pipeline(vs_spec=self.g.spec(3))
        self.assertEqual(snapshot.resources[0].bindings[0].count, 3)

    def test_requirements_survive_layout_destruction_and_reuse(self):
        self.layout(((0, 6, 1, 1),))
        self.module()
        snapshot = self.g.pipeline()
        self.layout(((0, 7, 1, 16),))
        self.assertEqual(snapshot.resources[0].bindings[0].kind, 6)
        self.assertEqual(snapshot.layout.sets[0][1][0][1], 6)

    def test_equivalent_descriptor_aliases_share_one_requirement(self):
        self.layout(((0, 6, 2, 1),))
        self.module(count=2, second_binding=0)
        resources = self.g.pipeline().resources[0].bindings
        self.assertEqual(len(resources), 1)
        self.assertEqual(resources[0].count, 2)

    def test_packed_decoration_flag_alias_does_not_fabricate_block(self):
        self.refuses(((0, 6, 1, 1),), block_decoration=42)

    def test_push_word_extent_is_bounded_before_allocation(self):
        self.refuses((), push=((1, 0, 128),), storage=9, push_offsets=(128,))


if __name__ == '__main__':
    unittest.main()
