# Sparse corev_apu glue — lightweight uncore module (no full AXI typedef tree).
# Prefer analyzable slice for FO4 screening; soft-skip if file absent.
+incdir+${CVA6_REPO_DIR}/core/include
+incdir+${CVA6_REPO_DIR}/corev_apu/include
${CVA6_REPO_DIR}/corev_apu/src/g6lc_axi_2to1_mux.sv
