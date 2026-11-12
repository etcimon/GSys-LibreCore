#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Shader opcode table: the one list of SPIR-V opcodes the APU accepts.

Source of truth for
  spirv_scan.OP / ACCEPT and the generic result handler list,
  spirv_model.Model.HAS_RTY,
  g6lc_apu_shmod.sv  is_accepted() and has_result(),
  g6lc_apu_shwave.sv f_has_rty().
The Python consumers import this module.  The SystemVerilog case labels
are written between `// GEN-BEGIN sh_opcodes:<set>` and `// GEN-END`
markers by gen_sh_opcodes.py (`--check` fails on drift).

To add an opcode: add its row here, run gen_sh_opcodes.py, then write the
execution (model and shwave) and a corpus vector.  A row alone makes the
opcode commit; it does not make it execute.

Row: (opcode, name, flags, operands).  Flags:
  r  the instruction has a (result type, result id) prefix
  f  legal only in a Fragment execution model (commit fault elsewhere)
  a  the result may be a struct or array value; any other result-
     bearing opcode with such a result type faults TYPE at commit
     (invariant I1: accepted means executed)
operands: value operands the wave engine resolves before execution
  (f_nva / Model.nva); None = computed from the word count or the
  image-operands mask, written by hand in both places.

Notes kept from the hand-written lists:
  87/89/91/93/105 (implicit LOD, QueryLod) and 207-215 (derivatives) are
  fragment-only; 90/92/94 and the gathers 96/97 run in any model.
  4416/5380/5381 are fragment termination / helper ops.
  228 AtomicStore and 99 ImageWrite have no result.
