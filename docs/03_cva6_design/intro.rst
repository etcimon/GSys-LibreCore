Introduction
============

This document describes the 6-stage, single issue Ariane CPU which implements the 64-bit RISC-V instruction set. It fully implements I, M and C extensions as specified in Volume I: User-Level ISA V 2.1 as well as the draft privilege extension 1.10. It implements three privilege levels M, S, U to fully support a Unix-like operating system.

.. note::

   **CVA6V-EC / currency.** The prose and diagrams in this manual describe the
   baseline in-order Ariane/CVA6 pipeline. The present worktree may enable
   additional **config-gated** features (multi-issue, slice/full OoO, SMT, L2,
   etc.) that are not fully reflected here. Prefer ``architecture/README.md``
   and ``docs/website/`` for the live map; structural path feedback is via
   ``sv-timing`` / ``cva6-build timings`` (not STA sign-off).

AI policy control compartment
-----------------------------

GSys LibreCore keeps throughput matrix control outside the CPU pipeline, under
``corev_apu/ai_island/``. The optional ``CVA6Cfg.AiCfg.PolicyCodecEn`` compartment
encodes bucketed matrix metadata into a frozen three-bit policy word, retains it
with work-count hysteresis, and decodes current and repeat/successor steering
hints. It does not train a runtime profiler, change the descriptor ABI, or yet
steer the production GEMM array. Sparse samples never authorize skipped arithmetic;
an exact-zero proof is required. The design, timing caveats, ownership rules and
verification ladder are in ``architecture/ai-matrix/README.md`` sections 10–11.
The additional default-off ``PolicyBenefitEn`` wrapper handles native-format
metadata and chooses balanced input/output groupings only for anticipated benefit
at a fixed service budget. Its per-format efficiency figures are validated
scheduling-model results, not production floating-point capability or silicon
throughput. The fallback never changes number format. Neither policy gate is
on in production and no production policy top instance exists. A real descriptor
metadata producer/consumer, per-context flush, PMU and tile/bank/tail validation
must precede RTL-memory performance measurements; I3-before-I2 is unchanged.

AI numeric evaluation and scalar arithmetic
------------------------------------------

Descriptor-v2 k-major packing and ``ai-native-eval`` now connect ai-tensor native
bytes to the B3 software evaluator. Public matmul B layouts are converted at the
packing boundary. Live island grants and the PE implementation mask remain
``16'h0003`` (INT8/INT4 only); wider software fixtures do not grant hardware
floating GEMM. ``ai-desc-formats`` tests the actual descriptor engine as well as
its helpers: unsupported compute modes fail before operand fetch, and legacy
INT + EW=1 is granted and handed off as effective INT4. This is a small
combinational parse guard, not new state, a clock/reset, DTS or capability.
Software memory-safety tests reject invalid C/completion destinations and device
overlays, and preserve sticky completion errors.

The standalone ``g6lc_ai_fp_mac.sv`` and ``include/g6lc_ai_fp_pkg.sv`` implement
exact FP8/FP16/BF16 widening and separate RNE FP32 multiply then add, without FTZ
or fused/reassociated reduction. ``AiCfg.IslandFpEn`` remains off in production.
For pipeline-register settings 1/2/3/5, measured scalar latency is 4/6/8/12 cycles
and initiation interval is 6/8/10/14 cycles: this serial primitive is not an
array throughput result. Floating GEMM loaders, array integration and grant
validation remain open. This increment adds neither fused requantization nor
non-GEMM arithmetic; existing spine operations are unchanged. None of these tests
establishes ISA F/D conformance.

See ``architecture/ai-matrix/numeric-formats-datapath.md`` and the
``AGENTS-specs-to-{impl,tests}.md`` maps for source and artifact traceability.
Recorded focused tests, generic synthesis and bounded checks are not a fresh
full-SoC sign-off. Prior full-core synthesis range/declaration-order and branding
blockers remain, along with DFT/test-mode audit, PDK STA, physical area/power and
full compliance; ``agents/guides/AGENTS-soc-readiness.md`` tracks those gates.

Scope and Purpose
-----------------

The purpose of the core is to run a full OS at reasonable speed and IPC. To achieve the necessary speed the core features a 6-stage pipelined design. In order to increase the IPC the CPU features a scoreboard which should hide latency to the data RAM (cache) by issuing data-independent instructions.
The instruction RAM has (or L1 instruction cache) an access latency of 1 cycle on a hit, while accesses to the data RAM (or L1 data cache) have a longer latency of 3 cycles on a hit.

.. image:: _static/ariane_overview.drawio.png
    :alt: Ariane Block Diagram
