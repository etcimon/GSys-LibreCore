# Sparse frontend slice (FTQ / instr queue) for hierarchical timing screens.
#
# Supply is core/fetch_B, matching Flist.cva6's `+define+G6LC_FETCH_B` and
# `-f Flist.fetch_B`. This slice used to list core/fetch_A/frontend/instr_queue.sv and
# core/fetch_A/frontend/instr_scan.sv, which Flist.cva6 has commented out in favour of the
# fetch_B copies (architecture/core-fetch/SMT-LEGACY.md) -- so it was screening RTL that
# nothing compiles. Predictors legitimately stay in core/frontend.
#
# Do not add core/fetch_A/smt_legacy/frontend.sv or core/fetch_A/frontend/frontend.sv here: there would
# be two `module frontend`.
+define+G6LC_FETCH_B
+incdir+${CVA6_REPO_DIR}/core/include
${CVA6_REPO_DIR}/core/include/config_pkg.sv
${CVA6_REPO_DIR}/core/include/riscv_pkg.sv
${CVA6_REPO_DIR}/core/include/ariane_pkg.sv
${CVA6_REPO_DIR}/core/include/cv64a6_imafdc_sv39_config_pkg.sv
${CVA6_REPO_DIR}/core/fetch_B/g6lc_fetch_pkg.sv
${CVA6_REPO_DIR}/core/frontend/g6lc_ftq.sv
${CVA6_REPO_DIR}/core/fetch_B/instr_queue.sv
${CVA6_REPO_DIR}/core/fetch_B/instr_scan.sv
