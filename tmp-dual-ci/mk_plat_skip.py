"""R3a cont.51 soft ladder: SI/DI to post-hsm success WFI (peeled stubs).

Promotion (do not grow VAs without inventory):
  architecture/multi-threading/soft-ladder/README.md
  architecture/multi-threading/soft-ladder/inventory.yaml
  architecture/multi-threading/soft-ladder/CONT-FULL-MAP.md
Buckets: B1 RTL DI residual | B2 firmware policy | B3 sim harness only.
Order: B1 first → B3 SUCCESS → B2 source profile → retire this script.

Ordered-path soft/peel env (2026-08-08 cookie soaks on work-ver-smt2):
  Default production soft ELF:
    - natural SA/freelist spins (spin peeled)
    - natural atomic_cmpxchg LR/SC (cmpx peeled)
    - natural hart_init CSR probes (csr peeled)
    - soft malloc/zalloc/free + heap space stubs (freelist open)
    - nop dual c.mv @7312/14 (cmv still open on OpenSBI)
  Bisect restores:
    SOFT_SPIN=1   SA/heap spin NOP4
    SOFT_CMPX=1   ld/sd atomic_cmpxchg shim
    SOFT_CSR=1    CSR probe cut cd86→cd0e
    PEEL_CMV=1    natural c.mv (FAIL cookie 2026-08-08 — keep nops default)
    PEEL_MALLOC=1 real malloc/zalloc/free

Critical fix vs cont.16: do NOT patch 0x996 with j lottery.
0x996 is fall-through after sbi_hsm_hart_start_finish — patching it caused
an infinite coldboot loop. Instead redirect 0x752 bnez → lottery directly,
and use 0x996 for success WFI cookie.

cont.21: _trap_handler @0x3d8 assumed t1 set by _start_hang @0x3c8, but mtvec
points at 0x3d8 — so exception dump used garbage t1 (store misalign mcause=6).
Cave re-forms t1=0x80001000 then dumps mepc/mcause/mtval. Real domain_init on
cont.30: peel real putc + domain_dump_all; keep heap freelist soft; global soft SA.
cont.31: hart_init bisect — keep stub0; real peel blocked (soft caves inside hart_init body 0xED00..0xEF70).
cont.32: relocate soft caves into stubbed fn bodies so hart_init text stays intact:
  SA → pmu body @2C90; printf → domain_finalize @BAB0; trap → domain_finalize @BB40.
  hang/success stay at hart_hang/switch_mode (outside hart_init).
cont.33: peel real sbi_hart_init; soft-skip CSR expected-trap probe tail
  (after memset @cd86 → reinit @cd0e). Dual-issue races probe CSR with
  csrw mtvec so expected-trap never sees the illegal (mtvec already restored).
cont.34: free domain_finalize body — move printf+trap caves into heap_used /
  hsm_start_finish bodies. domain_finalize alone → 51b1dead; console_init
  alone → mepc=0x80042870 mcause=2 (fn ptr into .bss). Keep both stub0.
cont.35: soft domain_finalize (domain_finalized=1, ret0); real console_init
  with device jalr soft-skipped (c.li a0,0 @ab6a). Real domain table walk still
  fails (hsm_hart_start / platform residual).
cont.36: soft stub sbi_hsm_hart_start (ret0) — needed for any real domain walk
  that secondary-starts harts; real domain walk still residual (platform/table).
cont.37: trap cave → pmu @2D00 (free hsm_start_finish text). Domain bisect:
  table load OK; walk body @bb20+ poisons ecall_init s1. Real printf still
  mepc=0x12eb2 mcause=6. Real start_finish needs HSM state=START_PENDING.
cont.38: domain walk pin @bb5c..bb70 (scratch-table ld). Real domain_finalize
  through assigned-bit check, then j bbca (set domain_finalized + restore).
  Soft-skip platform jalr (c.li a0,0 @bac4). Skip hartindex→scratch ld.
cont.39: fine bisect — scratch-table ld @bb64/66 is GREEN; poison starts at
  ld domain_hart_ptr_offset @bb6a (or rest of walk). Cut advances bb5c→bb68.
cont.40: full domain walk green if *domain_hart_ptr_offset=0 (sd zero,0(s7)
  @bb20 after s7 formed). Soft-zero ptr; keep platform jalr skip.
cont.41: fix domain soft-zero CF (j helper: sd zero; j bb2c). Soft start_finish:
  fake cmpxchg old=2, skip switch_mode, restore+ret (no payload handoff).
cont.42: drop soft-zero fall-through; restore natural bb20 (c.sd s9; j bb2c)
  and cut@bb68→bbca (cont.39 style, keeps soft finish). Soft heap freelist
  returns free=2047 / used=0 / scratch_used=0 instead of plain stub0.
cont.43: domain multi-iter after bb24 residual (keep cut@bb68).
cont.44: FDT lenp DI residual (keep soft printf).
cont.45: peel real sbi_hsm_hart_start (stub0 ret0 → natural). Domain cut
  still skips assigned-body hsm calls; other coldboot callers OK under DI.
cont.46: peel past cut@bb68 — real ld domain_hart_ptr_offset (a4←*s7) then
  j bbca. Assigned body still skipped. Natural multi-iter still poisons ecall.
cont.47: real sbi_scratch_alloc_offset (retire soft SA cave). Soft-skip
  spin_lock/unlock inside SA (DI AMO residual → mepc=0x2). Memset path kept.
cont.48: deeper start_finish — fake cmpx via local cave (keep global
  atomic_cmpxchg natural); real success path through atomic_write; cut before
  sbi_hart_switch_mode → FINISH_RET (still no payload handoff).
cont.49: real sbi_heap_free_space (nop its spin lock/unlock). Real jal
  sbi_hart_switch_mode from finish; soft switch_mode entry → success cookie
  WFI (payload handoff still soft). Real atomic_cmpxchg still DI-stuck (LR/SC).
cont.50: soft atomic_cmpxchg as non-LR/SC ld/bne/sd (real semantics); finish
  uses natural jal cmpxchg. Relocate soft printf → pmu @2C98; real
  sbi_heap_used_space (nop locks). Domain multi-iter still residual.
cont.51: real sbi_scratch_used_space (nop spin). Soft switch_mode natural
  prologue then fall into success cookie. Domain multi-iter (a4=0) is green
  if ecall_init soft — pin: multi-iter poisons ecall table/s1; keep real ecall
  + domain ld-hart_ptr cut for now.
"""
from pathlib import Path
import os
import struct
import subprocess

