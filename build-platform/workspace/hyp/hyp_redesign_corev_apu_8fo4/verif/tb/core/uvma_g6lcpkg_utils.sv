import "DPI-C" function void spike_set_param_uint64_t(string base, string name, longint unsigned value);
import "DPI-C" function void spike_set_param_str(string base, string name, string value);
import "DPI-C" function void spike_set_param_bool(string base, string name, bit value);
import "DPI-C" function void spike_set_default_params(string profile);

function st_core_cntrl_cfg g6lcpkg_to_core_cntrl_cfg(st_core_cntrl_cfg cfg);

    automatic config_pkg::g6lc_cfg_t G6LCCfg = build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
    string base;

    $cast(cfg.xlen, G6LCCfg.XLEN);

    cfg.ilen = 32;

    cfg.marchid = g6lc_core_pkg::G6LC_MARCHID;
    cfg.mvendorid = g6lc_core_pkg::G6LC_MVENDORID;

    cfg.ext_i_supported = 1;
    cfg.ext_a_supported = G6LCCfg.RVA;
    cfg.ext_m_supported = 1;
    cfg.ext_c_supported = G6LCCfg.RVC;
    cfg.ext_p_supported = 0;
    cfg.ext_v_supported = G6LCCfg.RVV;
    cfg.ext_f_supported = G6LCCfg.RVF;
    cfg.ext_d_supported = G6LCCfg.RVD;
    cfg.ext_zba_supported = G6LCCfg.RVB;
    cfg.ext_zbb_supported = G6LCCfg.RVB;
    cfg.ext_zbc_supported = G6LCCfg.RVB;
    cfg.ext_zbe_supported = 0;
    cfg.ext_zbf_supported = 0;
    cfg.ext_zbm_supported = 0;
    cfg.ext_zbp_supported = 0;
    cfg.ext_zbr_supported = 0;
    cfg.ext_zbs_supported = G6LCCfg.RVB;
    cfg.ext_zbt_supported = 0;
    cfg.ext_zcb_supported = G6LCCfg.RVZCB;
    cfg.ext_zifencei_supported = 1;
    cfg.ext_zicsr_supported = 1;
    cfg.ext_zicntr_supported = 0;

    cfg.ext_cv32a60x_supported = 0;

    // FIXME TODO: Temporary solution. We need explicit info on memory map.
    // FORNOW The solution below relies on specific region ordering.
    cfg.dram_base = 'h40000000;
    cfg.dram_size = 'h80000000;
    cfg.dram_valid = 1;

    cfg.disable_all_csr_checks = 0;
    cfg.mode_s_supported = G6LCCfg.RVS;
    cfg.mode_u_supported = G6LCCfg.RVU;
    cfg.mode_h_supported = G6LCCfg.RVH;

    cfg.pmp_supported = (G6LCCfg.NrPMPEntries > 0);
    cfg.pmp_regions = G6LCCfg.NrPMPEntries;
    cfg.debug_supported = G6LCCfg.DebugEn;

    cfg.DirectVecOnly = G6LCCfg.DirectVecOnly;
    cfg.TvalEn = G6LCCfg.TvalEn;

    cfg.unsupported_csr_mask['h643] = 1; // HTVAL
    cfg.unsupported_csr_mask['h64A] = 1; // HTINST

    if (!cfg.mode_h_supported) begin
      cfg.unsupported_csr_mask['h34A] = 1; // MTINST
      cfg.unsupported_csr_mask['h34B] = 1; // MTVAL2
    end

    // Disable comparison
    cfg.unsupported_csr_mask['h7C0] = 1; // ICACHE
    cfg.unsupported_csr_mask['h7C1] = 1; // DCACHE

    // MHPMEVENT
    for (int unsigned i = 32'h323; i < 32'h33F; i++)
      cfg.unsupported_csr_mask[i] = 1;

    base = $sformatf("/top/core/%0d/", cfg.mhartid);

    void'(spike_set_param_bool(base, "hide_csrs_based_on_priv", 1));
    void'(spike_set_param_uint64_t(base, "mtvec_vectored_alignment", 64 * 4));
    void'(spike_set_param_str(base, "extensions", "cvxif"));

    // All enabled except XS and TW bits
    void'(spike_set_param_uint64_t(base, "mstatus_write_mask", 'hFFDE_7FFF));

    if (cfg.DirectVecOnly) begin
      void'(spike_set_param_uint64_t(base, "mtvec_write_mask", 32'hFFFF_FFFC));
    end

    void'(spike_set_param_uint64_t(base, "misa_override_value", get_misa(cfg)));
    void'(spike_set_param_uint64_t(base, "misa_override_mask", 64'h0FFF_FFFF));
    void'(spike_set_param_bool    (base, "misa_we_enable", 1'b1));
    void'(spike_set_param_bool    (base, "misa_we", 1'b0));

    if (!cfg.TvalEn) begin
      void'(spike_set_param_bool    (base, "mtval_we_enable", 1'b1));
      void'(spike_set_param_bool    (base, "mtval_we", 1'b0));
    end

    return cfg;

endfunction : g6lcpkg_to_core_cntrl_cfg

