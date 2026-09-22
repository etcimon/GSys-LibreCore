# Sparse OoO issue slice for FO4 screening of the select/age/CAM cones.
# Packages + the OoO backend units that own the issue-side combinational paths;
# not full Flist.cva6. Companion to sparse_issue_lsu.f (in-order issue + LSU).
+incdir+${CVA6_REPO_DIR}/core/include
${CVA6_REPO_DIR}/core/include/config_pkg.sv
${CVA6_REPO_DIR}/core/include/riscv_pkg.sv
${CVA6_REPO_DIR}/core/include/ariane_pkg.sv
${CVA6_REPO_DIR}/core/include/g6lc64_ooo_int_config_pkg.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_ooo_pkg.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_iq.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_lsq.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_memdep.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_rename.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_prf.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_rob.sv
${CVA6_REPO_DIR}/core/ooo/g6lc_ooo_dispatch.sv
