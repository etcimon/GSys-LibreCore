# Full CVA6 core RTL (Flist.cva6) for structural FO4 soak.
# Instruction supply is fetch_B only (`+define+G6LC_FETCH_B` + Flist.fetch_B).
# Do not analyse core/fetch_A/** (retired frontend + g1* recover). Predictors
# stay in core/frontend.
+define+G6LC_FETCH_B
-F ${CVA6_REPO_DIR}/core/Flist.cva6
