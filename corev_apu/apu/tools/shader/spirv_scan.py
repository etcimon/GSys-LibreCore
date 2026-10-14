#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Golden model of the g6lc_apu_shmod commit scanner (architecture
doc 7a).  Parses a SPIR-V module, enforces the increment-4a compute
subset, and produces the exact SRAM table images the RTL must build:

  type table   3 words/id     const table   16 words/id
  member table 2 words/entry  decor table   2 words/id
  var table    2 words/id     regmap        1 word/id
  init table   2 words/entry  entry record  4 words
  block table  1 word/id      phi table     5 words/phi-result-id

Usage:
  spirv_scan.py module.spv [--emit-tab module.tab] [--check] [--info]

`--check` only validates subset membership and prints the fault word
stream (code/opcode/word) plus the entry record.
"""
import json
import struct
import sys

MAGIC = 0x07230203

# ---- table geometry (must match g6lc_apu_sh_pkg) ------------------
SHADER_IDS = 1024
SHADER_REGS = 256
SHADER_MEMBERS = 256
SHADER_INIT = 128
MDECOR_MAX = 64            # pending member-decor window (RTL)
BRANCH_MAX = 48            # queued branch targets (existence check)
OPN_MAX = 32               # operand words staged (RTL OPB)
TYPE_WORDS = 3
CONST_WORDS = 16
MEMBER_WORDS = 2
DECOR_WORDS = 2
VAR_WORDS = 2
REGMAP_WORDS = 1
INIT_WORDS = 2
ENTRY_WORDS = 4
PHI_WORDS = 5              # npairs word + 4 packed (value,parent) words
PHI_MAXPAIRS = 4
MAX_LOCAL = 64

# ---- fault codes (must match APU_SH_FAULT_*) ----------------------
FAULT = dict(NONE=0, MAGIC=1, VERSION=2, CAP=3, MEMMODEL=4, ENTRY=5,
             EXECMODE=6, LOCALSIZE=7, OPCODE=8, TYPE=9, DECOR=10,
             CONST=11, VAR=12, STORAGE=13, BOUND=14, REGS=15,
             TWO_ENTRY=16, WORDS=17, FWDREF=18, SPEC=19, BRANCH=20,
             FUNC=21)
FAULT_NAME = {v: k for k, v in FAULT.items()}

# G3a-i: function table geometry (must match shmod MaxFuncs/MaxParams)
MAX_FUNCS = 16                 # OpFunction bodies per module
MAX_PARAMS = 8                 # OpFunctionParameter per function

# ---- type kinds (must match APU_SH_TK_*) ---------------------------
TK = dict(NONE=0, VOID=1, BOOL=2, INT=3, FLOAT=4, VEC=5, MAT=6,
          ARRAY=7, RARRAY=8, STRUCT=9, PTR=10, FUNC=11,
          IMG=12, SAMP=13, SIMG=14)          # §12.3 C/5b

# ---- storage classes (must match APU_SH_SC_*) ----------------------
SC = dict(UNIFORMCONST=0, INPUT=1, UNIFORM=2, OUTPUT=3, WORKGROUP=4,
          CROSSWG=5, PRIVATE=6, FUNCTION=7, GENERIC=8, PUSHCONST=9,
          ATOMICCTR=10, IMAGE=11, SBUF=12)
SC_OK = {SC['INPUT'], SC['OUTPUT'], SC['UNIFORM'], SC['SBUF'],
         SC['PUSHCONST'], SC['WORKGROUP'], SC['PRIVATE'],
         SC['FUNCTION'], SC['UNIFORMCONST']}

# builtins we materialize per lane
BUILTIN = dict(NumWorkgroups=24, WorkgroupSize=25, WorkgroupId=26,
               LocalInvocationId=27, GlobalInvocationId=28,
               LocalInvocationIndex=29)
BUILTIN_OK = set(BUILTIN.values())

# ---- graphics stages (first-pixel increment) --------------------
# execution models (OpEntryPoint operand)
EM = dict(VERTEX=0, FRAGMENT=4, GLCOMPUTE=5)
# graphics builtins: Position/PointSize/ClipDistance/CullDistance are
# the gl_PerVertex members; FragCoord/FrontFacing are FS inputs;
# VertexIndex/InstanceIndex are VS inputs
BI_GFX = dict(POSITION=0, POINTSIZE=1, CLIPDIST=3, CULLDIST=4,
              FRAGCOORD=15, FRONTFACING=17, HELPERINVOCATION=23,
              FRAGDEPTH=22,
              VERTEXINDEX=42, INSTANCEINDEX=43)
BI_GFX_IDS = set(BI_GFX.values())
BI_GFX_DROP = {BI_GFX['POINTSIZE'], BI_GFX['CLIPDIST'],
               BI_GFX['CULLDIST']}
BUILTIN_OK |= BI_GFX_IDS          # id-level set; stage rules in variable()
MBR_BI_OK = {BI_GFX['POSITION'], BI_GFX['POINTSIZE'],
             BI_GFX['CLIPDIST'], BI_GFX['CULLDIST']}
# varying/attribute records, 16 B per location, fixed stride:
#   VS-in:  Location l at 16*l          stride ATTR (128)
#   VS-out: Position at 0, loc l 16*(1+l) stride VARY (144)
#   FS-in:  FragCoord at 0, loc l 16*(1+l) stride VARY
#   FS-out: Location l at 16*l          stride ATTR
VARY_LOCS = 8
ATTR_STRIDE = 16 * (1 + VARY_LOCS)  # 144 (VS-in slot 8 = VertexIndex/InstanceIndex)
VARY_STRIDE = 16 * (1 + VARY_LOCS)  # 144
# interface-variable/pointer flags nibble (var row w0[31:28], init
# row w0[31:28], pointer tag comp1[31:28])
VF_REC = 0x1     # aperture record access
VF_DROP = 0x2    # dropped builtin region (stores dropped, loads 0)
MF_DROP = 0x40   # member-table flag: dropped builtin member
# decor-row flags-byte markers: bit5 = builtin field valid (0 is a
# legal builtin id), bit6 = word1 holds a Location
DF_BI = 0x20
DF_LOC = 0x40
# type-table word0 spare bit marking a struct with builtin members
# (gl_PerVertex shape)
TY_HAS_MBI = 1 << 29

# decorations we accept (id-level and member-level)
DEC = dict(RelaxedPrecision=0, SpecId=1, Block=2, BufferBlock=3,
           RowMajor=4, ColMajor=5, ArrayStride=6, MatrixStride=7,
           Builtin=11, NoPerspective=13, Flat=14, Centroid=16,
           Restrict=19, Aliased=20, NonWritable=24, NonReadable=25,
           Uniform=26, Location=30, Binding=33, DescriptorSet=34,
           Offset=35, NoContraction=42)
DEC_ID_OK = {DEC['RelaxedPrecision'], DEC['Block'], DEC['BufferBlock'],
             DEC['ArrayStride'], DEC['Builtin'], DEC['Restrict'],
             DEC['Aliased'], DEC['NonWritable'], DEC['NonReadable'],
             DEC['Binding'], DEC['DescriptorSet'], DEC['NoContraction'],
             DEC['SpecId'], DEC['Uniform'], DEC['Location']}
DEC_MBR_OK = {DEC['RelaxedPrecision'], DEC['RowMajor'], DEC['ColMajor'],
              DEC['MatrixStride'], DEC['Offset'], DEC['NonWritable'],
              DEC['NonReadable'], DEC['NoContraction'], DEC['SpecId'],
              DEC['Builtin']}

CAP_OK = {1, 50, 51, 5379}  # + DemoteToHelperInvocation (G3a-i)
EXEC_MODE_OK = {17}    # LocalSize (OriginUpperLeft=7 handled inline)
MEM_OK = (0, 1)        # Logical GLSL450
ENTRY_MODEL_OK = set(EM.values())   # Vertex/Fragment/GLCompute

# accepted opcodes (grammar spirv.core.grammar.json vulkan-sdk-
# 1.4.309.0): the 4a execution subset plus header/type/decor
OP = dict(
    Nop=0, Source=3, SourceExtension=4, Name=5, MemberName=6,
    String=7, Line=8, Extension=10,
    ExtInstImport=11, ExtInst=12, MemoryModel=14, EntryPoint=15,
    ExecutionMode=16, Capability=17,
    TypeVoid=19, TypeBool=20, TypeInt=21, TypeFloat=22, TypeVector=23,
    TypeMatrix=24, TypeImage=25, TypeSampler=26, TypeSampledImage=27,
    TypeArray=28, TypeRuntimeArray=29,
    TypeStruct=30, TypePointer=32, TypeFunction=33,
    ConstantTrue=41, ConstantFalse=42, Constant=43,
    ConstantComposite=44, ConstantNull=46,
    SpecConstantTrue=48, SpecConstantFalse=49, SpecConstant=50,
    SpecConstantComposite=51, SpecConstantOp=52,
    # §12.3 C/5b image ops — OpImageSampleImplicitLod (87, G2b) is
    # fragment-only (FRAG_ONLY below); the projected/depth-ref
    # implicit forms (89..93) stay absent and fault OPCODE
    SampledImage=86, ImageSampleImplicitLod=87,
    ImageSampleExplicitLod=88,
    ImageFetch=95, ImageRead=98, ImageWrite=99, Image=100,
    ImageQuerySizeLod=103, ImageQuerySize=104, ImageQueryLevels=106,
    Function=54, FunctionParameter=55, FunctionEnd=56,
    FunctionCall=57, Variable=59, Load=61, Store=62,
    AccessChain=65, InBoundsAccessChain=66, ArrayLength=68,
    Decorate=71, MemberDecorate=72,
    VectorShuffle=79, CompositeConstruct=80, CompositeExtract=81,
    CompositeInsert=82, Transpose=84,
    # G3a-i: misc/value ops
    Undef=1, VectorExtractDynamic=77, VectorInsertDynamic=78,
    CopyObject=83, FRem=140, FMod=141,
    IAddCarry=149, ISubBorrow=150, UMulExtended=151, SMulExtended=152,
    Any=154, All=155, IsNan=156, IsInf=157,
    ConvertFToU=109, ConvertFToS=110, ConvertSToF=111,
    ConvertUToF=112, Bitcast=124,
    SNegate=126, FNegate=127, IAdd=128, FAdd=129, ISub=130, FSub=131,
    IMul=132, FMul=133, UDiv=134, SDiv=135, FDiv=136, UMod=137,
    SRem=138, SMod=139,
    VectorTimesScalar=142,
    MatrixTimesScalar=143, VectorTimesMatrix=144,
    MatrixTimesVector=145, MatrixTimesMatrix=146,
    OuterProduct=147, Dot=148,
    LogicalEqual=164, LogicalNotEqual=165, LogicalOr=166,
    LogicalAnd=167, LogicalNot=168, Select=169,
    IEqual=170, INotEqual=171, UGreaterThan=172, SGreaterThan=173,
    UGreaterThanEqual=174, SGreaterThanEqual=175, ULessThan=176,
    SLessThan=177, ULessThanEqual=178, SLessThanEqual=179,
    FOrdEqual=180, FUnordEqual=181, FOrdNotEqual=182,
    FUnordNotEqual=183, FOrdLessThan=184, FUnordLessThan=185,
    FOrdGreaterThan=186, FUnordGreaterThan=187,
    FOrdLessThanEqual=188, FUnordLessThanEqual=189,
    FOrdGreaterThanEqual=190, FUnordGreaterThanEqual=191,
    ShiftRightLogical=194, ShiftRightArithmetic=195,
    ShiftLeftLogical=196, BitwiseOr=197, BitwiseXor=198,
    BitwiseAnd=199, Not=200,
    BitFieldInsert=201, BitFieldSExtract=202, BitFieldUExtract=203,
    BitReverse=204, BitCount=205,
    # G3a-i: 32-bit atomics (lane-serial read-modify-write)
    AtomicLoad=227, AtomicStore=228, AtomicExchange=229,
    AtomicCompareExchange=230, AtomicIIncrement=232,
    AtomicIDecrement=233, AtomicIAdd=234, AtomicISub=235,
    AtomicSMin=236, AtomicUMin=237, AtomicSMax=238, AtomicUMax=239,
    AtomicAnd=240, AtomicOr=241, AtomicXor=242,
    # G2b derivative family — fragment-only (FRAG_ONLY); quads are
    # lanes {4k..4k+3} of a wave
    DPdx=207, DPdy=208, Fwidth=209,
    DPdxFine=210, DPdyFine=211, FwidthFine=212,
    DPdxCoarse=213, DPdyCoarse=214, FwidthCoarse=215,
    ControlBarrier=224, MemoryBarrier=225,
    Phi=245, LoopMerge=246, SelectionMerge=247,
    Label=248, Branch=249, BranchConditional=250, Switch=251,
    Kill=252, Return=253, ReturnValue=254, Unreachable=255,
    # G3a-i fragment termination / helper ops (SPV_EXT_terminator /
    # demote; all FRAG_ONLY)
    TerminateInvocation=4416, DemoteToHelperInvocation=5380,
    IsHelperInvocationEXT=5381,
)

ACCEPT = set(OP.values())

# opcodes legal only inside a Fragment-execution-model module: the
# implicit-LOD sample (87) needs quad derivatives that VS/compute
# waves never form, and 207-215 *are* quad derivatives
FRAG_ONLY = {87, 207, 208, 209, 210, 211, 212, 213, 214, 215,
             252, 4416, 5380, 5381}

# instruction word bound for ops that stage all operand words
STAGE_BOUND = {57, 245, 224, 225, 246, 247, 250, 251, 84,
               143, 144, 145, 146, 147, 255}

# GLSL.std.450 extinst numbers accepted in 4a (extinst grammar vulkan-
# sdk-1.4.309.0); everything else faults at commit.
EXT450 = dict(Round=1, RoundEven=2, Trunc=3, FAbs=4, SAbs=5, FSign=6,
              SSign=7, Floor=8, Ceil=9, Fract=10, Sqrt=31,
              InverseSqrt=32,
              # G3a-i: determinant/inverse, modf/frexp family, fp16 and
              # fixed-point pack pairs, geometry ops, bit scans, NaN-
              # propagating min/max/clamp
              Determinant=33, MatrixInverse=34, Modf=35, ModfStruct=36,
              Frexp=51, FrexpStruct=52, Ldexp=53, PackSnorm4x8=54,
              PackUnorm4x8=55, PackSnorm2x16=56, PackUnorm2x16=57,
              PackHalf2x16=58, UnpackSnorm2x16=60, UnpackUnorm2x16=61,
              UnpackHalf2x16=62, UnpackSnorm4x8=63, UnpackUnorm4x8=64,
              FaceForward=70, Reflect=71, Refract=72, FindILsb=73,
              FindSMsb=74, FindUMsb=75, NMin=79, NMax=80, NClamp=81,
              FMin=37, UMin=38, SMin=39, FMax=40,
              UMax=41, SMax=42, FClamp=43, UClamp=44, SClamp=45,
              FMix=46, Step=48, SmoothStep=49, Fma=50, Length=66,
              Distance=67, Cross=68, Normalize=69)
EXT450_OK = set(EXT450.values())


def w32(x):
    return x & 0xFFFFFFFF


class Fault(Exception):
    def __init__(self, code, opcode, word):
        super().__init__(FAULT_NAME[code])
        self.code, self.opcode, self.word = code, opcode, word


class Scanner:
    def __init__(self, words):
        self.w = words
        self.types = {}       # id -> dict
        self.consts = {}      # id -> list of words (<=16)
        self.const_tid = {}
        self.decor = {}       # id -> dict(set,binding,builtin,flags,stride)
        self.mdecor = {}      # (id,member) -> dict(offset,mstride,flags)
        self.vars = {}        # id -> dict(storage,set,binding,builtin,
        #                                  scratch_off,type_id)
        self.regmap = {}      # id -> (tag, idx, type_id)
        self.labels = {}      # label id -> word offset (block table)
        self.branches = []    # (word off, target label id) deferred check
        self.phis = []        # (result id, [(value,parent)]) — P table
        self.loops = []       # open (merge_lbl, cont_lbl), innermost last
        self.merge_pending = False  # previous insn was a merge op
        self.member_base = {}  # type id -> base idx in member table
        self.members = []      # flat member table entries
        self.init = []         # (reg_idx, storage, aux, set, binding, off)
        self.entry = None
        self.em = EM['GLCOMPUTE']  # execution model (h_15 overrides)
        self.in_mask = 0           # Location'd Input variables (bit/loc)
        self.out_mask = 0          # Location'd Output variables
        self.localsize = (0, 0, 0)
        self.scratch = 0
        self.slab = 0
        self.n_regs = 0
        self.n_consts = 0
        self.entry_count = 0
        self.in_function = False
        self.saw_function_end = False
        self.glsl_id = None
        self.entry_off = 0
        # G3a-i: function table + deferred call-target check
        self.funcs = {}        # func id -> dict(off, rty, params, pbase)
        self.forder = []       # function ids in scan order (table idx)
        self.cur_func = 0
        self.fn_head = False   # between OpFunction and first OpLabel
        self.calls = []        # (word off, callee func id)
        self.has_kill = False  # kill/terminate/demote present
        self.wr_fdepth = False # module writes FragDepth (FS Output)

    # -- helpers -----------------------------------------------------
    # regmap row: {tag[31:30], aux[29:26] (const word count),
    #              type_id[25:16], idx[15:0]}
    def reg(self, iid, tag=0, tid=0, aux=0):
        """regmap row {tag[31:30], aux[29:26], type_id[25:16], idx[15:0]}.
        A MAT-typed id occupies `cols` consecutive RF slots starting at
        idx (§7c: one 4-lane reg row per column)."""
        if iid == 0:
            return
        if iid in self.regmap:
            return
        if tag == 1:
            self.regmap[iid] = (1, iid, tid, aux)
            self.n_consts += 1
        else:
            n = 1
            t = self.types.get(tid)
            if t is not None and t['kind'] == TK['MAT']:
                n = t['cols']
            elif t is not None and t['kind'] == TK['STRUCT']:
                # G3a-i struct-typed results (IAddCarry / ModfStruct /
                # FrexpStruct): flat word image, 4 words per RF row
                n = (self.struct_words(tid) + 3) // 4
            if self.n_regs + n > SHADER_REGS:
                raise Fault(FAULT['REGS'], 0, 0)
            self.regmap[iid] = (0, self.n_regs, tid, aux)
            self.n_regs += n

    def nwords(self, tid):
        """flat 32-bit words of a value of type tid."""
        t = self.types.get(tid, {})
        k = t.get('kind')
        if k == TK['VEC']:
            return t['comps']
        if k == TK['MAT']:
            return t['cols'] * self.types.get(t['elem'],
                                              {'comps': 1})['comps']
        if k == TK['STRUCT']:
            return self.struct_words(tid)
        if k == TK['ARRAY']:
            return t.get('length', 0) * self.nwords(t['elem'])
        return 1

    def struct_words(self, tid):
        """word extent of a struct-typed value (member offsets + each
        member's flat word count)."""
        t = self.types.get(tid, {})
        if t.get('kind') != TK['STRUCT']:
            return 0
        mb = self.member_base.get(tid, 0)
        top = 0
        for i in range(t['nmemb']):
            m = self.members[mb + i]
            top = max(top, m['offset'] // 4 + self.nwords(m['type']))
        return top

    def reg_rows(self, tid):
        """RF rows a value of type tid occupies (mat=cols, struct=
        ceil(words/4), everything else 1) — the reg() row count."""
        t = self.types.get(tid, {})
        if t.get('kind') == TK['MAT']:
            return t['cols']
        if t.get('kind') == TK['STRUCT']:
            return (self.struct_words(tid) + 3) // 4
        return 1

    def decor_of(self, iid):
        return self.decor.get(iid, {})

    def type_size(self, tid, depth=0):
        """natural layout size (4a: Function/Private/Workgroup)"""
        if depth > 6:
            raise Fault(FAULT['FWDREF'], 0, 0)
        t = self.types.get(tid)
        if t is None:
            raise Fault(FAULT['FWDREF'], 0, 0)
        k = t['kind']
        if k in (TK['BOOL'], TK['INT'], TK['FLOAT'], TK['VOID']):
            return 4
        if k == TK['VEC']:
            return 4 * t['comps']
        if k == TK['MAT']:
            ct = self.types[t['elem']]
            return 4 * t['cols'] * ct['comps']
        if k == TK['ARRAY']:
            return t['length'] * self.type_size(t['elem'], depth + 1)
        if k == TK['STRUCT']:
            top = 0
            mb = self.member_base[tid]
            for i in range(t['nmemb']):
                m = self.members[mb + i]
                esz = self.type_size(m['type'], depth + 1)
                top = max(top, m['offset'] + esz)
            return top
        if k == TK['PTR']:
            return 16      # tagged vec4 pointer record
        raise Fault(FAULT['TYPE'], 0, 0)

    def align(self, x, a):
        return (x + a - 1) & ~(a - 1)

    # -- per-opcode scan ----------------------------------------------
    def op_type(self, opc, rty, rid, ops, at):
        if opc == OP['TypeVoid']:
            t = dict(kind=TK['VOID'], sign=0, comps=0, cols=0,
                     storage=0, elem=0, nmemb=0, length=0,
                     size=0, stride=0)
        elif opc == OP['TypeBool']:
            t = dict(kind=TK['BOOL'], sign=0, comps=1, cols=0,
                     storage=0, elem=0, nmemb=0, length=0,
                     size=4, stride=0)
        elif opc == OP['TypeInt']:
            width, sign = ops
            if width != 32:
                raise Fault(FAULT['TYPE'], opc, at)
            t = dict(kind=TK['INT'], sign=sign, comps=1, cols=0,
                     storage=0, elem=0, nmemb=0, length=0,
                     size=4, stride=0)
        elif opc == OP['TypeFloat']:
            if ops[0] != 32:
                raise Fault(FAULT['TYPE'], opc, at)
            t = dict(kind=TK['FLOAT'], sign=0, comps=1, cols=0,
                     storage=0, elem=0, nmemb=0, length=0,
                     size=4, stride=0)
        elif opc == OP['TypeVector']:
            elem, n = ops
            if elem not in self.types:
                raise Fault(FAULT['FWDREF'], opc, at)
            if not (1 <= n <= 4):
                raise Fault(FAULT['TYPE'], opc, at)
            t = dict(kind=TK['VEC'], sign=0, comps=n, cols=0,
                     storage=0, elem=elem, nmemb=0, length=0,
                     size=4 * n, stride=0)
        elif opc == OP['TypeMatrix']:
            elem, n = ops
            if elem not in self.types:
                raise Fault(FAULT['FWDREF'], opc, at)
            if not (1 <= n <= 4):
                raise Fault(FAULT['TYPE'], opc, at)
            et = self.types[elem]
            t = dict(kind=TK['MAT'], sign=0, comps=et['comps'], cols=n,
                     storage=0, elem=elem, nmemb=0, length=0,
                     size=4 * n * et['comps'], stride=0)
        elif opc == OP['TypeImage']:
            # §12.3 C/5b: {sampled_type, dim, depth, arrayed, ms,
            # sampled, format, [aq]} — 2D images only, no MSAA, format
            # Unknown (the descriptor record carries the real format);
            # sampled 1 = sampled image, 2 = storage image
            st, dim, depth, arr, ms, smp, fmt = ops[:7]
            if st not in self.types:
                raise Fault(FAULT['FWDREF'], opc, at)
            if self.types[st]['kind'] not in (TK['INT'], TK['FLOAT']):
                raise Fault(FAULT['TYPE'], opc, at)
            # 2D images only, no MSAA; the declared ImageFormat operand
            # (0..41 defined) is informational — the descriptor record's
            # format governs decode, so any legal value is accepted
            if (dim != 1 or depth > 1 or arr > 1 or ms != 0 or
                    smp not in (1, 2) or fmt > 41):
                raise Fault(FAULT['TYPE'], opc, at)
            t = dict(kind=TK['IMG'], sign=depth, comps=arr,
                     cols=smp, storage=0, elem=st, nmemb=0, length=0,
                     size=4, stride=0)
        elif opc == OP['TypeSampler']:
            if ops:
                raise Fault(FAULT['TYPE'], opc, at)
            t = dict(kind=TK['SAMP'], sign=0, comps=0, cols=0,
                     storage=0, elem=0, nmemb=0, length=0,
                     size=4, stride=0)
        elif opc == OP['TypeSampledImage']:
            (it,) = ops
            if it not in self.types:
                raise Fault(FAULT['FWDREF'], opc, at)
            it_ = self.types[it]
            if it_['kind'] != TK['IMG'] or it_['cols'] != 1:
                raise Fault(FAULT['TYPE'], opc, at)
            t = dict(kind=TK['SIMG'], sign=0, comps=0, cols=0,
                     storage=0, elem=it, nmemb=0, length=0,
                     size=4, stride=0)
        elif opc == OP['TypeArray']:
            elem, cid = ops
            if elem not in self.types or cid not in self.consts:
                raise Fault(FAULT['FWDREF'], opc, at)
            length = self.consts[cid][0]
            t = dict(kind=TK['ARRAY'], sign=0, comps=0, cols=0,
                     storage=0, elem=elem, nmemb=0, length=length,
                     size=0, stride=self.decor_of(rid).get('stride', 0))
        elif opc == OP['TypeRuntimeArray']:
            elem = ops[0]
            if elem not in self.types:
                raise Fault(FAULT['FWDREF'], opc, at)
            t = dict(kind=TK['RARRAY'], sign=0, comps=0, cols=0,
                     storage=0, elem=elem, nmemb=0, length=0,
                     size=0, stride=self.decor_of(rid).get('stride', 0))
        elif opc == OP['TypeStruct']:
            if len(self.members) + len(ops) > SHADER_MEMBERS:
                raise Fault(FAULT['WORDS'], opc, at)
            mb = len(self.members)
            self.member_base[rid] = mb
            # builtin members are only legal in the gl_PerVertex
            # shape: member 0 = Position, every later member a
            # dropped builtin (PointSize/ClipDistance/CullDistance)
            bis = [self.mdecor.get((rid, i), {}).get('builtin')
                   for i in range(len(ops))]
            has_bi = any(b is not None for b in bis)
            if has_bi and (bis[0] != BI_GFX['POSITION'] or
                           any(b not in BI_GFX_DROP for b in bis[1:])):
                raise Fault(FAULT['DECOR'], opc, at)
            # members without an Offset decoration take the natural
            # packed layout (each member at the running size total) —
            # carry/borrow structs never carry decorations
            noff = 0
            for i, mt in enumerate(ops):
                if mt not in self.types:
                    raise Fault(FAULT['FWDREF'], opc, at)
                d = self.mdecor.get((rid, i), {})
                mo = d.get('offset', noff)
                self.members.append(dict(type=mt, offset=mo,
                                         mstride=d.get('mstride', 0),
                                         flags=d.get('flags', 0)))
                noff = mo + self.nwords(mt) * 4
            t = dict(kind=TK['STRUCT'], sign=0, comps=0, cols=0,
                     storage=0, elem=0, nmemb=len(ops), length=0,
                     size=0, stride=0, has_bi=has_bi)
        elif opc == OP['TypePointer']:
            sc, elem = ops
            if sc not in SC_OK:
                raise Fault(FAULT['STORAGE'], opc, at)
            if elem not in self.types:
                raise Fault(FAULT['FWDREF'], opc, at)
            t = dict(kind=TK['PTR'], sign=0, comps=0, cols=0,
                     storage=sc, elem=elem, nmemb=0, length=0,
                     size=16, stride=0)
        elif opc == OP['TypeFunction']:
            # G3a-i: non-void returns and parameter lists are legal —
            # the function-type row only needs to exist (the call site
            # carries its own result type)
            for pt in ops:
                if pt not in self.types:
                    raise Fault(FAULT['FWDREF'], opc, at)
            t = dict(kind=TK['FUNC'], sign=0, comps=0, cols=0,
                     storage=0, elem=0, nmemb=0, length=0,
                     size=0, stride=0)
        else:
            raise Fault(FAULT['OPCODE'], opc, at)
        self.types[rid] = t

    def type_id_of(self, kind):
        for i, t in self.types.items():
            if t['kind'] == kind:
                return i
        return -1

    def const_words(self, cid, rty, ops, opc, at):
        """evaluate a constant to its component words (<=16)."""
        if opc == OP['ConstantTrue']:
            return [1]
        if opc == OP['ConstantFalse']:
            return [0]
        if opc == OP['Constant']:
            return list(ops)
        if opc == OP['ConstantNull']:
            n = self.const_count(rty)
            return [0] * n
        if opc == OP['ConstantComposite']:
            out = []
            for c in ops:
                out += self.consts[c]
            if len(out) > CONST_WORDS:
                raise Fault(FAULT['CONST'], opc, at)
            return out
        raise Fault(FAULT['CONST'], opc, at)

    def const_count(self, tid):
        t = self.types.get(tid)
        if t is None:
            raise Fault(FAULT['FWDREF'], 0, 0)
        k = t['kind']
        if k in (TK['BOOL'], TK['INT'], TK['FLOAT'], TK['VOID']):
            return 1
        if k == TK['VEC']:
            return t['comps']
        if k == TK['MAT']:
            return t['cols'] * self.types[t['elem']]['comps']
        if k == TK['ARRAY']:
            return t['length'] * self.const_count(t['elem'])
        if k == TK['STRUCT']:
            return sum(self.const_count(m['type'])
                       for m in self.members[
                           self.member_base[tid]:
                               self.member_base[tid] + t['nmemb']])
        if k == TK['PTR']:
            return 4
        return 1

    def variable(self, rty, rid, ops, at):
        sc = ops[0]
        if sc not in SC_OK:
            raise Fault(FAULT['STORAGE'], OP['Variable'], at)
        t = self.types.get(rty)
        if t is None or t['kind'] != TK['PTR']:
            raise Fault(FAULT['TYPE'], OP['Variable'], at)
        if sc in (SC['UNIFORMCONST'],):
            # §12.3 C/5b: image/sampler/sampled-image vars only —
            # everything else under UniformConstant stays refused
            et = self.types.get(t['elem'])
            if et is None or et['kind'] not in (
                    TK['IMG'], TK['SAMP'], TK['SIMG']):
                raise Fault(FAULT['STORAGE'], OP['Variable'], at)
        d = self.decor_of(rid)
        off = 0
        fl = 0                    # {VF_DROP, VF_REC} for gfx I/O vars
        if len(self.init) >= SHADER_INIT:
            raise Fault(FAULT['REGS'], OP['Variable'], at)
        bi = d.get('builtin')
        gfx_io = self.em != EM['GLCOMPUTE'] and \
            sc in (SC['INPUT'], SC['OUTPUT'])
        if self.em == EM['GLCOMPUTE']:
            # compute accepts only the compute builtins, on any storage
            if bi is not None and bi not in BUILTIN.values():
                raise Fault(FAULT['VAR'], OP['Variable'], at)
        elif gfx_io:
            # graphics interface variable — aperture record layout
            loc = d.get('location')
            rec = drop = False
            et = self.types.get(t['elem'])
            if self.em == EM['VERTEX']:
                if sc == SC['INPUT']:
                    if bi is not None:
                        # VertexIndex/InstanceIndex keep the builtin path
                        if bi not in (BI_GFX['VERTEXINDEX'],
                                      BI_GFX['INSTANCEINDEX']):
                            raise Fault(FAULT['VAR'], OP['Variable'], at)
                    elif loc is None or loc > VARY_LOCS - 1:
                        raise Fault(FAULT['VAR'], OP['Variable'], at)
                    else:
                        off = 16 * loc
                        rec = True
                        self.in_mask |= 1 << loc
                else:                            # VS Output
                    if bi is not None:
                        if bi == BI_GFX['POSITION']:
                            rec = True           # record slot 0
                        elif bi in BI_GFX_DROP:
                            drop = True          # stores dropped/loads 0
                        else:
                            raise Fault(FAULT['VAR'], OP['Variable'], at)
                    elif loc is not None:
                        if loc > VARY_LOCS - 1:
                            raise Fault(FAULT['VAR'], OP['Variable'], at)
                        off = 16 * (1 + loc)
                        rec = True
                        self.out_mask |= 1 << loc
                    elif et is not None and et['kind'] == TK['STRUCT'] \
                            and et.get('has_bi'):
                        # gl_PerVertex block: Position member at slot 0
                        rec = True
                    else:
                        raise Fault(FAULT['VAR'], OP['Variable'], at)
            else:                                # Fragment
                if sc == SC['INPUT']:
                    if bi is not None:
                        if bi == BI_GFX['FRAGCOORD']:
                            rec = True           # record slot 0
                        elif bi not in (BI_GFX['FRONTFACING'],
                                        BI_GFX['HELPERINVOCATION']):
                            raise Fault(FAULT['VAR'], OP['Variable'], at)
                    elif loc is None or loc > VARY_LOCS - 1:
                        raise Fault(FAULT['VAR'], OP['Variable'], at)
                    else:
                        off = 16 * (1 + loc)
                        rec = True
                        self.in_mask |= 1 << loc
                else:                            # FS Output
                    if bi is not None:
                        # G3a-i: FragDepth lands in record slot 8
                        # word 0 (APU_SH_FSOUT_BI); any other builtin
                        # is refused
                        if bi == BI_GFX['FRAGDEPTH'] and \
                                et is not None and \
                                et['kind'] == TK['FLOAT']:
                            off = 16 * VARY_LOCS
                            rec = True
                            self.wr_fdepth = True
                        else:
                            raise Fault(FAULT['VAR'], OP['Variable'],
                                        at)
                    elif loc is None or loc > VARY_LOCS - 1:
                        raise Fault(FAULT['VAR'], OP['Variable'], at)
                    else:
                        off = 16 * loc
                        rec = True
                        self.out_mask |= 1 << loc
            fl = (VF_REC if rec else 0) | (VF_DROP if drop else 0)
        elif bi is not None:
            # builtin decorations have no meaning off the interface in
            # a graphics stage
            raise Fault(FAULT['VAR'], OP['Variable'], at)
        if sc == SC['WORKGROUP']:
            sz = self.type_size(t['elem'])
            off = self.slab
            self.slab += self.align(sz, 16)
        elif sc in (SC['FUNCTION'], SC['PRIVATE']):
            sz = self.type_size(t['elem'])
            off = self.scratch
            self.scratch += self.align(sz, 16)
        self.vars[rid] = dict(storage=sc, set=d.get('set', 0),
                              binding=d.get('binding', 0),
                              builtin=d.get('builtin', 0xFF),
                              off=off, type_id=t['elem'],
                              flags=fl if gfx_io else d.get('flags', 0))
        self.reg(rid, tid=rty)
        self.init.append((self.regmap[rid][1], sc, d.get('builtin', 0xFF),
                          d.get('set', 0), d.get('binding', 0), off, fl))

    # -- main walk ----------------------------------------------------
    def scan(self):
        w = self.w
        if len(w) < 5 or w[0] != MAGIC:
            raise Fault(FAULT['MAGIC'], 0, 0)
        ver = (w[1] >> 16) & 0xFF
        if not (0 <= ver <= 6):
            raise Fault(FAULT['VERSION'], 0, 1)
        bound = w[3]
        if bound > SHADER_IDS:
            raise Fault(FAULT['BOUND'], 0, 3)
        at = 5
        while at < len(w):
            w0 = w[at]
            wc = w0 >> 16
            opc = w0 & 0xFFFF
            if wc == 0 or at + wc > len(w):
                raise Fault(FAULT['WORDS'], opc, at)
            ops = w[at + 1: at + wc]
            if opc not in ACCEPT:
                raise Fault(FAULT['OPCODE'], opc, at)
            if opc in FRAG_ONLY and self.em != EM['FRAGMENT']:
                raise Fault(FAULT['OPCODE'], opc, at)
            if opc in STAGE_BOUND and wc - 1 > OPN_MAX:
                raise Fault(FAULT['WORDS'], opc, at)
            h = getattr(self, 'h_%d' % opc, None)
            if h is None:
                h = self.h_default
            h(opc, ops, at)
            # a merge op applies to the immediately following
            # instruction only (§7c commit rule)
            self.merge_pending = opc in (246, 247)
            at += wc
        if self.entry is None:
            raise Fault(FAULT['ENTRY'], 0, 0)
        if self.in_function:
            raise Fault(FAULT['WORDS'], 0, len(w) - 1)
        if self.entry['func'] not in self.funcs:
            raise Fault(FAULT['ENTRY'], 0, 0)
        for at, tgt in self.branches:
            if tgt not in self.labels:
                raise Fault(FAULT['BRANCH'], 249, at)
        # deferred OpFunctionCall targets (callee bodies may follow the
        # caller — a forward reference is legal module order)
        for at, fid in self.calls:
            if fid not in self.funcs:
                raise Fault(FAULT['FUNC'], 57, at)
        return self

    # -- handlers -----------------------------------------------------
    def h_default(self, opc, ops, at):
        pass

    def h_17(self, opc, ops, at):       # OpCapability
        if ops[0] not in CAP_OK:
            raise Fault(FAULT['CAP'], opc, at)

    def h_14(self, opc, ops, at):       # OpMemoryModel
        if tuple(ops) != MEM_OK:
            raise Fault(FAULT['MEMMODEL'], opc, at)

    def h_15(self, opc, ops, at):       # OpEntryPoint
        if ops[0] not in ENTRY_MODEL_OK:
            raise Fault(FAULT['ENTRY'], opc, at)
        self.entry_count += 1
        if self.entry_count > 1:
            raise Fault(FAULT['TWO_ENTRY'], opc, at)
        self.em = ops[0]
        self.entry = dict(func=ops[1], name_bytes=ops[2:])

    def h_16(self, opc, ops, at):       # OpExecutionMode
        if ops[1] in (7, 12, 14, 15, 16):
            # OriginUpperLeft / DepthReplacing / DepthGreater /
            # DepthLess / DepthUnchanged — accepted no-ops (G3a-i:
            # fs_late comes from the module content, not the mode)
            return
        if ops[1] != 17:                # LocalSize
            raise Fault(FAULT['EXECMODE'], opc, at)
        lx, ly, lz = ops[2], ops[3], ops[4]
        if lx * ly * lz > MAX_LOCAL or lx * ly * lz == 0:
            raise Fault(FAULT['LOCALSIZE'], opc, at)
        self.localsize = (lx, ly, lz)

    def h_71(self, opc, ops, at):       # OpDecorate
        tid, dec = ops[0], ops[1]
        if dec not in DEC_ID_OK:
            raise Fault(FAULT['DECOR'], opc, at)
        d = self.decor.setdefault(tid, {})
        if dec == DEC['Binding']:
            d['binding'] = ops[2]
        elif dec == DEC['DescriptorSet']:
            d['set'] = ops[2]
        elif dec == DEC['Builtin']:
            if ops[2] not in BUILTIN_OK:
                raise Fault(FAULT['DECOR'], opc, at)
            d['builtin'] = ops[2]
            # marker bit (0 is a legal builtin id, so the field alone
            # cannot distinguish "Position" from "undecorated")
            d['flags'] = d.get('flags', 0) | DF_BI
        elif dec == DEC['ArrayStride']:
            d['stride'] = ops[2]
            d['aux1'] = ops[2]
        elif dec == DEC['Location']:
            d['location'] = ops[2]
            d['aux1'] = ops[2]          # decor word1 carries the value
            d['flags'] = d.get('flags', 0) | DF_LOC
        else:
            d['flags'] = d.get('flags', 0) | (1 << (dec % 8))

    def h_72(self, opc, ops, at):       # OpMemberDecorate
        tid, m, dec = ops[0], ops[1], ops[2]
        if dec not in DEC_MBR_OK:
            raise Fault(FAULT['DECOR'], opc, at)
        if (tid, m) not in self.mdecor and \
           len(self.mdecor) >= MDECOR_MAX:
            raise Fault(FAULT['DECOR'], opc, at)
        d = self.mdecor.setdefault((tid, m), {})
        if dec == DEC['Offset']:
            d['offset'] = ops[3]
        elif dec == DEC['MatrixStride']:
            d['mstride'] = ops[3]
        elif dec == DEC['Builtin']:
            # gl_PerVertex members: Position (record slot 0) or the
            # dropped region (PointSize/ClipDistance/CullDistance)
            if ops[3] not in MBR_BI_OK:
                raise Fault(FAULT['DECOR'], opc, at)
            d['builtin'] = ops[3]
            if ops[3] in BI_GFX_DROP:
                d['flags'] = d.get('flags', 0) | MF_DROP
        else:
            d['flags'] = d.get('flags', 0) | (1 << (dec % 8))

    def h_19(self, opc, ops, at):       # types (19..33)
        # type ids are not RF values; they index the type table only
        self.op_type(opc, 0, ops[0], ops[1:], at)

    h_20 = h_19
    h_21 = h_19
    h_22 = h_19
    h_23 = h_19
    h_24 = h_19
    h_25 = h_19                          # TypeImage
    h_26 = h_19                          # TypeSampler
    h_27 = h_19                          # TypeSampledImage
    h_28 = h_19
    h_29 = h_19
    h_30 = h_19
    h_32 = h_19
    h_33 = h_19

    def h_const(self, opc, ops, at):
        rty, rid = ops[0], ops[1]
        vals = self.const_words(rid, rty, ops[2:], opc, at)
        self.consts[rid] = vals
        self.const_tid[rid] = rty
        self.reg(rid, tag=1, tid=rty, aux=len(vals))

    h_41 = h_const
    h_42 = h_const
    h_43 = h_const
    h_44 = h_const
    h_46 = h_const
    h_48 = h_const
    h_49 = h_const
    h_50 = h_const
    h_51 = h_const

    def h_52(self, opc, ops, at):       # OpSpecConstantOp
        raise Fault(FAULT['SPEC'], opc, at)

    def h_11(self, opc, ops, at):       # OpExtInstImport — GLSL.std.450
        name = b''.join(struct.pack('<I', x) for x in ops[1:])
        name = name.split(b'\0')[0]
        if name != b'GLSL.std.450':
            raise Fault(FAULT['OPCODE'], opc, at)
        self.glsl_id = ops[0]

    def h_12(self, opc, ops, at):       # OpExtInst — GLSL.std.450 subset
        if ops[2] != self.glsl_id or ops[3] not in EXT450_OK:
            raise Fault(FAULT['OPCODE'], ops[3], at)
        self.reg(ops[1], tid=ops[0])

    def h_59(self, opc, ops, at):       # OpVariable
        if len(ops) > 3:
            raise Fault(FAULT['VAR'], opc, at)   # initializer unsupported
        self.variable(ops[0], ops[1], ops[2:], at)

    def h_54(self, opc, ops, at):       # OpFunction
        if self.in_function:
            raise Fault(FAULT['WORDS'], opc, at)
        if len(self.forder) >= MAX_FUNCS:
            raise Fault(FAULT['FUNC'], opc, at)
        self.in_function = True
        self.fn_head = True             # params legal until first label
        self.func_result = ops[1]       # function ids are not RF regs
        self.cur_func = ops[1]
        self.funcs[ops[1]] = dict(off=at, rty=ops[0], params=[])
        self.forder.append(ops[1])
        if self.entry is not None and ops[1] == self.entry['func']:
            self.entry_off = at

    def h_55(self, opc, ops, at):       # OpFunctionParameter rty rid
        if not self.in_function or not self.fn_head:
            raise Fault(FAULT['FUNC'], opc, at)
        f = self.funcs[self.cur_func]
        if len(f['params']) >= MAX_PARAMS:
            raise Fault(FAULT['FUNC'], opc, at)
        f['params'].append((ops[1], ops[0]))
        self.reg(ops[1], tid=ops[0])
        if len(f['params']) == 1:
            f['pbase'] = self.regmap[ops[1]][1]

    def h_56(self, opc, ops, at):       # OpFunctionEnd
        self.in_function = False
        self.fn_head = False
        self.cur_func = 0

    def h_57(self, opc, ops, at):       # OpFunctionCall rty rid f a*
        if not self.in_function:
            raise Fault(FAULT['FUNC'], opc, at)
        # the callee may be declared later in the module — the
        # existence check is deferred to the post-scan pass
        self.calls.append((at, ops[2]))
        if self.types.get(ops[0], {}).get('kind') != TK['VOID']:
            self.reg(ops[1], tid=ops[0])

    def h_254(self, opc, ops, at):      # OpReturnValue v
        if not self.in_function:
            raise Fault(FAULT['WORDS'], opc, at)

    def h_252(self, opc, ops, at):      # OpKill — sets the late flag
        self.has_kill = True

    h_4416 = h_252                      # OpTerminateInvocation
    h_5380 = h_252                      # OpDemoteToHelperInvocation

    def h_248(self, opc, ops, at):      # OpLabel — block table
        self.labels[ops[0]] = at
        self.fn_head = False
        # scan-order pop: a label equal to an open loop's merge target
        # leaves that loop scope (and anything nested inside it)
        while self.loops and self.loops[-1][0] == ops[0]:
            self.loops.pop()

    def qbranch(self, at, tgt):
        if len(self.branches) >= BRANCH_MAX:
            raise Fault(FAULT['BRANCH'], 249, at)
        self.branches.append((at, tgt))

    def h_249(self, opc, ops, at):      # OpBranch — any direction
        self.qbranch(at, ops[0])

    def _merge_free_ok(self, targets):
        """§7c commit rule: a merge-less BranchConditional/Switch is
        accepted only when one of its targets is the innermost open
        loop's merge or continue block."""
        if self.merge_pending:
            return True
        if not self.loops:
            return False
        m, c = self.loops[-1]
        return any(t == m or t == c for t in targets)

    def h_250(self, opc, ops, at):      # OpBranchConditional
        tg = [ops[1], ops[2]]
        if not self._merge_free_ok(tg):
            raise Fault(FAULT['BRANCH'], opc, at)
        for t in tg:
            self.qbranch(at, t)

    def h_251(self, opc, ops, at):      # OpSwitch
        tg = [ops[1]] + ops[3::2]       # default + pair labels
        if not self._merge_free_ok(tg):
            raise Fault(FAULT['BRANCH'], opc, at)
        for t in tg:
            self.qbranch(at, t)

    def h_246(self, opc, ops, at):      # OpLoopMerge M C [control]
        self.qbranch(at, ops[0])
        self.qbranch(at, ops[1])
        if len(self.loops) >= 8:        # CfDepth — RTL commit stack
            raise Fault(FAULT['BRANCH'], opc, at)
        self.loops.append((ops[0], ops[1]))

    def h_247(self, opc, ops, at):      # OpSelectionMerge M [control]
        self.qbranch(at, ops[0])

    def h_245(self, opc, ops, at):      # OpPhi rty rid (value,parent)*
        if len(ops) < 4 or (len(ops) - 2) % 2:
            raise Fault(FAULT['BRANCH'], opc, at)
        pairs = [(ops[2 + 2 * k], ops[3 + 2 * k])
                 for k in range((len(ops) - 2) // 2)]
        if len(pairs) > PHI_MAXPAIRS:
            raise Fault(FAULT['BRANCH'], opc, at)
        for v, p in pairs:
            self.qbranch(at, p)
        self.phis.append((ops[1], pairs))
        self.reg(ops[1], tid=ops[0])

    def h_result(self, opc, ops, at):
        """instructions with (result-type, result-id) prefix"""
        self.reg(ops[1], tid=ops[0])

    def h_noresult(self, opc, ops, at):
        pass

    # result-bearing execution instructions
    for _o in [61, 65, 66, 68, 79, 80, 81, 82, 84, 109, 110, 111, 112,
               124, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135,
               136, 137, 138, 139, 142, 143, 144, 145, 146, 147, 148,
               164, 165, 166, 167, 168, 169, 170, 171, 172, 173, 174,
               175, 176, 177, 178, 179, 180, 182, 183, 184, 186, 188,
               190, 194, 195, 196, 197, 198, 199, 200,
               # G2b: implicit LOD + quad-derivative result registers
               87, 207, 208, 209, 210, 211, 212, 213, 214, 215,
               # §12.3 C/5b: image ops with a result register
               86, 88, 95, 98, 100, 103, 104, 106,
               # G3a-i: undef/copy, dynamic vector ops, fp/int
               # remainder + carry/borrow/wide-mul struct results,
               # reductions, fp tests, unordered compares, bitfield ops
               1, 77, 78, 83, 140, 141, 149, 150, 151, 152, 154, 155,
               156, 157, 181, 185, 187, 189, 191,
               201, 202, 203, 204, 205,
               # G3a-i: atomics with a result (AtomicStore has none),
               # helper-invocation query
               227, 229, 230, 232, 233, 234, 235, 236, 237, 238, 239,
               240, 241, 242, 5381]:
        exec('h_%d = h_result' % _o)

    h_99 = h_noresult                        # OpImageWrite
    h_228 = h_noresult                       # OpAtomicStore

    # ---- table emit --------------------------------------------------
    def type_words(self, tid):
        t = self.types.get(tid)
        if t is None:
            return [0, 0, 0]
        w0 = (t['kind'] | (t['sign'] << 4) | (t['comps'] << 5) |
              (t['cols'] << 8) | (t['storage'] << 11) | (t['elem'] << 15) |
              (t['nmemb'] << 25) |
              (TY_HAS_MBI if t.get('has_bi') else 0))
        w1 = (self.member_base.get(tid, 0) & 0xFFFF) | \
             ((t['length'] & 0xFFFF) << 16)
        w2 = (self.size_of(tid) & 0xFFFF) | ((t['stride'] & 0xFFFF) << 16)
        return [w32(w0), w32(w1), w32(w2)]

    def size_of(self, tid):
        t = self.types[tid]
        if t['kind'] in (TK['ARRAY'],):
            try:
                return t['length'] * self.size_of(t['elem'])
            except Fault:
                return 0
        if t['kind'] == TK['STRUCT']:
            try:
                return self.type_size(tid)
            except Fault:
                return 0
        return t['size']

    def member_words(self, i):
        m = self.members[i]
        return [w32(m['offset'] | (m['mstride'] << 16)),
                w32(m['flags'] | (m['type'] << 8))]

    def const_tab(self, iid):
        return (self.consts.get(iid, []) + [0] * CONST_WORDS)[:CONST_WORDS]

    def decor_words(self, iid):
        d = self.decor.get(iid)
        if d is None:
            return [0, 0]
        return [w32(d.get('set', 0) | (d.get('binding', 0) << 8) |
                    (d.get('builtin', 0xFF) << 16) |
                    (d.get('flags', 0) << 24)),
                w32(d.get('aux1', 0))]

    def var_words(self, iid):
        v = self.vars.get(iid)
        if v is None:
            return [0, 0]
        # w0 = {flags[3:0], builtin[7:0], binding[7:0], set[7:0],
        #       storage[3:0]} — RTL packs de_rdata[27:24] (flags[3:0])
        # at bits 31:28; flag bits 4..7 are not carried into the row.
        return [w32(v['storage'] | (v['set'] << 4) | (v['binding'] << 12) |
                    (v['builtin'] << 20) | ((v['flags'] & 0xF) << 28)),
                w32(v['off'] | (v['type_id'] << 16))]

    def regmap_word(self, iid):
        r = self.regmap.get(iid)
        if r is None:
            return 0
        # {tag[31:30], aux[29:26], type_id[25:16], idx[15:0]}
        return w32((r[0] << 30) | ((r[3] & 0xF) << 26) |
                   ((r[2] & 0x3FF) << 16) | (r[1] & 0xFFFF))

    def init_words(self, i):
        idx, sc, bi, st, bd, off, fl = self.init[i]
        return [w32(idx | (sc << 16) | ((bi & 0xFF) << 20) |
                    ((fl & 0xF) << 28)),
                w32(st | (bd << 8) | (off << 16))]

    def block_word(self, iid):
        return w32(self.labels.get(iid, 0) | (0x8000 if iid in
                                              self.labels else 0))

    def phi_words(self, rid):
        """phi row for result id `rid` (§7c): word0 = pair count,
        word k (1..PHI_MAXPAIRS) = {parent[31:16], value[15:0]}."""
        pr = None
        for (r2, pairs) in self.phis:
            if r2 == rid:
                pr = pairs
        if pr is None:
            return [0] * PHI_WORDS
        out = [w32(len(pr))]
        for k in range(PHI_MAXPAIRS):
            if k < len(pr):
                v, p = pr[k]
                out.append(w32((v & 0xFFFF) | ((p & 0xFFFF) << 16)))
            else:
                out.append(0)
        return out

    def entry_words(self):
        # graphics stages have no LocalSize: lx=ly=lz=1 and the
        # execution model + Location masks ride the entry record's
        # spare half-words (w2[31:16] = {out,in}_mask, w3[31:28] = em)
        lx, ly, lz = self.localsize if self.em == EM['GLCOMPUTE'] \
            else (1, 1, 1)
        # G3a-i FS sideband: w3[27] = fs_late (kills or FragDepth → the
        # rasterizer defers the depth test), w3[26] = writes FragDepth
        # (shmod en_wdata packs {em[31:28], late[27], fdepth[26],
        # pad[25:16], slab[15:0]})
        fs_late = 1 if (self.wr_fdepth or self.has_kill) else 0
        return [w32((self.entry_off & 0xFFFF) | (self.n_regs << 16)),
                w32(lx | (ly << 8) | (lz << 16) |
                    (len(self.init) << 24)),
                w32(self.scratch | (self.in_mask << 16) |
                    (self.out_mask << 24)),
                w32(self.slab | (fs_late << 27) | (self.wr_fdepth << 26)
                    | (self.em << 28))]

    def emit_tab(self, path):
        """flat list of (table, addr, word) triples the TB compares."""
        lines = []
        for iid in range(SHADER_IDS):
            for j, v in enumerate(self.type_words(iid)):
                lines.append('T %d %d %08x' % (iid, j, v))
            for j, v in enumerate(self.const_tab(iid)):
                lines.append('C %d %d %08x' % (iid, j, v))
            for j, v in enumerate(self.decor_words(iid)):
                lines.append('D %d %d %08x' % (iid, j, v))
            for j, v in enumerate(self.var_words(iid)):
                lines.append('V %d %d %08x' % (iid, j, v))
            lines.append('R %d 0 %08x' % (iid, self.regmap_word(iid)))
            lines.append('B %d 0 %08x' % (iid, self.block_word(iid)))
            for j, v in enumerate(self.phi_words(iid)):
                lines.append('P %d %d %08x' % (iid, j, v))
        for i in range(len(self.members)):
            for j, v in enumerate(self.member_words(i)):
                lines.append('M %d %d %08x' % (i, j, v))
        # G3a-i function table: F <fid> 0 = the function row keyed by
        # function id {nparams[31:28], param-table base[27:16],
        # OpFunction word off[15:0]} — the table base is the function
        # ordinal * MAX_PARAMS (shmod's fn_pb).  Q <pbase+ord> 0 =
        # param row {4'h0, value-rows[11:8], first RF row[7:0]}.
        for fi, fid in enumerate(self.forder):
            f = self.funcs[fid]
            pbase = fi * MAX_PARAMS
            lines.append('F %d 0 %08x' %
                         (fid, w32((len(f['params']) << 28) |
                                   (pbase << 16) | f['off'])))
            for p, (pid, pt) in enumerate(f['params']):
                lines.append('Q %d 0 %08x' %
                             (pbase + p,
                              w32((self.reg_rows(pt) << 8) |
                                  (self.regmap[pid][1] & 0xFF))))
        for i in range(len(self.init)):
            for j, v in enumerate(self.init_words(i)):
                lines.append('I %d %d %08x' % (i, j, v))
        for j, v in enumerate(self.entry_words()):
            lines.append('E 0 %d %08x' % (j, v))
        with open(path, 'w') as f:
            f.write('\n'.join(lines) + '\n')


def read_spv(path):
    data = open(path, 'rb').read()
    return list(struct.unpack('<%dI' % (len(data) // 4), data))


def main():
    args = sys.argv[1:]
    emit = None
    if '--emit-tab' in args:
        i = args.index('--emit-tab')
        emit = args[i + 1]
        del args[i:i + 2]
    info = '--info' in args
    sc = Scanner(read_spv(args[0]))
    try:
        sc.scan()
        fault = (0, 0, 0)
    except Fault as f:
        fault = (f.code, f.opcode, f.word)
    if info or True:
        print('fault=%s(%d) opcode=%d word=%d' %
              (FAULT_NAME[fault[0]], fault[0], fault[1], fault[2]))
        print('entry=%s localsize=%s scratch=%d slab=%d regs=%d '
              'consts=%d vars=%d members=%d' %
              (sc.entry_words()[0] if sc.entry else None,
               sc.localsize, sc.scratch, sc.slab, sc.n_regs,
               sc.n_consts, len(sc.vars), len(sc.members)))
    if emit and fault[0] == 0:
        sc.emit_tab(emit)
    return fault[0]


if __name__ == '__main__':
    sys.exit(0 if main() == 0 else 1)
