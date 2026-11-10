# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Scalar specialization bytes, immutable module provenance and real replay."""
import unittest
from unittest.mock import patch

import test_vn_compute_replay as compute_fixture
from shader.spirv_scan import Fault, Scanner
from test_vn_compute import program
from vn_native_execution import StreamFault
from vn_native_pipelines import operand
from vn_specialization import read_specialization, specialize


def spec_program():
    source, result, position = program(), list(program()[:5]), 5
    while position < len(source):
        count, opcode = source[position] >> 16, source[position] & 0xFFFF
        if opcode == 19:
            result.extend((4 << 16 | 71, 5, 1, 7))
        if opcode == 43 and source[position + 2] == 5:
            result.extend((count << 16 | 50, *source[position + 1:position + count]))
        else:
            result.extend(source[position:position + count])
        position += count
    return tuple(result)


def op_program(operation=128, operands=(5, 19)):
    source, result, position = spec_program(), list(spec_program()[:5]), 5
    while position < len(source):
        count, opcode = source[position] >> 16, source[position] & 0xFFFF
        if opcode == 54:
            result.extend(((len(operands) + 4) << 16 | 52, 3, 27, operation, *operands))
        if opcode == 62:
            result.extend((3 << 16 | 62, 12, 27))
        else:
            result.extend(source[position:position + count])
        position += count
    return tuple(result)


def composite_program():
    """GLCompute module exercising OpSpecConstantComposite +
    OpSpecConstantOp CompositeExtract: comp=[2,3,5]; e_i = extract i;
    prod = IMul(e0,e1) = 6; sum = IAdd(prod,e2) = 11.  No SpecId — the
    spec constants carry their default values."""
    return tuple(
        [119734787, 67072, 458752, 16, 0] +
        [2 << 16 | 17, 1,
         3 << 16 | 14, 0, 1,
         5 << 16 | 15, 5, 1, 1852399981, 0,
         6 << 16 | 16, 1, 17, 1, 1, 1,
         2 << 16 | 19, 2,
         3 << 16 | 33, 3, 2,
         4 << 16 | 21, 4, 32, 0,
         4 << 16 | 23, 5, 4, 3,
         4 << 16 | 50, 4, 6, 2,
         4 << 16 | 50, 4, 7, 3,
         4 << 16 | 50, 4, 8, 5,
         6 << 16 | 51, 5, 9, 6, 7, 8,
         6 << 16 | 52, 4, 10, 81, 9, 0,
         6 << 16 | 52, 4, 11, 81, 9, 1,
         6 << 16 | 52, 4, 12, 81, 9, 2,
         6 << 16 | 52, 4, 13, 132, 10, 11,
         6 << 16 | 52, 4, 14, 128, 13, 12,
         5 << 16 | 54, 2, 1, 0, 3,
         2 << 16 | 248, 15,
         1 << 16 | 253,
         1 << 16 | 56])


def encoded(entries=((7, 1, 4),), data=b'x\x63\0\0\0'):
    words = [1, 0, len(entries), len(entries), 0]
    for identifier, offset, size in entries:
        words.extend((identifier, offset, size, 0))
    words.extend((len(data), 0, len(data), 0))
    data += b'\0' * (-len(data) % 4)
    words.extend(int.from_bytes(data[i:i + 4], 'little') for i in range(0, len(data), 4))
    return tuple(words)


