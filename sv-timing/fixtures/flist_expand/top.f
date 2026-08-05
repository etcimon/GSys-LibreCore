# Env + nested -F portable demo for tools/flist_expand.py
# Expand with: svt.py flist --in fixtures/flist_expand/top.f --set SVT_FLIST_ROOT=<abs>
+incdir+${SVT_FLIST_ROOT}
+define+FLIST_TOP
${SVT_FLIST_ROOT}/top_mod.sv
-F ${SVT_FLIST_ROOT}/nested_leaf.f
