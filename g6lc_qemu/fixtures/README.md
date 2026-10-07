# fixtures — synthetic inputs and golden outputs

Everything here is **authored for this package**. Nothing is copied, extracted or adapted
from any design project.

Two reasons, both load-bearing:

1. **Licensing.** Copying a configuration package, manifest or device tree out of a host
   project would import that project's terms into an MIT tree and break the "no
   third-party material here" property (`../AGENTS-licensing.md` §4).
2. **Independence.** These fixtures are what make `cargo test --workspace` pass with only
   this tree. If they were extracts, the tests would be quietly coupled to a specific
   upstream revision and would rot the moment it moved.

They are *shaped* like real inputs — same grammar, same idioms, same failure modes — but
the names, addresses and numbers are invented. Where a fixture reproduces a real-world
hazard (a manifest cycle, a capability enabled in configuration but absent from the build,
an extension advertised to software that the design does not implement) it does so because
that hazard is what the test is about, not because it was observed in a particular tree.

## Contents

| Path | Shape | Exercises |
|---|---|---|
| `mini/target_config_pkg.sv` | a configuration package with one named struct literal | the narrow reader: scalars, sized literals, enums, nested structs, and one member it must refuse to guess at |
| `mini/manifest.f` | a top-level manifest with an include, a comment, and a variable | expansion, cycle guarding, `+incdir+` / `+define+` |
| `mini/manifest-nested.f` | the included manifest, which points back at the top | the cycle guard |
| `mini/board.dts` | a small device tree | extension tokens, including one deliberately overdeclared |
| `golden/mini-model.json` | the model the above should produce | canonical rendering and schema stability |
| `ai/g6lc_ai_island_cfg_pkg.sv` | a minimal AI-island configuration package with `QueueClusterMap` | ingest of queue-to-cluster dispatch |
| `ai/g6lc_ai_desc_pkg.sv` | a packed descriptor package with `desc_t`, `bits_to_desc`, `desc_to_bits`, `make_completion`, per-field `desc_dtype`/`desc_accmode`/`desc_ew`/`desc_sp24` accessors **and** a stale combined type comment | descriptor layout, completion geometry, and the accessor-beats-comment rule for the arithmetic-type subfields |
| `ai/g6lc_ai_instr_pkg.sv` | a minimal custom-instruction package with `ai.enq`/`ai.poll`/`ai.qfence` encodings | instruction-set ingestion |
| `apu/g6lc_apu_cfg_pkg.sv` | a minimal APU configuration package with one `ApuVenus` struct literal | APU bridge geometry ingestion (window bases, IRQ source, DMA window, queue counts) |
| `apu/g6lc_apu_pkg.sv` | the `APU_SHM_*` shared-aperture constants | aperture base/length/SHM-id ingestion |

## Native numeric exploration

`ai/eval-manifest.f` selects the invented `eval_g6lc_ai_desc_pkg.sv` and
`eval_g6lc_ai_island_cfg_pkg.sv`, plus the existing instruction fixture. The descriptor
publishes version 2 and `DESC_B_K_MAJOR=1`; the software-only format mask is 0xfb.
This is not a hardware capability override. The legacy `ai/manifest.f` stays unchanged.

`ai/tensor-eval-jobs.json` exercises all seven dense formats, asymmetric and padded
geometry, FP32 signaling NaN, SP24 rejection and an unrepresentable selector. The
first seven jobs share golden C = [[1,2,3],[3,4,7]]; the padded INT8 job produces
[[6],[15]], NaN produces `0000c07f`, and the last two jobs produce no C. The result
has 9 executed and 2 failed jobs, exit 0. CLI invocations are in architecture/CLI.md.
The CLI tests relocate both DRAM (a 4-GiB window with only 216 scratch bytes needed
for the asymmetric jobs) and descriptor field offsets to catch hard-coded addresses.

## Rules for adding a fixture

- Invent the content. If you need a hazard from a real tree, reproduce the *hazard*, not
  the file.
- Add the golden output in the same change, so a reader regression is a failing diff and
  not a silent behaviour change.
- Keep them small. A fixture is a specification, and a specification nobody reads is not
  one.
- A fixture may deliberately publish something the live design does not yet, when that
  something is an open ask in `../architecture/RTL_FEEDBACK.md`. Then the reader's forward
  path is tested here, while a separate test pins what the live package actually publishes
  today — so "the design has not published it" and "the emulator cannot read it" stay
  distinguishable. `ai/g6lc_ai_desc_pkg.sv` does this for the F10 type accessors.
