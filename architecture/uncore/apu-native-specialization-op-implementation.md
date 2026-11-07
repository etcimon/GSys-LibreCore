# Bounded Native Specialization Operations

GSys LibreCore now folds a bounded scalar `OpSpecConstantOp` subset for native
compute pipelines. Original module words remain immutable. Default GPU refusal,
diagnostic compute opt-ins and zero Vulkan capsets remain unchanged.

## Native-Only Evaluation

The shared commit scanner is also the hardware table reference. Its default
continues to reject opcode52 with SPEC. Only native frontend module scans opt
into `native_spec_ops`; standalone/hardware-profile scanning stays unchanged.

One scanner evaluator handles native defaults and pipeline overrides. Pipeline
specialization first replaces supported scalar overrides, scans dependencies
in definition order, then emits ordinary Constant/ConstantTrue/ConstantFalse
instructions for derived results. Execution uses that immutable folded copy;
module provenance retains the original operations and SpecId declarations.

Supported scalar operations are integer add/subtract/multiply/negate, bitwise
or/xor/and/not, logical/arithmetic shifts, boolean equality/inequality/or/and/not,
scalar select, integer equality/inequality and unsigned less/less-equal.
Integer results wrap to32 bits. Reject shift counts>=32, nonconstant/forward/
self dependencies, incompatible types and unsupported operations/widths.
Vector/composite operations, floating arithmetic and division remain refused.

The evaluator executes no arbitrary code or recursive dependency interpreter.
Existing module/ID/constant/pipeline budgets remain. Derived array lengths pass
the scanner's constant-footprint bound before null materialization. Fold-scan
depth/shape failures normalize to bounded admission errors.

## Evidence

382 frozen checks pass17.971s from
`~/.cache/librecore/apu/native-execution.yxnv_4kg`;96 hashes unchanged and live
inputs match. Eight new cases cover default hardware refusal versus native
defaults, immutable wrapping overrides, unary/bitwise/shifts, invalid types/
counts/dependencies, boolean/select chains, derived-array bounds, scan-depth
error normalization and actual pipeline dispatch storing the folded result.

Four-source MIT tier/header/syntax/whitespace audit passes. Native presence
files=94 and default-PGO DEV PREFLIGHT OK perform no installation/build/training/
tests. Frozen lanes, strict warnings/timeouts and separate compiler/simulator
PGO policy remain.

## Review And Gates

Reference/software only: no functional RTL/config/ISA/CSR/DTS/discovery,
clock/reset/SRAM/DFT/PMU or timing-cone change. Hardware tables/ABI, upstream/
link sets and spec-index statuses remain; core/Storamic work is preserved.
Uncommitted; no timing/area/power, stock renderer, RTL/CTS or silicon promotion.

This is not complete SPIR-V specialization support or malformed-module
qualification. Broader shader/image/graphics/synchronization and stock feedback
remain open. RTL retained-unmap owner/alias/capacity and full capability/software/
hardware/CTS/formal/synthesis/physical/WSI qualification remain independent.
