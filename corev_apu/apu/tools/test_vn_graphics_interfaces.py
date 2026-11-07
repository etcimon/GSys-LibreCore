# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Specialized stage I/O must match declarations before pipeline allocation."""
import unittest

import test_vn_graphics_state as state_fixture
from test_vn_graphics_pipelines import stage_program
from vn_graphics_interfaces import FORMAT_KIND
from vn_native_execution import StreamFault


def interface_program(em, *, io=None, comps=4, duplicate=False, listed=True,
                      position=True, scalar_position=False, color=0, uint_color=False,
                      position_block=False):
    original = stage_program(em)
    result = list(original[:5])
    result[3] = 32

    def emit(op, *values):
        result.extend(((len(values) + 1) << 16 | op, *values))

    position_in_original = 5
    while position_in_original < len(original):
        count = original[position_in_original] >> 16
        op = original[position_in_original] & 0xFFFF
        values = list(original[position_in_original + 1:position_in_original + count])
        position_in_original += count
        if op == 15 and io is not None and listed:
            values.extend((14, 26) if duplicate else (14,))
        if op == 19:
            if io is not None:
                emit(71, 14, 30, 0)
                if duplicate:
                    emit(71, 26, 30, 0)
            if position_block:
                emit(71, 16, 2)
                emit(72, 16, 0, 11, 0)
        if op == 71 and values[0] == 6:
            if position_block:
                continue
            if em == 0 and not position:
                values = [6, 30, 0]
            elif em == 4:
                values[2] = color
        if op == 22 and uint_color:
            op, values = 21, [3, 32, 0]
        if op == 32 and values[0] == 5:
            if scalar_position:
                values[2] = 3
            if position_block:
                emit(30, 16, 4)
                values[2] = 16
        if op == 54:
            if io is not None:
                element = 4
                if comps != 4:
                    emit(23, 13, 3, comps)
                    element = 13
                emit(32, 12, io, element)
                emit(59, 12, 14, io)
                if duplicate:
                    emit(59, 12, 26, io)
            if position_block:
                emit(21, 17, 32, 0)
                emit(43, 17, 18, 0)
                emit(32, 19, 3, 4)
        if op == 62:
            if scalar_position:
                values[1] = 8
            if position_block:
                emit(65, 19, 20, 6, 18)
                values[0] = 20
        emit(op, *values)
    return tuple(result)


class GraphicsInterfaceTests(unittest.TestCase):
    def setUp(self):
        self.s = state_fixture.GraphicsStateTests()
        self.s.setUp()
        self.g = self.s.g

    def module(self, handle, code):
        self.g.f.command('vkDestroyShaderModule', device=self.g.w.DEVICE, shaderModule=handle)
        self.g.f.command('vkCreateShaderModule', device=self.g.w.DEVICE, pShaderModule=handle,
            pCreateInfo=self.g.w.structure('VkShaderModuleCreateInfo', pNext=[], flags=0,
                codeSize=len(code) * 4, pCode=list(code)))

    def refuses(self, vertex=None, fragment=None, edits=None):
        case = GraphicsInterfaceTests()
        case.setUp()
        if vertex is not None:
            case.module(case.g.VS, vertex)
        if fragment is not None:
            case.module(case.g.FS, fragment)
        with self.assertRaisesRegex(StreamFault, 'graphics interface'):
            case.s.pipeline(edits)
        self.assertNotIn(case.g.PIPE, case.g.f.front.idmap)
        self.assertEqual((case.g.f.entry(case.g.VS)['pins'], case.g.f.entry(case.g.FS)['pins']),
                         (0, 0))
        self.assertEqual(case.g.f.owner.work_refs, 0)

    def test_baseline_position_and_color_are_typed(self):
        snapshot = self.s.pipeline()
        self.assertEqual(snapshot.interfaces.vertex_builtins, (((3, 0), ('float', 4)),))
        self.assertEqual(snapshot.interfaces.colors, ((0, ('float', 4)),))
        self.assertEqual(snapshot.interfaces.attributes, ())

    def test_matching_float_varying_links_specialized_stages(self):
        self.module(self.g.VS, interface_program(0, io=3))
        self.module(self.g.FS, interface_program(4, io=1))
        snapshot = self.s.pipeline()
        self.assertEqual(snapshot.interfaces.varyings, ((0, ('float', 4)),))

    def test_vertex_format_class_allows_default_component_filling(self):
        self.module(self.g.VS, interface_program(0, io=1))
        snapshot = self.s.pipeline({'pVertexInputState': self.s.vertex()})
        self.assertEqual(snapshot.interfaces.attributes, ((0, ('float', 4)),))
        self.assertEqual(snapshot.fixed.attributes[0][2], 103)

    def test_missing_or_mismatched_varying_fails_before_pins(self):
        self.refuses(fragment=interface_program(4, io=1))
        self.refuses(vertex=interface_program(0, io=3), fragment=interface_program(4, io=1, comps=2))

    def test_vertex_input_requires_declared_attribute(self):
        self.refuses(vertex=interface_program(0, io=1))

    def test_vertex_format_numeric_class_must_match(self):
        self.refuses(vertex=interface_program(0, io=1),
            edits={'pVertexInputState': self.s.vertex(attributes=((0, 3, 107, 0),))})

    def test_duplicate_interface_locations_are_rejected(self):
        self.refuses(fragment=interface_program(4, io=1, duplicate=True))

    def test_position_must_be_unique_vec4_float_output(self):
        self.refuses(vertex=interface_program(0, position=False))
        self.refuses(vertex=interface_program(0, scalar_position=True))

    def test_fragment_color_type_and_subpass_location_are_checked(self):
        self.refuses(fragment=interface_program(4, color=1))
        self.refuses(fragment=interface_program(4, uint_color=True))

    def test_declared_io_must_be_listed_in_selected_entry(self):
        self.refuses(vertex=interface_program(0, io=1, listed=False))

    def test_format_class_table_covers_native_vertex_whitelist(self):
        self.assertEqual(set(FORMAT_KIND), self.g.e.golden.VATTR_OK)

    def test_position_only_per_vertex_block_is_supported(self):
        self.module(self.g.VS, interface_program(0, position_block=True))
        snapshot = self.s.pipeline()
        self.assertEqual(snapshot.interfaces.vertex_builtins, (((3, 0), ('float', 4)),))


if __name__ == '__main__':
    unittest.main()