class SpecializationTests(unittest.TestCase):
    def test_module_scanner_evaluates_specialization_defaults(self):
        self.assertEqual(Scanner(list(spec_program())).scan().consts[5], [5])

    def test_unaligned_data_bytes_and_constant_override(self):
        words = encoded()
        entries = read_specialization(words, 0, len(words))
        self.assertEqual(entries, ((7, (99).to_bytes(4, 'little')),))
        original = spec_program()
        compiled = specialize(original, entries)
        self.assertEqual(Scanner(list(compiled)).scan().consts[5], [99])
        self.assertEqual(original, spec_program())
        self.assertLess(len(compiled), len(original))

    def test_unused_ids_and_shared_data_ranges_preserve_defaults(self):
        words = encoded(((100, 0, 4), (101, 0, 4)), b'abcd')
        compiled = specialize(spec_program(), read_specialization(words, 0, len(words)))
        self.assertEqual(Scanner(list(compiled)).scan().consts[5], [5])

    def test_maximum_entry_and_data_budgets(self):
        words = encoded(tuple((i, 0, 4) for i in range(100, 132)), b'x' * 64)
        entries = read_specialization(words, 0, len(words))
        self.assertEqual(len(entries), 32)
        self.assertEqual(Scanner(list(specialize(spec_program(), entries))).scan().consts[5], [5])

    def test_record_bounds_counts_duplicates_and_sizes_reject(self):
        good = encoded()
        bad = [good[:-1], good + (0,), encoded(((7, 2, 4),)),
               encoded(((7, 0, 4), (7, 0, 4)), b'abcd'),
               encoded(((7, 0, 8),), b'abcdefgh'),
               encoded(tuple((i, 0, 4) for i in range(33)), b'abcd'),
               encoded((), b'x' * 65)]
        mismatch = list(good)
        mismatch[3] = 0
        bad.append(tuple(mismatch))
        for words in bad:
            with self.subTest(words=words[:8]), self.assertRaises(ValueError):
                read_specialization(words, 0, len(words))
        self.assertEqual(read_specialization((0, 0), 0, 2), ())

    def test_scalar_size_and_malformed_instruction_refuse(self):
        for words, entries in ((spec_program(), ((7, b'\1'),)),
                               (spec_program() + (0,), ()),
                               (spec_program() + (4 << 16 | 50, 3), ())):
            with self.assertRaises(ValueError):
                specialize(words, entries)

    def test_bool_nonzero_float_bits_and_composite_defaults(self):
        source = list(spec_program())
        # Unused, well-typed constants still exercise the ordinary scanner.
        start = next(i for i in range(5, len(source)) if source[i] == (5 << 16 | 54))
        extra = [2 << 16 | 20, 21, 3 << 16 | 48, 21, 22,
                 3 << 16 | 22, 23, 32, 4 << 16 | 50, 23, 24, 0x3F800000,
                 4 << 16 | 23, 25, 3, 2, 5 << 16 | 51, 25, 26, 5, 19]
        source[start:start] = extra
        source[5:5] = [4 << 16 | 71, 22, 1, 8, 4 << 16 | 71, 24, 1, 9]
        defaults = Scanner(source).scan()
        self.assertEqual(defaults.consts[22], [1])
        self.assertEqual(defaults.consts[26], [5, 2])
        compiled = specialize(source, ((8, (2).to_bytes(4, 'little')),
                                      (9, (0x80000000).to_bytes(4, 'little'))))
        scan = Scanner(list(compiled)).scan()
        self.assertEqual(scan.consts[22], [1])
        self.assertEqual(scan.consts[24], [0x80000000])
        false = specialize(source, ((8, b'\0' * 4),))
        self.assertEqual(Scanner(list(false)).scan().consts[22], [0])

    def test_unsupported_spec_constant_operations_remain_refused(self):
        with self.assertRaisesRegex(ValueError, 'operations'):
            specialize(op_program(129))

    def test_native_operation_defaults_do_not_broaden_hardware_scanner(self):
        with self.assertRaises(Fault):
            Scanner(list(op_program())).scan()
        self.assertEqual(Scanner(list(op_program()), native_spec_ops=True).scan().consts[27], [7])
        self.assertEqual(Scanner(list(specialize(op_program()))).scan().consts[27], [7])

    def test_dependent_override_folds_immutably_with_integer_wrap(self):
        original = op_program()
        compiled = specialize(original, ((7, (0xFFFFFFFF).to_bytes(4, 'little')),))
        self.assertEqual(Scanner(list(compiled)).scan().consts[27], [1])
        self.assertEqual(original, op_program())
        self.assertNotEqual(compiled, original)

    def test_unary_bitwise_and_shift_operations_are_bounded(self):
        for opcode, operands, expected in ((126, (5,), 0xFFFFFFFB),
                (200, (5,), 0xFFFFFFFA), (197, (5, 19), 7), (198, (5, 19), 7),
                (199, (5, 19), 0), (194, (5, 19), 1), (196, (5, 19), 20)):
            with self.subTest(opcode=opcode):
                code = specialize(op_program(opcode, operands))
                self.assertEqual(Scanner(list(code)).scan().consts[27], [expected])

    def test_invalid_shift_type_and_dependency_refuse_as_bounded_faults(self):
        for source, entries in ((op_program(196, (19, 5)), ((7, (32).to_bytes(4, 'little')),)),
                                (op_program(170), ()), (op_program(128, (31, 19)), ()),
                                (op_program(128, (27, 19)), ())):
            with self.assertRaisesRegex(ValueError, 'operations'):
                specialize(source, entries)

    def test_boolean_comparison_select_dependencies_use_overrides(self):
        source = list(op_program())
        position = source.index(5 << 16 | 54)
        start = position - 6
        source[start:position] = [2 << 16 | 20, 21,
            6 << 16 | 52, 21, 28, 176, 5, 19,
            7 << 16 | 52, 3, 27, 169, 28, 5, 19]
        self.assertEqual(Scanner(list(specialize(source))).scan().consts[27], [2])
        code = specialize(source, ((7, (1).to_bytes(4, 'little')),))
        self.assertEqual(Scanner(list(code)).scan().consts[27], [1])

    def test_derived_array_bound_is_checked_before_null_allocation(self):
        source = list(op_program(132))
        position = source.index(5 << 16 | 54)
        source[position:position] = [4 << 16 | 28, 21, 3, 27, 3 << 16 | 46, 21, 22]
        self.assertEqual(len(Scanner(list(specialize(source))).scan().consts[22]), 10)
        with self.assertRaisesRegex(ValueError, 'operations'):
            specialize(source, ((7, (65536).to_bytes(4, 'little')),))

    def test_operation_scan_depth_failure_is_a_bounded_admission_error(self):
        with patch('vn_specialization.Scanner.scan', side_effect=RecursionError('depth')):
            with self.assertRaisesRegex(ValueError, 'operations'):
                specialize(op_program())

    def test_spec_constant_composite_extract_folds(self):
        words = composite_program()
        # native scan evaluates the spec-ops: composite extract yields the
        # component, then IMul/IAdd fold to concrete constants.
        sc = Scanner(list(words), native_spec_ops=True).scan()
        self.assertEqual(sc.consts[9], [2, 3, 5])
        self.assertEqual(sc.consts[10], [2])
        self.assertEqual(sc.consts[11], [3])
        self.assertEqual(sc.consts[12], [5])
        self.assertEqual(sc.consts[13], [6])
        self.assertEqual(sc.consts[14], [11])
        # specialize() folds the spec-ops to OpConstant for the device path.
        folded = Scanner(list(specialize(words))).scan()
        self.assertEqual(folded.consts[13], [6])
        self.assertEqual(folded.consts[14], [11])

    def test_specialized_null_array_rejects_before_unbounded_materialization(self):
        source = list(spec_program())
        start = next(i for i in range(5, len(source)) if source[i] == (5 << 16 | 54))
        source[start:start] = [4 << 16 | 28, 21, 3, 5, 3 << 16 | 46, 21, 22]
        self.assertEqual(Scanner(source).scan().consts[22], [0] * 5)
        compiled = specialize(source, ((7, b'\xff' * 4),))
        with self.assertRaises(Fault):
            Scanner(list(compiled)).scan()


