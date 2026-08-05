# Sparse GSys LibreCore (G6LC) module set for monorepo-soak / sv-timing auto-correct.
# Tier-R g6lc_* units only — packages first, then frontend BP fabric, OoO, SMT,
# cache helpers, and thin uncore glue. Not a full Flist; structural FO4 only.

+incdir+${CVA6_REPO_DIR}/core/include
+incdir+${CVA6_REPO_DIR}/corev_apu/include

# ---- packages / config seam ------------------------------------------------
${CVA6_REPO_DIR}/core/include/config_pkg.sv
${CVA6_REPO_DIR}/core/include/riscv_pkg.sv
${CVA6_REPO_DIR}/core/include/ariane_pkg.sv
${CVA6_REPO_DIR}/core/include/g6lc_pkg.sv
${CVA6_REPO_DIR}/core/include/cv64a6_imafdc_sv39_config_pkg.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_ooo_pkg.sv

# ---- frontend (U1 BP fabric + FTQ) -----------------------------------------
${CVA6_REPO_DIR}/core/frontend/g6lc_ftq.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_fdip.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_loop_buffer.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_ghist.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_ckpt.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_tage_table.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_tage.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_gshare.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_loop.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_statcor.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_ittage.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_bp_top.sv

# ---- OoO / slice (lightweight entry points) --------------------------------
${CVA6_REPO_DIR}/core/ooo/g6lc_freelist.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_rob.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_rename.sv
${CVA6_REPO_DIR}/core/g6lc_slice_steer.sv
${CVA6_REPO_DIR}/core/g6lc_slice_ist.sv

# ---- SMT -------------------------------------------------------------------
${CVA6_REPO_DIR}/core/smt/g6lc_hart_state.sv
${CVA6_REPO_DIR}/core/smt/g6lc_thread_select.sv
${CVA6_REPO_DIR}/core/smt/g6lc_smt_pc_bank.sv

# ---- cache helpers ---------------------------------------------------------
${CVA6_REPO_DIR}/core/cache_subsystem/g6lc_way_predictor.sv
${CVA6_REPO_DIR}/core/cache_subsystem/g6lc_rrip_repl.sv

# ---- uncore glue -----------------------------------------------------------
${CVA6_REPO_DIR}/corev_apu/src/g6lc_axi_2to1_mux.sv
