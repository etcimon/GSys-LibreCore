# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Original-wire fixed state must not inherit silent legacy truncation/omission."""
import unittest
from unittest.mock import patch

import test_vn_graphics_pipelines as graphics_fixture
from vn_native_execution import StreamFault


class GraphicsStateTests(unittest.TestCase):
    def setUp(self):
        self.g = graphics_fixture.GraphicsPipelineTests()
        self.g.setUp()

    def pipeline(self, edits=None):
        command = self.g.f.command

        def send(name, **kwargs):
            if name == 'vkCreateGraphicsPipelines':
                info = kwargs['pCreateInfos'][0]
                for key, value in (edits or {}).items():
                    if isinstance(value, dict):
                        info[key].update(value)
                    else:
                        info[key] = value
            return command(name, **kwargs)

        with patch.object(self.g.f, 'command', side_effect=send):
            return self.g.pipeline()

    def refuses(self, edits):
        case = GraphicsStateTests()
        case.setUp()
        with self.assertRaisesRegex(StreamFault, 'graphics fixed'):
            case.pipeline(edits)
        self.assertNotIn(case.g.PIPE, case.g.f.front.idmap)
        self.assertEqual((case.g.f.entry(case.g.VS)['pins'], case.g.f.entry(case.g.FS)['pins']),
                         (0, 0))
        self.assertEqual(case.g.f.owner.work_refs, 0)

    def vertex(self, bindings=((3, 16, 1),), attributes=((0, 3, 103, 4),)):
        s = self.g.w.structure
        return dict(vertexBindingDescriptionCount=len(bindings),
            pVertexBindingDescriptions=[s('VkVertexInputBindingDescription',
                binding=binding, stride=stride, inputRate=rate) for binding, stride, rate in bindings],
            vertexAttributeDescriptionCount=len(attributes),
            pVertexAttributeDescriptions=[s('VkVertexInputAttributeDescription',
                location=location, binding=binding, format=fmt, offset=offset)
                for location, binding, fmt, offset in attributes])

    def test_baseline_state_is_typed_without_work(self):
        snapshot = self.pipeline()
        self.assertEqual(snapshot.fixed.bindings, ())
        self.assertEqual(snapshot.fixed.attributes, ())
        self.assertEqual((snapshot.fixed.cull, snapshot.fixed.front_face), (0, 0))
        self.assertEqual(snapshot.fixed.color_masks, (15,))
        self.assertEqual(snapshot.fixed.dynamic, (0, 1))
        self.assertFalse(self.g.e.transfers.active)

    def test_vertex_rows_retain_binding_rate_format_and_offset(self):
        snapshot = self.pipeline({'pVertexInputState': self.vertex()})
        self.assertEqual(snapshot.fixed.bindings, ((3, 16, 1),))
        self.assertEqual(snapshot.fixed.attributes, ((0, 3, 103, 4),))

    def test_cull_front_face_and_dynamic_order_are_preserved(self):
        snapshot = self.pipeline({'pRasterizationState': dict(cullMode=3, frontFace=1),
            'pDynamicState': dict(pDynamicStates=[1, 0])})
        self.assertEqual((snapshot.fixed.cull, snapshot.fixed.front_face), (3, 1))
        self.assertEqual(snapshot.fixed.dynamic, (0, 1))

    def test_ignored_multisample_fields_are_not_silently_supported(self):
        for values in (dict(rasterizationSamples=2), dict(sampleShadingEnable=1),
                       dict(pSampleMask=[0]), dict(alphaToCoverageEnable=1),
                       dict(alphaToOneEnable=1)):
            with self.subTest(values=values):
                self.refuses({'pMultisampleState': values})

    def test_raster_and_topology_outside_profile_fail_before_pins(self):
        for values in (dict(depthClampEnable=1), dict(rasterizerDiscardEnable=1),
                       dict(polygonMode=1), dict(depthBiasEnable=1),
                       dict(lineWidth=0x40000000), dict(cullMode=4), dict(frontFace=2)):
            with self.subTest(values=values):
                self.refuses({'pRasterizationState': values})
        self.refuses({'pInputAssemblyState': dict(topology=1)})
        self.refuses({'pInputAssemblyState': dict(primitiveRestartEnable=1)})

    def test_dynamic_state_counts_duplicates_and_unknowns_fail(self):
        for states in ([0, 0], [0, 2], [], [0, 1, 4]):
            with self.subTest(states=states):
                self.refuses({'pDynamicState': dict(dynamicStateCount=len(states),
                                                   pDynamicStates=states)})
        self.refuses({'pViewportState': None})

    def test_logic_blend_and_color_count_require_explicit_profile(self):
        self.refuses({'pColorBlendState': dict(logicOpEnable=1)})
        state = self.g.w.structure('VkPipelineColorBlendAttachmentState',
            blendEnable=1, srcColorBlendFactor=1, dstColorBlendFactor=0, colorBlendOp=0,
            srcAlphaBlendFactor=1, dstAlphaBlendFactor=0, alphaBlendOp=0, colorWriteMask=15)
        self.refuses({'pColorBlendState': dict(pAttachments=[state])})
        self.refuses({'pColorBlendState': dict(attachmentCount=0, pAttachments=[])})

    def test_vertex_rows_cannot_truncate_or_alias(self):
        cases = [
            self.vertex(bindings=((3, 2049, 0),)),
            self.vertex(bindings=((3, 65536, 0),)),
            self.vertex(bindings=((3, 16, 2),)),
            self.vertex(bindings=((3, 16, 0), (3, 16, 1))),
            self.vertex(attributes=((0, 4, 103, 0),)),
            self.vertex(attributes=((0, 3, 103, 2048),)),
            self.vertex(attributes=((8, 3, 103, 0),)),
            self.vertex(attributes=((0, 3, 0, 0),)),
            self.vertex(attributes=((0, 3, 103, 0), (0, 3, 103, 4))),
        ]
        for index, state in enumerate(cases):
            with self.subTest(index=index):
                self.refuses({'pVertexInputState': state})


if __name__ == '__main__':
    unittest.main()
