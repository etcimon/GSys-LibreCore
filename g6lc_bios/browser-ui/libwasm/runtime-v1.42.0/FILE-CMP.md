# FILE-CMP v1.42.0 — generated vs pin druntime-wasm

- match 115  missed-libwasm 18  adapt-delta 0  extra 10  missing 0  text-diff 1

| path | class | gen | pin | first hunk |
|---|---|---:|---:|---|
| `core/demangle.d` | missed-libwasm | 96319 | 71365 | L1 |
| `core/internal/array/arrayassign.d` | missed-libwasm | 9888 | 9662 | L350 |
| `core/internal/array/capacity.d` | missed-libwasm | 12614 | 3168 | L12 |
| `core/internal/array/concatenation.d` | missed-libwasm | 5050 | 5134 | L20 |
| `core/internal/array/construction.d` | missed-libwasm | 17568 | 11824 | L16 |
| `core/internal/array/utils.d` | missed-libwasm | 9121 | 12082 | L15 |
| `core/internal/cast_.d` | extra | 7908 | 0 | L1 |
| `core/internal/dassert.d` | extra | 17562 | 0 | L1 |
| `core/internal/destruction.d` | extra | 1245 | 0 | L1 |
| `core/internal/lifetime.d` | missed-libwasm | 7045 | 6035 | L206 |
| `core/internal/moving.d` | extra | 3571 | 0 | L1 |
| `core/internal/newaa.d` | extra | 29363 | 0 | L1 |
| `core/internal/postblit.d` | extra | 6159 | 0 | L1 |
| `core/internal/spinlock.d` | extra | 1936 | 0 | L1 |
| `core/internal/switch_.d` | extra | 5421 | 0 | L1 |
| `core/lifetime.d` | missed-libwasm | 70491 | 68598 | L5 |
| `ldc/attributes.d` | missed-libwasm | 12688 | 12754 | L11 |
| `ldc/dcompute.d` | missed-libwasm | 3732 | 3550 | L68 |
| `ldc/dynamic_compile.d` | extra | 17549 | 0 | L1 |
| `ldc/gccbuiltins_aarch64.di` | missed-libwasm | 1203 | 1087 | L28 |
| `ldc/gccbuiltins_amdgcn.di` | missed-libwasm | 25745 | 19293 | L10 |
| `ldc/gccbuiltins_nvvm.di` | missed-libwasm | 69700 | 67249 | L46 |
| `ldc/gccbuiltins_ppc.di` | missed-libwasm | 48723 | 47736 | L10 |
| `ldc/gccbuiltins_s390.di` | missed-libwasm | 15404 | 14314 | L7 |
| `ldc/gccbuiltins_x86.di` | missed-libwasm | 128808 | 114533 | L67 |
| `ldc/intrinsics.di` | missed-libwasm | 28972 | 29307 | L28 |
| `ldc/sanitizers_optionally_linked.d` | missed-libwasm | 5192 | 5089 | L29 |
| `object.d` | text-diff | 132821 | 119390 | L2 |
| `std/string.d` | extra | 224349 | 0 | L1 |