SRC = Path("tmp-dual-ci/fw_payload_diag.elf")
DST = Path("tmp-dual-ci/fw_payload_r3a_c15_plat_skip.elf")
BASE, LIMIT = 0x80007550, 0x80007588
SETUP, SETUP_LIMIT = 0x800071e4, 0x80007250
# Caves in permanently-stubbed bodies (not inside peeled functions).
HANG = 0x8000ef4c  # sbi_hart_hang (intentional overwrite)
SUCCESS = 0x8000ef70  # sbi_hart_switch_mode prologue
# cont.37: was hsm_start_finish @F660; now pmu body after soft SA @2C90
TRAP_CAVE = 0x80002D00
A0, A5, S1, S2, S3, S4, S5, S6, T0, T1, SP, RA = 10, 15, 9, 18, 19, 20, 21, 22, 5, 6, 2, 1


def _env_peel(name: str) -> bool:
    v = os.environ.get(name, "").strip().lower()
    return v in ("1", "true", "yes", "on")


PEEL_CMV = _env_peel("PEEL_CMV")
# Default soft-stub malloc/zalloc/free (freelist DI residual on dual-hart smt2).
PEEL_MALLOC = _env_peel("PEEL_MALLOC")
print(
    "peel flags: "
    f"SOFT_SPIN={int(_env_peel('SOFT_SPIN'))} "
    f"SOFT_CMPX={int(_env_peel('SOFT_CMPX'))} "
    f"SOFT_CSR={int(_env_peel('SOFT_CSR'))} "
    f"PEEL_CMV={int(PEEL_CMV)} PEEL_MALLOC={int(PEEL_MALLOC)}"
)


