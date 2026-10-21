#!/usr/bin/env python3
# hyp8: mechanical two-phase split of csr_regfile.csr_update.
# Phase A: per-domain csr_wr_* always_comb blocks producing *_w (hold + CSR write arms).
# Phase B: csr_update = defaults from *_w + verbatim post-case override code.
# Reference: verbatim original under translate_off driving rf_* + equality asserts.
import re, sys

PATH = 'core/csr_regfile.sv'
src = open(PATH, encoding='utf-8').read().split('\n')

BLOCK_TOP = next(i for i, l in enumerate(src) if 'always_comb begin : csr_update' in l)
CASE_IF   = next(i for i in range(BLOCK_TOP, len(src)) if 'if (csr_we) begin' in src[i])
CASE_KW   = next(i for i in range(CASE_IF, len(src)) if 'unique case (conv_csr_addr.address)' in src[i])
ENDCASE   = next(i for i in range(CASE_KW, len(src)) if re.match(r'^      endcase', src[i]))
CSRWE_END = ENDCASE + 1
assert re.match(r'^\s*end\s*$', src[CSRWE_END]), src[CSRWE_END]
BLOCK_END = next(i for i in range(CSRWE_END, len(src)) if re.match(r'^  end\s*$', src[i]))
print(f"csr_update block: {BLOCK_TOP+1}..{BLOCK_END+1}; case@{CASE_KW+1}; post {CSRWE_END+2}..{BLOCK_END}")

# ---- parse arm groups ---------------------------------------------------------
arms, i = [], CASE_KW + 1
while i < ENDCASE:
    st = src[i].strip()
    if re.match(r'^(riscv::CSR_\w+|default)\s*[,:]', st):
        labels, label_start = [], i
        while True:
            m = re.match(r'^\s*(riscv::CSR_\w+|default)\s*([,:])', src[i])
            if not m: break
            labels.append(m.group(1))
            if m.group(2) == ':': break
            i += 1
        j = i + 1
        depth = len(re.findall(r'\bbegin\b|\bcase[z]?\b|casex\b', src[i])) \
              - len(re.findall(r'\bend\b|endcase\b', src[i]))
        while j < ENDCASE:
            sj = src[j].strip()
            if depth == 0 and (re.match(r'^(riscv::CSR_\w+|default)\s*[,:]', sj)
                               or re.match(r'^endcase', sj)):
                break
            depth += len(re.findall(r'\bbegin\b|\bcase[z]?\b|casex\b', src[j])) \
                   - len(re.findall(r'\bend\b|endcase\b', src[j]))
            j += 1
        arms.append({'labels': labels, 'body': src[label_start:j]})
        i = j
    else:
        i += 1
print(f"arms: {len(arms)}")

LBL2BLK = {}
for blk, lbls in {
 'wr_fp':    'CSR_FFLAGS CSR_FRM CSR_FCSR CSR_FTRAN',
 'wr_dbg':   'CSR_DCSR CSR_DPC CSR_DSCRATCH0 CSR_DSCRATCH1',
 'wr_trig':  'CSR_TSELECT CSR_TDATA1 CSR_TDATA2 CSR_TDATA3',
 'wr_vs':    'CSR_VSSTATUS CSR_VSTVEC CSR_VSSCRATCH CSR_VSEPC CSR_VSCAUSE CSR_VSTVAL CSR_VSATP',
 'wr_ip':    'CSR_VSIE CSR_VSIP CSR_SIE CSR_SIP CSR_HIE CSR_HIP CSR_HVIP CSR_MIE CSR_MIP',
 'wr_s':     'CSR_JVT CSR_SCONTEXT CSR_STVEC CSR_SCOUNTEREN CSR_SSCRATCH CSR_SEPC CSR_SCAUSE CSR_STVAL CSR_SATP',
 'wr_stc':   'CSR_STIMECMP CSR_STIMECMPH CSR_VSTIMECMP CSR_VSTIMECMPH',
 'wr_mstat': 'CSR_SSTATUS CSR_MSTATUS CSR_MSTATUSH',
 'wr_envcfg':'CSR_SENVCFG CSR_HENVCFG CSR_HENVCFGH CSR_MENVCFG CSR_MENVCFGH',
 'wr_h':     'CSR_HSTATUS CSR_HEDELEG CSR_HIDELEG CSR_HCOUNTEREN CSR_HTVAL CSR_HTINST CSR_HGEIE CSR_HGATP CSR_HTIMEDELTA CSR_HTIMEDELTAH',
 'wr_m':     'CSR_MISA CSR_MEDELEG CSR_MIDELEG CSR_MTVEC CSR_MCOUNTEREN CSR_MSCRATCH CSR_MEPC CSR_MCAUSE CSR_MTVAL CSR_MTINST CSR_MTVAL2 CSR_MCOUNTINHIBIT',
 'wr_ctr':   'CSR_MCYCLE CSR_MCYCLEH CSR_MINSTRET CSR_MINSTRETH',
 'wr_acc':   'CSR_DCACHE CSR_ICACHE CSR_ACC_CONS',
}.items():
    for l in lbls.split(): LBL2BLK[l] = blk