"""

ROWS = [
    (0, 'Nop', '', 0),
    (1, 'Undef', 'ra', 0),
    (3, 'Source', '', 2),
    (4, 'SourceExtension', '', 2),
    (5, 'Name', '', 2),
    (6, 'MemberName', '', 2),
    (7, 'String', '', 2),
    (8, 'Line', '', 2),
    (10, 'Extension', '', 2),
    (11, 'ExtInstImport', '', 2),
    (12, 'ExtInst', 'ra', None),
    (14, 'MemoryModel', '', 2),
    (15, 'EntryPoint', '', 2),
    (16, 'ExecutionMode', '', 2),
    (17, 'Capability', '', 2),
    (19, 'TypeVoid', '', 2),
    (20, 'TypeBool', '', 2),
    (21, 'TypeInt', '', 2),
    (22, 'TypeFloat', '', 2),
    (23, 'TypeVector', '', 2),
    (24, 'TypeMatrix', '', 2),
    (25, 'TypeImage', '', 2),
    (26, 'TypeSampler', '', 2),
    (27, 'TypeSampledImage', '', 2),
    (28, 'TypeArray', '', 2),
    (29, 'TypeRuntimeArray', '', 2),
    (30, 'TypeStruct', '', 2),
    (32, 'TypePointer', '', 2),
    (33, 'TypeFunction', '', 2),
    (41, 'ConstantTrue', '', 2),
    (42, 'ConstantFalse', '', 2),
    (43, 'Constant', '', 2),
    (44, 'ConstantComposite', '', 2),
    (46, 'ConstantNull', '', 2),
    (48, 'SpecConstantTrue', '', 2),
    (49, 'SpecConstantFalse', '', 2),
    (50, 'SpecConstant', '', 2),
    (51, 'SpecConstantComposite', '', 2),
    (52, 'SpecConstantOp', '', 2),
    (54, 'Function', '', 0),
    (55, 'FunctionParameter', '', 2),
    (56, 'FunctionEnd', '', 0),
    (57, 'FunctionCall', 'ra', 0),
    (59, 'Variable', '', 0),
    (60, 'ImageTexelPointer', 'r', 3),
    (61, 'Load', 'ra', 1),
    (62, 'Store', '', 2),
    (65, 'AccessChain', 'r', 1),
    (66, 'InBoundsAccessChain', 'r', 1),
    (68, 'ArrayLength', 'r', 1),
    (71, 'Decorate', '', 2),
    (72, 'MemberDecorate', '', 2),
    (77, 'VectorExtractDynamic', 'r', 2),
    (78, 'VectorInsertDynamic', 'r', 3),
    (79, 'VectorShuffle', 'r', 2),
    (80, 'CompositeConstruct', 'ra', None),
    (81, 'CompositeExtract', 'ra', 1),
    (82, 'CompositeInsert', 'ra', 2),
    (83, 'CopyObject', 'ra', 1),
    (84, 'Transpose', 'r', 1),
    (86, 'SampledImage', 'r', 2),
    (87, 'ImageSampleImplicitLod', 'rf', None),
    (88, 'ImageSampleExplicitLod', 'r', 3),
    (89, 'ImageSampleDrefImplicitLod', 'rf', None),
    (90, 'ImageSampleDrefExplicitLod', 'r', None),
    (91, 'ImageSampleProjImplicitLod', 'rf', None),
    (92, 'ImageSampleProjExplicitLod', 'r', None),
    (93, 'ImageSampleProjDrefImplicitLod', 'rf', None),
    (94, 'ImageSampleProjDrefExplicitLod', 'r', None),
    (95, 'ImageFetch', 'r', None),
    (96, 'ImageGather', 'r', None),
    (97, 'ImageDrefGather', 'r', None),
    (98, 'ImageRead', 'r', 2),
    (99, 'ImageWrite', '', 3),
    (100, 'Image', 'r', 2),
    (103, 'ImageQuerySizeLod', 'r', 2),
    (104, 'ImageQuerySize', 'r', 2),
    (105, 'ImageQueryLod', 'rf', 2),
    (106, 'ImageQueryLevels', 'r', 2),
    (109, 'ConvertFToU', 'r', 1),
    (110, 'ConvertFToS', 'r', 1),
    (111, 'ConvertSToF', 'r', 1),
    (112, 'ConvertUToF', 'r', 1),
    (124, 'Bitcast', 'r', 1),
    (126, 'SNegate', 'r', 1),
    (127, 'FNegate', 'r', 1),
    (128, 'IAdd', 'r', 2),
    (129, 'FAdd', 'r', 2),
    (130, 'ISub', 'r', 2),
    (131, 'FSub', 'r', 2),
    (132, 'IMul', 'r', 2),
    (133, 'FMul', 'r', 2),
    (134, 'UDiv', 'r', 2),
    (135, 'SDiv', 'r', 2),
    (136, 'FDiv', 'r', 2),
    (137, 'UMod', 'r', 2),
    (138, 'SRem', 'r', 2),
    (139, 'SMod', 'r', 2),
    (140, 'FRem', 'r', 2),
    (141, 'FMod', 'r', 2),
    (142, 'VectorTimesScalar', 'r', 2),
    (143, 'MatrixTimesScalar', 'r', 2),
    (144, 'VectorTimesMatrix', 'r', 2),
    (145, 'MatrixTimesVector', 'r', 2),
    (146, 'MatrixTimesMatrix', 'r', 2),
    (147, 'OuterProduct', 'r', 2),
    (148, 'Dot', 'r', 2),
    (149, 'IAddCarry', 'ra', 2),
    (150, 'ISubBorrow', 'ra', 2),
    (151, 'UMulExtended', 'ra', 2),
    (152, 'SMulExtended', 'ra', 2),
    (154, 'Any', 'r', 1),
    (155, 'All', 'r', 1),
    (156, 'IsNan', 'r', 1),
    (157, 'IsInf', 'r', 1),
    (164, 'LogicalEqual', 'r', 2),
    (165, 'LogicalNotEqual', 'r', 2),
    (166, 'LogicalOr', 'r', 2),
    (167, 'LogicalAnd', 'r', 2),
    (168, 'LogicalNot', 'r', 1),
    (169, 'Select', 'ra', 3),
    (170, 'IEqual', 'r', 2),
    (171, 'INotEqual', 'r', 2),
    (172, 'UGreaterThan', 'r', 2),
    (173, 'SGreaterThan', 'r', 2),
    (174, 'UGreaterThanEqual', 'r', 2),
    (175, 'SGreaterThanEqual', 'r', 2),
    (176, 'ULessThan', 'r', 2),
    (177, 'SLessThan', 'r', 2),
    (178, 'ULessThanEqual', 'r', 2),
    (179, 'SLessThanEqual', 'r', 2),
    (180, 'FOrdEqual', 'r', 2),
    (181, 'FUnordEqual', 'r', 2),
    (182, 'FOrdNotEqual', 'r', 2),
    (183, 'FUnordNotEqual', 'r', 2),
    (184, 'FOrdLessThan', 'r', 2),
    (185, 'FUnordLessThan', 'r', 2),
    (186, 'FOrdGreaterThan', 'r', 2),
    (187, 'FUnordGreaterThan', 'r', 2),
    (188, 'FOrdLessThanEqual', 'r', 2),
    (189, 'FUnordLessThanEqual', 'r', 2),
    (190, 'FOrdGreaterThanEqual', 'r', 2),
    (191, 'FUnordGreaterThanEqual', 'r', 2),
    (194, 'ShiftRightLogical', 'r', 2),
    (195, 'ShiftRightArithmetic', 'r', 2),
    (196, 'ShiftLeftLogical', 'r', 2),
    (197, 'BitwiseOr', 'r', 2),
    (198, 'BitwiseXor', 'r', 2),
    (199, 'BitwiseAnd', 'r', 2),
    (200, 'Not', 'r', 1),
    (201, 'BitFieldInsert', 'r', 4),
    (202, 'BitFieldSExtract', 'r', 3),
    (203, 'BitFieldUExtract', 'r', 3),
    (204, 'BitReverse', 'r', 1),
    (205, 'BitCount', 'r', 1),
    (207, 'DPdx', 'rf', 1),
    (208, 'DPdy', 'rf', 1),
    (209, 'Fwidth', 'rf', 1),
    (210, 'DPdxFine', 'rf', 1),
    (211, 'DPdyFine', 'rf', 1),
    (212, 'FwidthFine', 'rf', 1),
    (213, 'DPdxCoarse', 'rf', 1),
    (214, 'DPdyCoarse', 'rf', 1),
    (215, 'FwidthCoarse', 'rf', 1),
    (224, 'ControlBarrier', '', 0),
    (225, 'MemoryBarrier', '', 0),
    (227, 'AtomicLoad', 'r', 1),
    (228, 'AtomicStore', '', 2),
    (229, 'AtomicExchange', 'r', 2),
    (230, 'AtomicCompareExchange', 'r', 3),
    (232, 'AtomicIIncrement', 'r', 2),
    (233, 'AtomicIDecrement', 'r', 2),
    (234, 'AtomicIAdd', 'r', 2),
    (235, 'AtomicISub', 'r', 2),
    (236, 'AtomicSMin', 'r', 2),
    (237, 'AtomicUMin', 'r', 2),
    (238, 'AtomicSMax', 'r', 2),
    (239, 'AtomicUMax', 'r', 2),
    (240, 'AtomicAnd', 'r', 2),
    (241, 'AtomicOr', 'r', 2),
    (242, 'AtomicXor', 'r', 2),
    (245, 'Phi', 'ra', 0),
    (246, 'LoopMerge', '', 0),
    (247, 'SelectionMerge', '', 0),
    (248, 'Label', '', 0),
    (249, 'Branch', '', 0),
    (250, 'BranchConditional', '', 1),
    (251, 'Switch', '', 1),
    (252, 'Kill', 'f', 0),
    (253, 'Return', '', 0),
    (254, 'ReturnValue', '', 0),
    (255, 'Unreachable', '', 0),
    (400, 'CopyLogical', 'ra', 1),
    (4416, 'TerminateInvocation', 'f', 0),
    (5380, 'DemoteToHelperInvocation', 'f', 0),
    (5381, 'IsHelperInvocationEXT', 'rf', 0),
]

# Result-bearing opcodes a consumer handles outside its generic path.
# spirv_scan registers the result in the opcode's own handler:
SCAN_OWN = {12: 'h_12 ExtInst', 57: 'h_57 FunctionCall', 245: 'h_245 Phi'}
# g6lc_apu_shmod reserves the result row from the opcode's own commit arm:
SHMOD_OWN = {12: 'ExtInst', 57: 'FunctionCall', 5381: 'IsHelperInvocation'}

OP = {name: code for code, name, _, _ in ROWS}
ACCEPT = frozenset(OP.values())
RESULT = frozenset(code for code, _, fl, _ in ROWS if 'r' in fl)
FRAG_ONLY = frozenset(code for code, _, fl, _ in ROWS if 'f' in fl)
AGG_RESULT = frozenset(code for code, _, fl, _ in ROWS if 'a' in fl)
assert AGG_RESULT <= RESULT
NVA = {code: n for code, _, _, n in ROWS if n is not None}

assert len(OP) == len(ROWS) == len(ACCEPT), 'duplicate opcode or name'
assert set(SCAN_OWN) <= RESULT and set(SHMOD_OWN) <= RESULT