def segs_of(data):
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    segs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        if struct.unpack_from("<I", data, o)[0] != 1:
            continue
        p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<QQQQQQ", data, o + 8)
        segs.append((p_offset, p_vaddr, p_filesz))
    return segs


def vf(segs, va):
    for off, v, fs in segs:
        if v <= va < v + fs:
            return off + (va - v)
    raise ValueError(hex(va))


def enc_i(imm, bits):
    if imm < 0:
        imm = (1 << bits) + imm
    return imm & ((1 << bits) - 1)


def addi(rd, rs1, imm12):
    return (enc_i(imm12, 12) << 20) | (rs1 << 15) | (rd << 7) | 0x13


def addiw(rd, rs1, imm12):
    return (enc_i(imm12, 12) << 20) | (rs1 << 15) | (rd << 7) | 0x1B


def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x37


def slli(rd, rs1, shamt):
    return (shamt << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x13


def auipc(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | (rd << 7) | 0x17


def ld(rd, rs1, imm12):
    return (enc_i(imm12, 12) << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x03


def sd(rs2, rs1, imm12):
    imm = enc_i(imm12, 12)
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (3 << 12) | ((imm & 0x1F) << 7) | 0x23


def sw(rs2, rs1, imm12):
    imm = enc_i(imm12, 12)
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12) | ((imm & 0x1F) << 7) | 0x23


def jalr(rd, rs1, imm12):
    return (enc_i(imm12, 12) << 20) | (rs1 << 15) | (rd << 7) | 0x67


def jal(rd, pc, target):
    imm = (target - pc) & 0x1FFFFF
    return (
        (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3FF) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xFF) << 12)
        | (rd << 7)
        | 0x6F
    )


def blt(rs1, rs2, pc, target):
    imm = (target - pc) & 0x1FFF
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (4 << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
    )


def bge(rs1, rs2, pc, target):
    imm = (target - pc) & 0x1FFF
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (5 << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
    )