def block_of(labels):
    for lb in labels:
        if lb.startswith('riscv::CSR_PMP'): return 'wr_pmp'
        if lb.startswith('riscv::CSR_MHPM'): return 'wr_ctr'
        s = lb.split('::')[-1]
        if s in LBL2BLK: return LBL2BLK[s]
    raise KeyError(labels)

blk_arms = {}
for a in arms:
    b = 'wr_dflt' if a['labels'] == ['default'] else block_of(a['labels'])
    blk_arms.setdefault(b, []).append(a)
print({k: len(v) for k, v in sorted(blk_arms.items())})

OWNED = {
 'wr_fp':['fcsr_d'], 'wr_dbg':['dcsr_d','dpc_d','dscratch0_d','dscratch1_d'], 'wr_trig':[],
 'wr_vs':['vsstatus_d','vstvec_d','vsscratch_d','vsepc_d','vscause_d','vstval_d','vsatp_d'],
 'wr_ip':['mip_d','mie_d'],
 'wr_s':['jvt_d','scontext_d','stvec_d','scounteren_d','sscratch_d','sepc_d','scause_d','stval_d','satp_d'],
 'wr_stc':['stimecmp_d','vstimecmp_d'], 'wr_mstat':['mstatus_d'],
 'wr_envcfg':['fiom_d','scbcfe_d','scbie_d','scbze_d','hcbcfe_d','hcbie_d','hcbze_d','hstce_d',
              'mcbcfe_d','mcbie_d','mcbze_d','mpbmte_d','mstce_d'],
 'wr_h':['hstatus_d','hedeleg_d','hideleg_d','hcounteren_d','htval_d','htinst_d','hgatp_d','htimedelta_d'],
 'wr_m':['mtvec_d','medeleg_d','mideleg_d','mepc_d','mcause_d','mcounteren_d','mscratch_d','mtval_d',
         'mtinst_d','mtval2_d','mcountinhibit_d'],
 'wr_ctr':['cycle_d','instret_d'], 'wr_pmp':['pmpcfg_d','pmpaddr_d'],
 'wr_acc':['dcache_d','icache_d','acc_cons_d','aicfg_d','aistatus_d','aiscale_d','aizp_d','aiqbase_d',
           'aiqctl_d','aiqhead_d','aiperm_d'], 'wr_dflt':[],
}
CASE_TOUCHED = sorted({s for v in OWNED.values() for s in v})
assert len(set(sum(OWNED.values(),[]))) == len(CASE_TOUCHED)

