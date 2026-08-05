# Portable filelist for the P14 measurement-truth fixtures.
# Relative paths resolve against this file's directory.
# `width_sensitive.sv` uses a hierarchical dim (CVA6Cfg.XLEN) on purpose:
# run it with --assume-xlen 64 (or --param-map) to exercise M3 resolution.
+incdir+.
independent_stmts.sv
dep_chain_cross_region.sv
cut_imbalance.sv
seq_boundary.sv
width_sensitive.sv
two_modules.sv
