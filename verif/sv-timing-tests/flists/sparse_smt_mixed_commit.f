# T6b-4b mixed-residency commit cone (NrHarts=2, SmtDrainedHandoff=0).
# Unlike sparse_issue_lsu (cv64a6_imafdc_sv39 / cva6_cfg_empty — MixedSmt
# folds to 0), this slice pairs the mixed-capable config package with the
# g6lc64_smt2_mixed param-map so the per-hart head-mux and reclaim logic in
# scoreboard and the p1_cross path in commit_stage actually elaborate.
+incdir+${CVA6_REPO_DIR}/core/include
${CVA6_REPO_DIR}/core/include/config_pkg.sv
${CVA6_REPO_DIR}/core/include/riscv_pkg.sv
${CVA6_REPO_DIR}/core/include/ariane_pkg.sv
${CVA6_REPO_DIR}/core/include/g6lc64_smt2_ooo_int_config_pkg.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_ooo_pkg.sv
${CVA6_REPO_DIR}/core/scoreboard.sv
${CVA6_REPO_DIR}/core/commit_stage.sv
${CVA6_REPO_DIR}/core/store_buffer.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_rob.sv
${CVA6_REPO_DIR}/core/smt/g6lc_smt_csr_bank.sv