HOLDS = {
 'wr_fp':"      fcsr_w = fcsr_q;",
 'wr_dbg':"      if (G6LCCfg.DebugEn) begin\n        dcsr_w      = dcsr_q;\n        dpc_w       = dpc_q;\n        dscratch0_w = dscratch0_q;\n        dscratch1_w = dscratch1_q;\n      end",
 'wr_trig':"      tdata1_to_tm = '0;\n      tdata2_to_tm = '0;\n      tdata3_to_tm = '0;\n      tselect_to_tm = '0;\n      tselect_we = 1'b0;\n      tdata1_we  = 1'b0;\n      tdata2_we  = 1'b0;\n      tdata3_we  = 1'b0;",
 'wr_vs':"      if (G6LCCfg.RVH) begin\n        vsstatus_w  = vsstatus_q;\n        vstvec_w    = vstvec_q;\n        vsscratch_w = vsscratch_q;\n        vsepc_w     = vsepc_q;\n        vscause_w   = vscause_q;\n        vstval_w    = vstval_q;\n        vsatp_w     = vsatp_q;\n      end",
 'wr_ip':"      mip_w = mip_q;\n      mie_w = mie_q;",
 'wr_s':"      if (G6LCCfg.RVZCMT) jvt_w = jvt_q;\n      // hyp8: scontext_w keeps the original no-hold (write-only window) behavior\n      if (G6LCCfg.RVS) begin\n        sepc_w       = sepc_q;\n        scause_w     = scause_q;\n        stvec_w      = stvec_q;\n        scounteren_w = scounteren_q;\n        sscratch_w   = sscratch_q;\n        stval_w      = stval_q;\n        satp_w       = satp_q;\n      end",
 'wr_stc':"      if (G6LCCfg.SstcEn) begin\n        stimecmp_w = stimecmp_q;\n      end else begin\n        stimecmp_w = '0;\n      end\n      if (G6LCCfg.SstcEn && G6LCCfg.RVH) begin\n        vstimecmp_w = vstimecmp_q;\n      end else begin\n        vstimecmp_w = '0;\n      end",
 'wr_mstat':"      mstatus_w = mstatus_q;",
 'wr_envcfg':"      fiom_w   = fiom_q;\n      mcbie_w  = mcbie_q;\n      scbie_w  = scbie_q;\n      hcbie_w  = hcbie_q;\n      mcbcfe_w = mcbcfe_q;\n      scbcfe_w = scbcfe_q;\n      hcbcfe_w = hcbcfe_q;\n      mcbze_w  = mcbze_q;\n      scbze_w  = scbze_q;\n      hcbze_w  = hcbze_q;\n      mpbmte_w = mpbmte_q;\n      if (G6LCCfg.SstcEn) begin\n        mstce_w = mstce_q;\n      end else begin\n        mstce_w = 1'b0;\n      end\n      if (G6LCCfg.SstcEn && G6LCCfg.RVH) begin\n        hstce_w = hstce_q;\n      end else begin\n        hstce_w = 1'b0;\n      end",
 'wr_h':"      if (G6LCCfg.RVH) begin\n        hstatus_w    = hstatus_q;\n        hedeleg_w    = hedeleg_q;\n        hideleg_w    = hideleg_q;\n        hcounteren_w = hcounteren_q;\n        htinst_w     = htinst_q;\n        htval_w      = htval_q;\n        hgatp_w      = hgatp_q;\n      end\n      if (G6LCCfg.RVH) htimedelta_w = htimedelta_q;\n      else htimedelta_w = '0;",
 'wr_m':"      mcountinhibit_w = mcountinhibit_q;\n      if (mtvec_rst_load_q) begin\n        mtvec_w = {{G6LCCfg.XLEN - G6LCCfg.VLEN{1'b0}}, boot_addr_i} + 'h40;\n      end else begin\n        mtvec_w = mtvec_q;\n      end\n      if (G6LCCfg.RVS) begin\n        medeleg_w = medeleg_q;\n        mideleg_w = mideleg_q;\n      end\n      mepc_w       = mepc_q;\n      mcause_w     = mcause_q;\n      mcounteren_w = mcounteren_q;\n      mscratch_w   = mscratch_q;\n      if (G6LCCfg.TvalEn) mtval_w = mtval_q;\n      if (G6LCCfg.RVH) begin\n        mtinst_w  = mtinst_q;\n        mtval2_w  = mtval2_q;\n      end",
 'wr_ctr':"      cycle_w   = cycle_incr;\n      instret_w = instret_incr;\n      perf_we_o   = 1'b0;\n      perf_data_o = 'b0;",
 'wr_pmp':"      pmpcfg_w  = pmpcfg_q;\n      pmpaddr_w = pmpaddr_q;",
 'wr_acc':"      dcache_w   = dcache_q;\n      icache_w   = icache_q;\n      acc_cons_w = acc_cons_q;\n      aicfg_w    = aicfg_q;\n      aistatus_w = aistatus_q;\n      aiscale_w  = aiscale_q;\n      aizp_w     = aizp_q;\n      aiqbase_w  = aiqbase_q;\n      aiqctl_w   = aiqctl_q;\n      aiqhead_w  = aiqhead_q;\n      aiperm_w   = aiperm_q;",
 'wr_dflt':"",
}
BLOCKS = list(OWNED.keys())
AUX = {'virtual_update_access_exception':'vuae', 'update_access_exception':'uae',
       'flush_req':'flush', 'dirty_fp_state_csr':'dfsc'}

def rename_body(text, blk):
    for old, new in AUX.items():
        text = re.sub(r'\b'+old+r'\b', f'bk_{blk}_{new}', text)
    for s in CASE_TOUCHED:
        text = re.sub(r'\b'+s+r'\b', s[:-2]+'_w', text)
    return text

