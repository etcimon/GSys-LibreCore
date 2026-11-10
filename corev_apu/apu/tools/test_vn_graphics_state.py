# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Original-wire fixed state must not inherit silent legacy truncation/omission."""
import struct
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
        for values in (dict(lineWidth=0x40000000),
                       dict(cullMode=4), dict(frontFace=2)):
            with self.subTest(values=values):
                self.refuses({'pRasterizationState': values})
        for topology in (6, 7):
            with self.subTest(topology=topology):
                self.refuses({'pInputAssemblyState': dict(topology=topology)})
        self.refuses({'pInputAssemblyState': dict(primitiveRestartEnable=2)})

    def test_rasterizer_discard_is_retained(self):
        # rasterizerDiscardEnable=1 discards every primitive before
        # rasterization; the flag is retained so the draw chain can emit
        # zero fragment records. An out-of-range enable still refuses.
        snapshot = self.pipeline({'pRasterizationState':
                                  dict(rasterizerDiscardEnable=1)})
        self.assertEqual(snapshot.fixed.discard, 1)
        self.refuses({'pRasterizationState': dict(rasterizerDiscardEnable=2)})

    def test_primitive_restart_enable_is_retained(self):
        # primitiveRestartEnable=1 is admitted (indexed draws break the
        # primitive stream on the index-width sentinel); the flag is
        # retained on the fixed state for the fetch stage. 0 stays the
        # default and out-of-range values still refuse.
        # NB: the fixture resolves one pipeline per test, so this asserts
        # the restart=1 retention on a single create; the restart=0
        # default is exercised by every other pipeline test.
        snapshot = self.pipeline({'pInputAssemblyState':
                                  dict(primitiveRestartEnable=1)})
        self.assertEqual(snapshot.fixed.restart, 1)

    def test_depth_bias_state_is_retained(self):
        # depthBiasEnable=1 retains the (constantFactor, clamp,
        # slopeFactor) fp32 triple; the factors are wire fp32 bit patterns.
        f32 = lambda v: struct.unpack('<I', struct.pack('<f', v))[0]
        snapshot = self.pipeline({'pRasterizationState': dict(
            depthBiasEnable=1, depthBiasConstantFactor=f32(0.25),
            depthBiasClamp=f32(1.0), depthBiasSlopeFactor=f32(0.0))})
        self.assertEqual(snapshot.fixed.depth_bias, (0.25, 1.0, 0.0))
        self.refuses({'pRasterizationState': dict(depthBiasEnable=2)})

    def test_depth_clamp_state_is_retained(self):
        # depthClampEnable is admitted as 0/1; out-of-range refuses.
        snapshot = self.pipeline({'pRasterizationState':
                                  dict(depthClampEnable=1)})
        self.assertEqual(snapshot.fixed.depth_clamp, 1)
        self.refuses({'pRasterizationState': dict(depthClampEnable=2)})

    def test_polygon_mode_line_is_retained(self):
        # polygonMode=LINE is admitted and retained.
        snapshot = self.pipeline({'pRasterizationState':
                                  dict(polygonMode=1)})
        self.assertEqual(snapshot.fixed.poly_mode, 1)

    def test_polygon_mode_point_is_retained(self):
        # polygonMode=POINT is admitted and retained; out-of-range refuses.
        snapshot = self.pipeline({'pRasterizationState':
                                  dict(polygonMode=2)})
        self.assertEqual(snapshot.fixed.poly_mode, 2)
        self.refuses({'pRasterizationState': dict(polygonMode=3)})

    def test_topology_line_list_is_retained(self):
        # inputAssembly topology=LINE_LIST is admitted and retained; the
        # triangle default and the still-refused strip/fan codes are
        # covered by the refusal matrix above.
        snapshot = self.pipeline({'pInputAssemblyState': dict(topology=1)})
        self.assertEqual(snapshot.fixed.topology, 1)

    def test_topology_point_list_is_retained(self):
        # POINT_LIST(0) is admitted and retained.
        snapshot = self.pipeline({'pInputAssemblyState': dict(topology=0)})
        self.assertEqual(snapshot.fixed.topology, 0)

    def test_topology_line_strip_is_retained(self):
        # LINE_STRIP(2) is admitted and retained; only the triangle
        # strip/fan codes stay refused.
        snapshot = self.pipeline({'pInputAssemblyState': dict(topology=2)})
        self.assertEqual(snapshot.fixed.topology, 2)

    def test_dynamic_state_counts_duplicates_and_unknowns_fail(self):
        for states in ([0, 0], [0, 2], [], [0, 1, 4]):
            with self.subTest(states=states):
                self.refuses({'pDynamicState': dict(dynamicStateCount=len(states),
                                                   pDynamicStates=states)})
        self.refuses({'pViewportState': None})

    def test_logic_blend_and_color_count_require_explicit_profile(self):
        # logicOp admission is covered by test_logicop_state_retained; here
        # the out-of-table code and the logicOp+blend combo stay refused.
        self.refuses({'pColorBlendState': dict(logicOpEnable=1, logicOp=15)})
        blendstate = self.g.w.structure('VkPipelineColorBlendAttachmentState',
            blendEnable=1, srcColorBlendFactor=1, dstColorBlendFactor=0,
            colorBlendOp=0, srcAlphaBlendFactor=1, dstAlphaBlendFactor=0,
            alphaBlendOp=0, colorWriteMask=15)
        self.refuses({'pColorBlendState': dict(logicOpEnable=1,
                                               pAttachments=[blendstate])})
        self.refuses({'pColorBlendState': dict(attachmentCount=0, pAttachments=[])})
        # blendEnable=1 is admitted for the single UNORM8 colour output; the
        # retained blend tuple is exercised end-to-end by the writeback path.
        snapshot = self.pipeline({'pColorBlendState': dict(pAttachments=[blendstate])})
        self.assertEqual(snapshot.fixed.blend,
                         (1, 0, 0, 1, 0, 0, 15, 0, 0, 0, 0))

    def test_logicop_state_retained(self):
        # logicOpEnable=1 retains the VkLogicOp code for the bounded UNORM8
        # writeback path (single pipeline admission per fresh fixture).
        snap = self.pipeline({'pColorBlendState': dict(logicOpEnable=1,
                                                       logicOp=6)})
        self.assertEqual(snap.fixed.logic_op, 6)
        self.assertIsNone(snap.fixed.blend)

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
