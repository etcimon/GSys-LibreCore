# Sparse EX datapath slice for sv-timing host gates (not full Flist.cva6).
# Packages first, then a few combinationally heavy units.
+incdir+${CVA6_REPO_DIR}/core/include
${CVA6_REPO_DIR}/core/include/config_pkg.sv
${CVA6_REPO_DIR}/core/include/riscv_pkg.sv
${CVA6_REPO_DIR}/core/include/ariane_pkg.sv
${CVA6_REPO_DIR}/core/include/cv64a6_imafdc_sv39_config_pkg.sv
${CVA6_REPO_DIR}/core/alu.sv
${CVA6_REPO_DIR}/core/mult.sv
${CVA6_REPO_DIR}/core/multiplier.sv
${CVA6_REPO_DIR}/core/serdiv.sv
${CVA6_REPO_DIR}/core/branch_unit.sv