# type lookup for *_w decls: type = statement text up to the first name token
def type_of(name_d):
    pat = re.compile(r'^(\s*\S[^;]*?)\s+([A-Za-z_]\w*)(\s*\[[^\]]*\])?\s*[,;]')
    for i in range(BLOCK_TOP):
        if not re.search(r'\b'+name_d+r'\b', src[i]):
            continue
        m = pat.match(src[i])
        if m and name_d in src[i] and '=' not in m.group(1) and '<' not in m.group(1):
            typ = m.group(1).strip()
            mm = re.search(r'\b'+name_d+r'\b(\s*\[[^\]]*\])?', src[i])
            dims = (mm.group(1) or '').strip() if mm else ''
            return typ, dims
    return 'logic', ''
for s in CASE_TOUCHED:
    print('decl', s, '->', type_of(s))

# ---- emit -------------------------------------------------------------------
LOCALS = {'mask':'    automatic logic [G6LCCfg.XLEN-1:0] mask;',
          'satp':'    automatic satp_t satp;', 'vsatp':'    automatic satp_t vsatp;',
          'hgatp':'    automatic hgatp_t hgatp;', 'instret':'    automatic logic [63:0] instret;'}
LOCAL_INIT = {'satp':"      if (G6LCCfg.RVS) satp = satp_q;",
              'vsatp':"      if (G6LCCfg.RVH) vsatp = vsatp_q;",
              'hgatp':"      if (G6LCCfg.RVH) hgatp = hgatp_q;",
              'instret':"      instret = instret_q;"}

gen = []
gen.append("  // --------------------------------------------------------------------------")
gen.append("  // hyp8: C1 write phase A -- per-domain writer blocks (csr_wr_*) producing *_w =")
gen.append("  // hold + this cycle's CSR write.  Arms are verbatim from the original monolithic")
gen.append("  // csr_update (rank-0 independent-LHS split); shared sideband bits are bank-local")
gen.append("  // bk_* and OR-merged below (at most one case arm fires per write).  Phase B")
gen.append("  // (csr_update) applies the trap-entry / debug / xRET / interrupt overrides in")
gen.append("  // the original order on top of *_w.  The original block is kept verbatim under")
gen.append("  // translate_off as csr_update_ref with per-signal equality assertions.")
gen.append("  // --------------------------------------------------------------------------")

for blk in BLOCKS:
    a_list = blk_arms.get(blk, [])
    gen.append(f"\n  always_comb begin : csr_{blk}")
    body_all = '\n'.join('\n'.join(a['body']) for a in a_list)
    need = [n for n in LOCALS if re.search(r'(?<![\w.])'+n+r'(?![\w_])', body_all)]
    for n in need: gen.append(LOCALS[n])
    if HOLDS[blk]: gen.append(HOLDS[blk])
    for n in need:
        if n in LOCAL_INIT: gen.append(LOCAL_INIT[n])
    gen.append(f"      bk_{blk}_uae   = 1'b0;")
    gen.append(f"      bk_{blk}_vuae  = 1'b0;")
    gen.append(f"      bk_{blk}_flush = 1'b0;")
    gen.append(f"      bk_{blk}_dfsc  = 1'b0;")
    if blk == 'wr_dflt':
        gen.append("      if (csr_we) begin")
        gen.append("        unique case (conv_csr_addr.address)")
        for a in arms:
            if a['labels'] == ['default']: continue
            gen.append("          " + ',\n          '.join(a['labels']) + ": ;")
        gen.append("          default: bk_wr_dflt_uae = 1'b1;")
        gen.append("        endcase")
        gen.append("      end")
    else:
        gen.append("      if (csr_we) begin")
        gen.append("        unique case (conv_csr_addr.address)")
        for a in a_list:
            gen.append(rename_body('\n'.join(a['body']), blk))
        gen.append("          default: ;")
        gen.append("        endcase")
        gen.append("      end")
    gen.append("  end")

gen.append("\n  // hyp8: write-path sideband merge (exactly one arm fires per CSR write)")
gen.append("  assign uae_w  = " + ' | '.join(f'bk_{b}_uae' for b in BLOCKS) + ';')
gen.append("  assign vuae_w = " + ' | '.join(f'bk_{b}_vuae' for b in BLOCKS) + ';')
gen.append("  assign flush_req_w = " + ' | '.join(f'bk_{b}_flush' for b in BLOCKS) + ';')
gen.append("  assign dfsc_w = " + ' | '.join(f'bk_{b}_dfsc' for b in BLOCKS) + ';')