def bne(rs1, rs2, pc, target):
    imm = (target - pc) & 0x1FFF
    return (
        (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3F) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (1 << 12)
        | (((imm >> 1) & 0xF) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
    )


def c_beqz(rs1_full, pc, target):
    o = target - pc
    assert o % 2 == 0 and -256 <= o <= 254, hex(o)
    rs1p = rs1_full - 8
    b = lambda n: (o >> n) & 1
    w = 0b110 << 13
    w |= b(8) << 12
    w |= (b(4) << 1 | b(3)) << 10
    w |= rs1p << 7
    w |= (b(7) << 1 | b(6)) << 5
    w |= (b(2) << 1 | b(1)) << 3
    w |= b(5) << 2
    w |= 0b01
    return w & 0xFFFF


def c_j(pc, target):
    o = target - pc
    assert o % 2 == 0 and -2048 <= o <= 2046, hex(o)
    b = lambda n: (o >> n) & 1
    w = 0b101 << 13
    w |= b(11) << 12
    w |= b(4) << 11
    w |= (b(9) << 1 | b(8)) << 9
    w |= b(10) << 8
    w |= b(6) << 7
    w |= b(7) << 6
    w |= (b(3) << 2 | b(2) << 1 | b(1)) << 3
    w |= b(5) << 2
    w |= 0b01
    return w & 0xFFFF


def auipc_addi(rd, pc, target):
    for imm20 in range(-0x80000, 0x80000):
        base = pc + (imm20 << 12)
        imm12 = target - base
        if -2048 <= imm12 <= 2047:
            return auipc(rd, imm20 & 0xFFFFF), addi(rd, rd, imm12)
    raise ValueError(f"cannot form {target:#x} from {pc:#x}")


def stub0(data, segs, va):
    struct.pack_into("<H", data, vf(segs, va), 0x4501)
    struct.pack_into("<H", data, vf(segs, va + 2), 0x8082)


data = bytearray(SRC.read_bytes())
segs = segs_of(data)
v7588 = struct.unpack_from("<I", data, vf(segs, 0x80007588))[0]

# --- 0) cont.21: fix _trap_handler t1 base before DRAM dump ---
# mtvec = 0x800003d8 skips _start_hang t1 setup; form t1=0x80001000 in cave.
struct.pack_into("<I", data, vf(segs, 0x800003D8), jal(0, 0x800003D8, TRAP_CAVE))
tpc = TRAP_CAVE
tseq = []


def t4(w):
    global tpc
    tseq.append((tpc, w & 0xFFFFFFFF))
    tpc += 4


t4(lui(T1, 0x80))
t4(addiw(T1, T1, 1))
t4(slli(T1, T1, 12))  # t1 = 0x80001000
t4(0x341022F3)  # csrr t0, mepc
t4(0x00533023)  # sd t0, 0(t1)
t4(0x342022F3)  # csrr t0, mcause
t4(0x00533423)  # sd t0, 8(t1)
t4(0x343022F3)  # csrr t0, mtval
t4(0x00533823)  # sd t0, 16(t1)
t4(0x00233C23)  # sd sp, 24(t1)
t4(0x02833023)  # sd s0, 32(t1)
t4(0x03233423)  # sd s2, 40(t1)
t4(0x02133823)  # sd ra, 48(t1)
t4(0x02933C23)  # sd s1, 56(t1)
wfi_t = tpc
t4(0x10500073)
t4(jal(0, tpc, wfi_t))
for p, w in tseq:
    struct.pack_into("<I", data, vf(segs, p), w)
print(f"trap cave {hex(TRAP_CAVE)}..{hex(tpc)} (t1=0x80001000 dump)")

# --- 1) plat_hc=2 epilogue ---
words = []
pc = BASE


def emit(w):
    global pc
    words.append((pc, w & 0xFFFFFFFF))
    pc += 4


emit(addi(T0, 0, 2))
w0, w1 = auipc_addi(T1, pc, 0x80040438)
emit(w0)
emit(w1)
emit(sw(T0, T1, 0))
emit(ld(S1, SP, 88))
emit(ld(S3, SP, 72))
emit(ld(S4, SP, 64))
emit(ld(S5, SP, 56))
emit(ld(S6, SP, 48))
emit(addi(A0, S2, 0))
emit(ld(S2, SP, 80))
emit(ld(RA, SP, 104))
emit(addi(SP, SP, 112))
emit(jalr(0, RA, 0))
assert pc == LIMIT
for p, w in words:
    struct.pack_into("<I", data, vf(segs, p), w)

struct.pack_into("<H", data, vf(segs, 0x80007494), c_beqz(10, 0x80007494, BASE))
struct.pack_into("<I", data, vf(segs, 0x80007496), bge(0, 15, 0x80007496, BASE) & 0xFFFFFFFF)
struct.pack_into("<H", data, vf(segs, 0x800075B2), c_j(0x800075B2, BASE))
struct.pack_into("<I", data, vf(segs, 0x8000745C), blt(10, 0, 0x8000745C, BASE) & 0xFFFFFFFF)
struct.pack_into("<I", data, vf(segs, 0x80007472), blt(10, 0, 0x80007472, BASE) & 0xFFFFFFFF)
assert struct.unpack_from("<I", data, vf(segs, 0x80007588))[0] == v7588
struct.pack_into("<I", data, vf(segs, 0x80040440), 0x20000)

# --- 2) lottery: 752 bnez a0 -> 7a2 (NOT via 996) ---
struct.pack_into(
    "<I", data, vf(segs, 0x80000752), bne(A0, 0, 0x80000752, 0x800007a2) & 0xFFFFFFFF
)
struct.pack_into("<I", data, vf(segs, 0x800007ac), 0xF1402573)  # csrr a0,mhartid
print("lottery: 752->7a2, hart0 wins")

# --- 3) 996 after start_finish -> success WFI ---
struct.pack_into("<I", data, vf(segs, 0x80000996), jal(0, 0x80000996, SUCCESS))
print("996 -> success cave")

# --- 4) cold_boot_allowed setup ---
cpc = SETUP
seq = []


def c4(w):
    global cpc
    seq.append((cpc, w & 0xFFFFFFFF))
    cpc += 4


c4((0x51B1C << 12) | (T0 << 7) | 0x37)
c4(addi(T0, T0, 1))
w0, w1 = auipc_addi(T1, cpc, 0x80001000)
c4(w0)
c4(w1)
c4(sw(T0, T1, 0))
c4(addi(T0, 0, -1))
w0, w1 = auipc_addi(T1, cpc, 0x80042A70)
c4(w0)
c4(w1)
c4(sd(T0, T1, 0))
c4(sd(T0, T1, 8))
w0, w1 = auipc_addi(T1, cpc, 0x80042870)
c4(w0)
c4(w1)
c4(sw(0, T1, 0))
c4(addi(T0, 0, 1))
c4(sw(T0, T1, 4))
c4(addi(A0, 0, 1))
c4(jalr(0, RA, 0))
assert cpc <= SETUP_LIMIT
for p, w in seq:
    struct.pack_into("<I", data, vf(segs, p), w)

# --- 5) cont.47: real sbi_scratch_alloc_offset (retire soft SA @2C90) ---
# cont.24–46 used leaf soft SA (extra_offset bump only, no memset/table walk).
# Full real SA under DI died mepc=0x2; bisect pins spin_lock/unlock AMO path.
# Real body from diag; soft-nop the three jal spin_{lock,unlock} sites. Single-
# hart coldboot does not need the lock; memset + extra_offset update stay real.
# PEEL_SPIN=1: leave diag spin jal (ordered path step2 / b1-amo-spin-lock).
NOP4 = 0x00000013  # addi x0,x0,0
# SA spins: peeled by default after 2026-08-08 cookie green (PEEL_SPIN=1 soak).
# SOFT_SPIN=1 restores NOP4 for AMO bisect. Soft malloc avoids freelist races.
if _env_peel("SOFT_SPIN"):
    for va in (
        0x800039AC,  # jal spin_lock
        0x800039D2,  # jal spin_unlock (ok path)
        0x80003A1C,  # jal spin_unlock (overflow path)
    ):
        struct.pack_into("<I", data, vf(segs, va), NOP4)
    print("SOFT_SPIN: SA spin lock/unlock NOP4")
else:
    print("cont.47+: real SA with natural spin lock/unlock (peeled)")

# --- 6) hang preserve-ra ---
struct.pack_into("<I", data, vf(segs, 0x80000766), jal(0, 0x80000766, HANG))
hpc = HANG
hseq = []


def h4(w):
    global hpc
    hseq.append((hpc, w & 0xFFFFFFFF))
    hpc += 4


h4((0x51B1E << 12) | (T0 << 7) | 0x37)
h4(addi(T0, T0, -0x153))  # 0x51b1dead
w0, w1 = auipc_addi(T1, hpc, 0x80001008)
h4(w0)
h4(w1)
h4(sw(T0, T1, 0))
h4(sd(RA, T1, 8))
wfi = hpc
h4(0x10500073)
h4(jal(0, hpc, wfi))
for p, w in hseq:
    struct.pack_into("<I", data, vf(segs, p), w)
# Hang cave @EF4C overruns into switch_mode entry @EF5E. Restore natural
# prologue EF5E..EF6E so finish can jal switch_mode then fall into SUCCESS@EF70.
_src = SRC.read_bytes()
_sseg = segs_of(_src)
for i in range(18):
    data[vf(segs, 0x8000EF5E + i)] = _src[vf(_sseg, 0x8000EF5E + i)]
print("cont.51: restore switch_mode prologue EF5E..EF6E after hang cave")

# --- 7) success cave: 0x51b1babe @ 1000, 0x51b1d000 @ 1008, WFI ---
cpc = SUCCESS
sseq = []


def s4(w):
    global cpc
    sseq.append((cpc, w & 0xFFFFFFFF))
    cpc += 4


s4((0x51B1C << 12) | (T0 << 7) | 0x37)
s4(addi(T0, T0, -0x542))  # 0x51b1babe
w0, w1 = auipc_addi(T1, cpc, 0x80001000)
s4(w0)
s4(w1)
s4(sw(T0, T1, 0))
s4((0x51B1D << 12) | (T0 << 7) | 0x37)
s4(addi(T0, T0, 0))
w0, w1 = auipc_addi(T1, cpc, 0x80001008)
s4(w0)
s4(w1)
s4(sw(T0, T1, 0))
wfi = cpc
s4(0x10500073)
s4(jal(0, cpc, wfi))
for p, w in sseq:
    struct.pack_into("<I", data, vf(segs, p), w)
print(f"success cave {hex(SUCCESS)}..{hex(cpc)}")

# --- 8) post-coldboot stubs (cont.20 peel) ---
# Skip early_init callback (still needed).
struct.pack_into("<H", data, vf(segs, 0x8000082C), c_j(0x8000082C, 0x80000838))
# cont.35–47 peel ladder. Still stubbed:
#   pmu (trap @2D00 + dhpo @2D40; SA cave @2C90 retired cont.47).
# Soft printf. hart_init real (cont.33). Soft start_finish (cont.41).
# cont.42/46: domain walk + real ld hart_ptr then j bbca; soft heap (printf @F300).
# cont.45: real sbi_hsm_hart_start. cont.47: real SA (nop locks).
for va in [
    0x80002C88,  # pmu (trap cave @2D00 still in body)
]:
    stub0(data, segs, va)
print("cont.47: pmu still stub0 (trap/dhpo caves); SA real")

# cont.42: soft heap freelist — free=2047 (max 12-bit), used=0, scratch_used=0.
# printf BANR cave lives in heap_used body @F300 (after this 6-byte stub).
def soft_ret_imm(va, imm):
    """addi a0,x0,imm; c.jr ra — imm must fit signed 12-bit."""
    assert -2048 <= imm <= 2047
    struct.pack_into(
        "<I", data, vf(segs, va), ((imm & 0xFFF) << 20) | (0 << 15) | (A0 << 7) | 0x13
    )
    struct.pack_into("<H", data, vf(segs, va + 4), 0x8082)


# cont.49–51 freelist spin sites: natural by default (SOFT_SPIN restores NOP4).
# With soft malloc, free/used/scratch_used are soft_ret_imm below unless PEEL_MALLOC.
if _env_peel("SOFT_SPIN"):
    struct.pack_into("<I", data, vf(segs, 0x8000F2BE), NOP4)  # heap_free spin_lock
    struct.pack_into("<I", data, vf(segs, 0x8000F2E4), NOP4)  # heap_free spin_unlock
    struct.pack_into("<I", data, vf(segs, 0x8000F314), NOP4)  # heap_used spin_lock
    struct.pack_into("<I", data, vf(segs, 0x8000F33E), NOP4)  # heap_used spin_unlock
    struct.pack_into("<I", data, vf(segs, 0x80003A4E), NOP4)  # scratch_used spin_lock
    struct.pack_into("<I", data, vf(segs, 0x80003A62), NOP4)  # scratch_used spin_unlock
    print("SOFT_SPIN: freelist/scratch spin NOP4")
else:
    print("cont.51+: freelist/scratch spins natural (peeled)")

# b1-heap-freelist-malloc (ordered path 2026-08-08): dual-hart smt2 + spin-nop
# freelist races → sbi_malloc unlink sd mcause=6 (mepc=0xf0ba) after coldboot_done.
# Soft-stub allocators so cookie path does not walk freelist. Coldboot already
# completed allocations before hang site; post-coldboot NULL malloc is OK for
# finish/switch_mode cookie. PEEL_MALLOC=1 restores real malloc/zalloc/free.
def soft_ret0(va):
    """c.li a0,0; c.jr ra"""
    struct.pack_into("<H", data, vf(segs, va), 0x4501)  # c.li a0,0
    struct.pack_into("<H", data, vf(segs, va + 2), 0x8082)  # c.jr ra


def soft_ret_void(va):
    """c.jr ra"""
    struct.pack_into("<H", data, vf(segs, va), 0x8082)


if not PEEL_MALLOC:
    soft_ret0(0x8000F04C)  # sbi_malloc → NULL
    soft_ret0(0x8000F176)  # sbi_zalloc → NULL
    soft_ret_void(0x8000F1A2)  # sbi_free → ret
    # Space queries without freelist walk (cont.42 style)
    soft_ret_imm(0x8000F2AA, 2047)  # sbi_heap_free_space
    soft_ret_imm(0x8000F2F4, 0)  # sbi_heap_used_space
    soft_ret_imm(0x80003A3C, 0)  # sbi_scratch_used_space
    print(
        "soft malloc/zalloc/free + heap space stubs "
        "(b1-heap-freelist-malloc; PEEL_MALLOC=1 to restore)"
    )
else:
    print("PEEL_MALLOC: real sbi_malloc/zalloc/free (from diag)")

# cont.42/46: real domain_finalize — natural bb20 (c.sd s9; j bb2c from diag),
# walk through assigned-bit + scratch-table ld. Soft-skip platform jalr.
# cont.46: at bb68 jal cave — real ld a4,0(s7) (domain_hart_ptr_offset) then
# j bbca. Peels past cont.42 cut@bb68; assigned body (add/ld/spin/hsm) still
# skipped. Cave @2D40 is past trap dump (2D00..2D40).
struct.pack_into("<H", data, vf(segs, 0x8000BAC4), 0x4501)  # c.li a0,0 was c.jalr a5
DHPO_CAVE = 0x80002D40
struct.pack_into(
    "<I", data, vf(segs, 0x8000BB68), jal(0, 0x8000BB68, DHPO_CAVE) & 0xFFFFFFFF
)
struct.pack_into("<I", data, vf(segs, DHPO_CAVE), 0x000BB703)  # ld a4, 0(s7)
struct.pack_into(
    "<I",
    data,
    vf(segs, DHPO_CAVE + 4),
    jal(0, DHPO_CAVE + 4, 0x8000BBCA) & 0xFFFFFFFF,
)
print("cont.46: domain plat→li0; natural bb20; ld hart_ptr @2D40; j bbca")

# cont.35: real sbi_console_init; soft-skip device init jalr (was mepc=0x42870).
# diag: ab6a = c.jalr a5 → c.li a0,0 so ops walk still runs, no bogus call.
struct.pack_into("<H", data, vf(segs, 0x8000AB6A), 0x4501)
print("cont.35: real console_init; c.li a0,0 @ab6a (skip device jalr)")

# cont.33 hart_init CSR probes: natural by default (cookie green 2026-08-08
# PEEL_CSR soak). SOFT_CSR=1 restores cd86→cd0e cut for bisect.
if _env_peel("SOFT_CSR"):
    struct.pack_into(
        "<I", data, vf(segs, 0x8000CD86), jal(0, 0x8000CD86, 0x8000CD0E) & 0xFFFFFFFF
    )
    print("SOFT_CSR: skip CSR probes cd86→cd0e reinit")
else:
    print("cont.33+: hart_init CSR probe tail natural (peeled)")
# peeled (not stubbed): 0x470A sse, 0x2EAA dbtr, 0x17CC irqchip, 0x165C ipi,
# cont.25: 0xC364 fwft, 0x8F22 ecall_init;
# 0x5A5C tlb, 0x53EC timer, 0xC656 pmp_configure; cont.33: 0xCCCC hart_init
struct.pack_into("<H", data, vf(segs, 0x80000B72), c_j(0x80000B72, 0x80000B9C))

# --- cont.26/50: soft printf (BANR) relocated out of heap_used ---
# Real sbi_printf still hits FDT lenp residual. Soft: count@0x80001060, BANR@+8.
# cont.50: PF cave in pmu free body @2C98 (was F300 inside heap_used).
PF_CAVE = 0x80002C98
struct.pack_into("<I", data, vf(segs, 0x8000A980), jal(0, 0x8000A980, PF_CAVE))
pfc = PF_CAVE
pfseq = []


def pf4(w):
    global pfc
    pfseq.append((pfc, w & 0xFFFFFFFF))
    pfc += 4


w0, w1 = auipc_addi(T1, pfc, 0x80001060)
pf4(w0)
pf4(w1)
pf4(ld(T0, T1, 0))
pf4(addi(T0, T0, 1))
pf4(sd(T0, T1, 0))
pf4(lui(T0, 0x42415))
pf4(addi(T0, T0, -0x1AE))  # 0x42414e52 BANR
pf4(sd(T0, T1, 8))
pf4(addi(A0, 0, 0))
pf4((enc_i(0, 12) << 20) | (RA << 15) | (0 << 7) | 0x67)  # ret
for pp, ww in pfseq:
    struct.pack_into("<I", data, vf(segs, pp), ww)
print(f"soft printf BANR cave {hex(PF_CAVE)}..{hex(pfc)}")

# Natural ecall at b9c
struct.pack_into("<I", data, vf(segs, 0x80000B9C), 0x386080EF)  # jal 80008f22 ecall_init

# cont.50 atomic_cmpxchg: natural LR/SC by default (cookie green 2026-08-08
# PEEL_CMPX soak). SOFT_CMPX=1 restores ld/sd shim for LR/SC bisect.
A1, A2 = 11, 12
CMPX = 0x800086C0
if _env_peel("SOFT_CMPX"):
    cpc_cx = CMPX
    cxseq = []

    def cx4(w):
        global cpc_cx
        cxseq.append((cpc_cx, w & 0xFFFFFFFF))
        cpc_cx += 4

    cx4(ld(T0, A0, 0))  # old = *addr
    cx4(bne(T0, A1, CMPX + 4, CMPX + 12))  # if old != expected skip store
    cx4(sd(A2, A0, 0))  # *addr = new
    cx4(addi(A0, T0, 0))  # return old
    cx4(jalr(0, RA, 0))  # ret
    for p, w in cxseq:
        struct.pack_into("<I", data, vf(segs, p), w)
    print(f"SOFT_CMPX: atomic_cmpxchg ld/sd @{hex(CMPX)}..{hex(cpc_cx)}")
else:
    print("cont.50+: atomic_cmpxchg natural LR/SC (peeled)")

# cont.51: switch_mode natural prologue @EF5E..EF6E then fall into SUCCESS
# cookie cave @EF70 (payload still soft). Finish natural jal switch_mode @F6BC.
# (Do not j SUCCESS at EF5E — run real stack frame setup first.)
print(
    f"cont.51: real jal cmpxchg+atomic_write; "
    f"switch_mode prologue→success cave@{hex(SUCCESS)}"
)
print("b9c ecall real; full banner; real putc+domain_dump; soft printf")
# DI cont.19: nop dual c.mv unless PEEL_CMV (b1-dual-cmv-s3).
if not PEEL_CMV:
    struct.pack_into("<H", data, vf(segs, 0x80007312), 0x0001)  # was c.mv a1,s1
    struct.pack_into("<H", data, vf(segs, 0x80007314), 0x0001)  # was c.mv a0,s2
    print("cont.19: nop c.mv a1/a0 @7312/7314 (keep override loop)")
else:
    print("PEEL_CMV: natural c.mv pair @7312/7314 (from diag)")


DST.write_bytes(data)
print("wrote", DST)
print(
    "expect SI/DI: 51b1babe + BANR "
    f"(soft_malloc={int(not PEEL_MALLOC)} soft_cmv={int(not PEEL_CMV)})"
)

r = subprocess.run(
    [
        "riscv64-unknown-elf-objdump",
        "-d",
        str(DST),
        "--start-address=0x80000750",
        "--stop-address=0x800007b0",
    ],
    capture_output=True,
    text=True,
)
print(r.stdout)
r = subprocess.run(
    [
        "riscv64-unknown-elf-objdump",
        "-d",
        str(DST),
        "--start-address=0x80000990",
        "--stop-address=0x800009a0",
    ],
    capture_output=True,
    text=True,
)
print(r.stdout)
