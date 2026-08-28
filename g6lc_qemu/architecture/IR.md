# IR — the `TargetModel` and the conformance report

Index: [`README.md`](README.md) · Producer: [`INGEST.md`](INGEST.md) · Consumers:
[`EMIT.md`](EMIT.md), [`DIAG.md`](DIAG.md). Crate: `g6q-core`.
Schemas: `../schemas/target-model.schema.json`, `../schemas/conformance.schema.json`.

The `TargetModel` is the **only** interface between ingest and everything downstream. No backend, no
diagnosis model and no emitter reads a design file directly.

---

## 1. Shape

```jsonc
{
  "schema_version": "1",
  "generated_by": { "tool": "g6lc-qemu", "version": "0.1.0", "rev": "<git-describe|unknown>" },

  "provenance": {
    "design_root": "/abs/design",
    "design_rev":  "<sha|dirty|unknown>",
    "sources":     [ { "path": "…/target_config_pkg.sv", "sha256": "…" } ],
    "defines":     ["…"],
    "overrides":   [ { "field": "…", "value": 2, "origin": "--cfg-override" } ]
  },

  "target": { "id": "…", "plane": "soc", "profile": "g6lc-soc", "faithful": true },

  "isa": {
    "xlen": 64, "base": "rv64i",
    "extensions": { "<token>": "live|stub|absent" },
    "isa_string": "…",
    "mmu": { "mode": "sv39", "itlb": 16, "dtlb": 16, "shared_tlb": false, "shared_tlb_depth": 0 },
    "vendor_ids": { "mvendorid": "…", "marchid": "…", "mimpid": "…" }
  },

  "csr": { "implemented": [ { "addr": "0x…", "name": "…", "gate": "<config field>" } ] },

  "uarch": {
    "BTBEntries": 64,
    "BHTEntries": 512,
    "RASDepth": 8,
    "IcacheByteSize": 16384,
    "DcacheByteSize": 16384,
    "L2En": 1,
    "L2ByteSize": 262144
  },

  "soc": {
    "peripherals": [ { "id": "…", "base": "0x…", "len": "0x…", "model": "…", "irq": 1 } ],
    "dram": { "base": "0x…", "len": "0x…" },
    "intc": { "sources": 30, "targets": 16, "max_priority": 7, "contexts_per_hart": 2 },
    "harts_total": 2
  },

  "accel": {
    "present": false,
    "seam": "…",
    "core_plane": {},
    "device": { "base": "0x…", "len": "0x…", "irq": 8, "descriptor_bytes": 64, "caps": {} }
  },

  "pmu": {
    "counter_count": 6,
    "counter_mask": 504,
    "idx_width": 5,
    "grp_width": 3,
    "events": [
      { "name": "legacy.01_l1_i_cache_misses", "group": 0, "index": 1, "mhpmevent": 1 }
    ],
    "groups": { "0": "legacy" },
    "unresolved": []
  },

  "flist": { "supply": "…", "files": 0, "defines": [], "membership": { "<fact>": "…" } },

  "conformance": { "rows": [] }
}
```

## 2. Design rules

1. **Carry, don't collapse.** A configuration field the readers do not semantically understand is
   still carried into `uarch.raw`. A future backend can use it without a re-ingest, and nothing is
   lost because the model was written before the use case existed.
2. **Every capability has a verdict, never a bare boolean.** `"v": true` cannot express "enabled but
   the unit is a stub". `"v": "stub"` can. See §3.
3. **Provenance is mandatory.** Source hashes and the design revision go in, so a model attached to a
   bug report is self-describing and a stale one is detectable.
4. **Canonical and deterministic.** Keys sorted, numbers normalised, addresses as `0x`-prefixed
   lowercase strings, no timestamps. Same inputs ⇒ byte-identical output. This is what makes
   `gen --check` a usable CI gate.
5. **`schema_version` is read before the payload.** A field rename is a version bump plus a fixture
   update, never a silent reinterpretation.
6. **Overrides are tainted, not absorbed.** `--cfg-override` appears in `provenance.overrides` and
   produces `synthetic` conformance rows; downstream artifacts inherit the taint.
7. **Addresses and sizes are strings.** JSON numbers cannot hold a 64-bit address without loss in
   every consumer that parses them as doubles.

## 3. The conformance report

The report is the reason the model is trustworthy. Each row is a capability plus the three inputs plus
a verdict.

```jsonc
{
  "capability": "vector",
  "config":     { "field": "<enable field>", "value": true },
  "flist":      { "evidence": "unit source tree absent from manifest", "present": false },
  "dts":        { "tokens": ["v", "zve64d"], "declared": true },
  "verdict":    "stub",
  "also":       ["overdeclared"],
  "note":       "configuration enables the unit; the elaborated design compiles a stub; the device tree advertises it to the guest"
}
```

| Verdict | Meaning | Under `--conform strict` |
|---|---|---|
| `live` | enabled, compiled, declared | emulate |
| `stub` | enabled, but the compiled RTL is a placeholder | **refuse** |
| `absent` | disabled and consistently absent | skip |
| `undeclared` | live in RTL, not advertised in the device tree | emulate, warn — the guest will not use it |
| `overdeclared` | advertised to the guest, not live in RTL | **refuse** — this is a guest-visible lie |
| `unresolved` | a reader could not determine the value | **refuse** |
| `synthetic` | forced by `--cfg-override` | emulate, taint everything |

Defaults: `--conform warn` for `run` (you want to boot a partially conformant machine while bringing
it up) and `--conform strict` for `diag` / `tandem` (you never want to publish a diagnosis from one).

## 4. Capability matrix

`g6q gen --emit matrix` (or `--emit matrix --json-out FILE`) prints a JSON matrix with one row per
capability from `g6q-ingest/data/capabilities.ini`. Each row exposes the input evidence used to
derive the verdict: the `config` probe and its resolved value, the `flist` probe type plus
`implementing`/`stubs` path fragments and the `flist` evidence string, the `dts` tokens/node and
whether the tree advertised the feature, and the stock-QEMU `qemu` properties or the delta they
cannot express. The `verdict` is the same value the conformance report carries.

The matrix is a diagnostic view: it does not change the verdict, but it makes the verdict
inspectable.

## 5. Why this is a product, not plumbing

`g6q conform` is useful with no emulator attached. It answers, mechanically, a question that is
otherwise answered by reading three sets of files and remembering how they relate: *does this design's
configuration, its build manifest, and its description to software actually agree?*

That is why Q1 is the stage that pays for itself, and why the conformance schema is versioned from the
first release rather than treated as debug output.
