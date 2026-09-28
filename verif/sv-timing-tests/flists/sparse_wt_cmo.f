# Sparse WT cache-subsystem cone + T9a CMO engine for sv-timing FO4 screening.
# Structural delay only (not STA); unresolved instantiated cells measure as
# leaves, matching the other sparse_* profiles.

+incdir+${CVA6_REPO_DIR}/core/include
+incdir+${CVA6_REPO_DIR}/corev_apu/include

# ---- packages / config seam ------------------------------------------------
${CVA6_REPO_DIR}/core/include/config_pkg.sv
${CVA6_REPO_DIR}/core/include/riscv_pkg.sv
${CVA6_REPO_DIR}/core/include/ariane_pkg.sv
${CVA6_REPO_DIR}/core/include/wt_cache_pkg.sv
${CVA6_REPO_DIR}/core/include/g6lc_pkg.sv
${CVA6_REPO_DIR}/core/include/cv64a6_imafdc_sv39_config_pkg.sv

# ---- common-cell primitives the WT cone instantiates -----------------------
${CVA6_REPO_DIR}/core/cvfpu/src/common_cells/src/rr_arb_tree.sv
${CVA6_REPO_DIR}/core/cvfpu/src/common_cells/src/lzc.sv

# ---- WT subsystem ----------------------------------------------------------
${CVA6_REPO_DIR}/core/cache_subsystem/wt_dcache_mem.sv
${CVA6_REPO_DIR}/core/cache_subsystem/wt_dcache_ctrl.sv
${CVA6_REPO_DIR}/core/cache_subsystem/wt_dcache_missunit.sv
${CVA6_REPO_DIR}/core/cache_subsystem/wt_dcache_wbuffer.sv
${CVA6_REPO_DIR}/core/cache_subsystem/wt_dcache.sv
${CVA6_REPO_DIR}/core/cache_subsystem/wt_axi_adapter.sv
${CVA6_REPO_DIR}/core/cache_subsystem/wt_cache_subsystem.sv

# ---- T9a cluster CMO engine -------------------------------------------------
${CVA6_REPO_DIR}/corev_apu/coherence/g6lc_cmo_engine.sv
