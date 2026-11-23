import os, sys
for k in ("SOFT_LADDER_BUILD_TOOLCHAIN","HYP8_BUILD_TOOLCHAIN","DEV_PGO_TOOLCHAIN","VLT_HOME","RISCV","CXX","CC"):
    print(f"{k}={os.environ.get(k)}")
