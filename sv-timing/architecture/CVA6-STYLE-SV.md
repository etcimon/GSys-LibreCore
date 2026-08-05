# Scoped types, hierarchical ports, genvar (language surface)

> **Design rule:** lower/emit treat scopes **structurally** — anything left of `::`
> (package/class path) or `.` (hierarchical field) — **not** a fixed list of
> project package names. Host RTL (e.g. OpenHW CVA6 `core/*.sv`) is only a
> source of *examples*; fixtures prove the same rules offline.

## 1. Generic SV constructs (and illustrative host loci)

| Construct | Structural rule | Example shape (any names) |
|---|---|---|
| Package + typedef/function | `package` items | `pkg::…` |
| `import pkg::*` | package identifier on import | any package on the file list |
| Scoped value parameter | type/default left of `::` | `parameter Pkg::type_t P = Pkg::def` |
| Type parameter | `parameter type T = …` | default may also be `Pkg::type_t` |
| Hierarchical port dims | root left of `.` in packed dims | `input T [P.field-1:0] port` |
| `for (genvar …)` | bound may be `root.member` | `i < P.N` |
| Named `begin` / `always_ff` edges | labels + sensitivity | `begin : L`, `posedge`/`negedge` |

Host files such as `load_unit` / `scoreboard` / `issue_read_operands` exercise these
shapes; analyzing them still needs a **host-expanded** filelist for real packages.

**Fixtures:** `fixtures/cva6_style/`, `fixtures/issue_style/` (sample multi-package
projects; names are incidental).

## 2. Lower (read) — IR fields

| SV construct | IR |
|---|---|
| `package P; … endpackage` | `TimingDesign.packages[P]` |
| Module `localparam` | `TimingModule.localparams[]` |
| `parameter Scope::T Name = Scope::def` | `TypedParameter` (`type_ref` / `default_expr` use `::`) |
| `parameter type T = …` | `TypedParameter { is_type_parameter: true }` |
| `input T [Root.member-1:0] p` | `ModulePort { uses_hierarchical, packed_dims }` |
| `for (genvar i … Root.member …)` | `GenerateLoop { bound_hint: "Root.member", label? }` |
| `import pkg::*` | `package_imports[]` (whatever `pkg` is) |
| `always_ff @(posedge clk or negedge rst) begin : L` | `CombRegion` + `GateInfo` names/edges |
| `always_comb begin : L` | `CombRegion.label` |

## 3. Emit (write) — dense auto-correct surface

Corrected blocks intentionally re-emit CVA6-shaped SV:

```systemverilog
  function automatic logic [SVT_DATA_W-1:0] svt_pipe_mux(...);
    return sel ? t : f;
  endfunction

  always_comb begin : svt_comb_ctrl
    ...
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : svt_pipe_ff
    if (!rst_ni) begin : svt_rst
      ...
    end else begin : svt_capture
      q <= svt_pipe_mux(en, d, q);
    end
  end
```

## 4. How to validate

```bash
sv-timing analyze --files-from fixtures/cva6_style/project.f \
  --modules cva6_style_unit --json-out report.json
# JSON: packages[].functions, modules[].regions[].label / clock_name / reset_name

sv-timing correct --files-from fixtures/cva6_style/project.f \
  --modules cva6_style_unit --allow-latency --assume-clk --emit \
  --out-dir .sv-timing-out/cva6_style
```

Fixtures: `fixtures/cva6_style/`, `fixtures/issue_style/` (config_pkg + ariane_pkg + issue_style_unit).  
Unit tests: `cva6_style_package_localparam_function_named_ff`, `issue_style_typed_params_ports_genvar`.  
Verif case: `cva6_style_unit` in `verif/regress/suites.toml`.

## 5. Host path for real core/*.sv

Preferred package-owned loop (no build-platform):

```bash
python tools/svt.py monorepo-soak --profile sparse_ex
# see architecture/MONOREPO-SOAK.md — fix package before RTL
```

Manual path:

1. Expand monorepo flist → portable `.f` (+incdir, packages first).  
2. Pass `--modules load_unit` (or scoreboard) with defines/`param-map` as needed.  
3. Expect same region labels (`ldbuf_ff`, `regs`) once packages parse.  
4. Never commit auto-corrected trees into `core/` without review.