class SpecializationPipelineTests(unittest.TestCase):
    def setUp(self):
        self.r = compute_fixture.ComputeReplayTests()
        self.r.setUp()
        self.p, self.f, self.w, self.e = self.r.p, self.r.f, self.r.w, self.r.e
        self.f.command('vkDestroyPipeline', device=self.w.DEVICE, pipeline=self.r.l.PIPE)
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.r.l.MODULE)
        self.p.module(spec_program())

    def info(self, value, *, size=4):
        return self.w.structure('VkSpecializationInfo', mapEntryCount=1,
            pMapEntries=[self.w.structure('VkSpecializationMapEntry', constantID=7,
                                         offset=1, size=size)],
            dataSize=5, pData=b'x' + value.to_bytes(4, 'little'))

    def test_specialized_dispatch_keeps_original_module_provenance(self):
        self.p.pipeline(spec=self.info(99))
        snapshot, _ = operand(self.e, 1, self.r.l.PIPE)
        self.assertEqual(snapshot.module_code, spec_program())
        self.assertNotEqual(snapshot.code, snapshot.module_code)
        self.assertEqual(tuple(self.f.front.sh_code[snapshot.module]), snapshot.module_code)
        self.r.record()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(), 99)

    def test_default_specialization_dispatch(self):
        self.p.pipeline()
        self.r.record()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(), 5)

    def test_operation_dispatch_retains_original_module_and_folded_result(self):
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.r.l.MODULE)
        self.p.module(op_program())
        self.p.pipeline(spec=self.info(99))
        snapshot, _ = operand(self.e, 1, self.r.l.PIPE)
        self.assertEqual(snapshot.module_code, op_program())
        self.assertEqual(Scanner(list(snapshot.code)).scan().consts[27], [101])
        self.r.record()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(), 101)

    def test_module_destruction_and_id_reuse_preserve_specialized_code(self):
        self.p.pipeline(spec=self.info(17))
        self.f.command('vkDestroyShaderModule', device=self.w.DEVICE, shaderModule=self.r.l.MODULE)
        self.p.module(program(add=True))
        self.r.record()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(), 17)

    def test_bad_scalar_size_refuses_before_pipeline_allocation_or_pin(self):
        with self.assertRaisesRegex(StreamFault, 'specialization'):
            self.p.pipeline(spec=self.info(17, size=1))
        self.assertNotIn(self.r.l.PIPE, self.f.front.idmap)
        self.assertEqual(self.f.entry(self.r.l.MODULE)['pins'], 0)

    def test_batch_pipelines_share_source_but_not_specialized_constants(self):
        other = 0x400180001018
        infos = [self.w.structure('VkComputePipelineCreateInfo', pNext=[], flags=0,
            stage=self.w.structure('VkPipelineShaderStageCreateInfo', pNext=[], flags=0,
                stage=0x20, module=self.r.l.MODULE, pName='main',
                pSpecializationInfo=self.info(value)),
            layout=self.r.l.PL, basePipelineHandle=0, basePipelineIndex=-1)
            for value in (11, 22)]
        self.f.command('vkCreateComputePipelines', device=self.w.DEVICE,
            pipelineCache=0, createInfoCount=2, pCreateInfos=infos,
            pPipelines=[self.r.l.PIPE, other])
        first, _ = operand(self.e, 1, self.r.l.PIPE)
        second, _ = operand(self.e, 1, other)
        self.assertEqual(first.module, second.module)
        self.assertEqual(first.module_code, second.module_code)
        self.assertNotEqual(first.code, second.code)
        self.r.record()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(), 11)
        self.f.begin()
        self.r.bind(pipeline=False)
        self.f.command('vkCmdBindPipeline', commandBuffer=self.f.CB,
                       pipelineBindPoint=1, pipeline=other)
        self.r.dispatch()
        self.f.end()
        self.r.enqueue()
        self.f.drain()
        self.assertEqual(self.r.word(), 22)


if __name__ == '__main__':
    unittest.main()