# phase B
gen.append("\n  always_comb begin : csr_update")
gen.append("    // hyp8: phase B -- holds through the per-bank writers (*_w), then the")
gen.append("    // original post-write overrides verbatim, in the original order.")
for s in CASE_TOUCHED:
    gen.append(f"    {s} = {s[:-2]+'_w'};")
gen.append("    // untouched state holds (verbatim from the original defaults)")
gen.append("    priv_lvl_d   = priv_lvl_q;")
gen.append("    v_d          = v_q;")
gen.append("    debug_mode_d = debug_mode_q;")
gen.append("    en_ld_st_translation_d = en_ld_st_translation_q;")
gen.append("    if (G6LCCfg.RVH) begin")
gen.append("      hgeie_d = hgeie_q;")
gen.append("      en_ld_st_g_translation_d = en_ld_st_g_translation_q;")
gen.append("    end")
gen.append("    eret_o         = 1'b0;")
gen.append("    set_debug_pc_o = 1'b0;")
gen.append("    // merged write-path sidebands")
gen.append("    flush_req                       = flush_req_w;")
gen.append("    update_access_exception         = uae_w;")
gen.append("    virtual_update_access_exception = vuae_w;")
gen.append("    dirty_fp_state_csr              = dfsc_w;")
gen.append("")
# verbatim post-case code
post = src[CSRWE_END+1:BLOCK_END]
gen.extend(post)
gen.append("  end")

# ---- reference + assertions ---------------------------------------------------
extra_lhs = ['priv_lvl_d','v_d','debug_mode_d','hgeie_d','en_ld_st_translation_d',
 'en_ld_st_g_translation_d','en_ld_st_translation_o','en_ld_st_g_translation_o',
 'eret_o','set_debug_pc_o','flush_req','update_access_exception','virtual_update_access_exception',
 'dirty_fp_state_csr','perf_we_o','perf_data_o','tdata1_to_tm','tdata2_to_tm','tdata3_to_tm',
 'tselect_to_tm','tselect_we','tdata1_we','tdata2_we','tdata3_we','ld_st_priv_lvl_o','ld_st_v_o',
 'priv_lvl_o','trap_to_priv_lvl','trap_to_v']
REF_RENAME = sorted(set(CASE_TOUCHED) | set(extra_lhs))
ref = '\n'.join(src[BLOCK_TOP:BLOCK_END+1])
ref = ref.replace('begin : csr_update', 'begin : csr_update_ref')
for nm in sorted(REF_RENAME, key=len, reverse=True) + ['mask']:
    ref = re.sub(r'\b'+nm+r'\b', 'rf_'+nm, ref)
gen.append("")
gen.append("  //pragma translate_off")
gen.append("  // hyp8: verbatim pre-split csr_update as the equivalence reference; every")
gen.append("  // rf_* output must equal the split implementation's signal cycle-by-cycle.")
gen.append(ref)
gen.append("")
for nm in REF_RENAME:
    gen.append(f"  assert property (@(posedge clk_i) disable iff (!rst_ni) rf_{nm} == {nm})")
    gen.append(f"    else $fatal(1, \"csr_regfile hyp8 two-phase split mismatch: {nm}\");")
gen.append("  //pragma translate_on")

# ---- signal declarations ------------------------------------------------------
decls = ["\n  // hyp8: phase-A writer outputs (x_w = hold + CSR write, per bank)"]
for s in CASE_TOUCHED:
    typ, dims = type_of(s)
    decls.append(f"  {typ} {s[:-2]+'_w'}{dims};")
decls.append("  logic uae_w, vuae_w, flush_req_w, dfsc_w;")
bk = ' '.join(f"bk_{b}_uae, bk_{b}_vuae, bk_{b}_flush, bk_{b}_dfsc;" for b in BLOCKS)
decls.append("  logic " + bk)

# ---- splice --------------------------------------------------------------------
DECL_ANCHOR = next(i for i, l in enumerate(src) if 'logic [G6LCCfg.XLEN-1:0] mask;' in l)
new = src[:DECL_ANCHOR] + ["  // hyp8: module-scope `mask` removed (per-block automatic in csr_wr_*)"] + \
      decls + src[DECL_ANCHOR+1:BLOCK_TOP] + gen + src[BLOCK_END+1:]
open(PATH, 'w', encoding='utf-8').write('\n'.join(new) + '\n')
print("spliced:", len(src), '->', len(new))
