// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Timing IR types — shared by measure, transform, emit (multi-pass).

//! Intermediate representation for structural timing analysis and auto-correct.
//! See `architecture/AUTO-CORRECT-CORE-API.md` and `architecture/DESIGN.md`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::loc::SourceLoc;

/// Opaque stable ids (allocated by lower / NameTable).
pub type ModuleId = u32;
/// Field names the current lowerer writes onto instances and designs.
///
/// Sorted. Cache keys and module blobs record this list. A loaded blob whose
/// list does not contain every name was lowered by an older binary.
pub fn emitted_lower_field_names() -> &'static [&'static str] {
    &[
        "branch_arms",
        "config_branch",
        "decls",
        "default_text",
        "fn_bodies",
        "param_override_present",
        "pipe_pragmas_derived",
        "stage_decls",
        "statement_source",
    ]
}

/// True when `stored` contains every name from [`emitted_lower_field_names`].
pub fn lower_fields_cover(stored: &[String]) -> bool {
    emitted_lower_field_names()
        .iter()
        .all(|name| stored.iter().any(|stored_name| stored_name == *name))
}

/// Signal / net / variable id within a design.
pub type SignalId = u32;
/// Operator or statement node id.
pub type NodeId = u32;
/// Combinational region id.
pub type RegionId = u32;
/// Timing path id.
pub type PathId = u32;
/// File identity for line maps.
pub type FileId = u32;

/// Operator timing class (cost model key).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperatorClass {
    /// Bitwise / logic.
    LogicBit,
    /// Comparators.
    Compare,
    /// Constant shift.
    ShiftConst,
    /// Variable shift.
    ShiftVar,
    /// Add / sub.
    AddSub,
    /// Multiply.
    Mul,
    /// Divide / rem.
    DivRem,
    /// Mux / select.
    Mux,
    /// Priority mux / case chain level.
    PriorityMux,
    /// Concatenation.
    Concat,
    /// Unclassified.
    Other,
}

/// Clock edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EdgeKind {
    /// Rising.
    Posedge,
    /// Falling.
    Negedge,
    /// Both / level (rare).
    Level,
}

/// Reset description.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResetInfo {
    /// Reset signal if known.
    pub signal: Option<SignalId>,
    /// Active-low when true.
    pub active_low: bool,
    /// Asynchronous reset.
    pub asynchronous: bool,
}

/// Gating for sequential / conditional NBA.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct GateInfo {
    /// Clock signal id (when resolved).
    pub clock: Option<SignalId>,
    /// Clock hierarchical/plain name from sensitivity (e.g. `clk_i`).
    pub clock_name: Option<String>,
    /// Clock edge (`posedge` / `negedge`).
    pub edge: Option<EdgeKind>,
    /// Enable expression node (optional).
    pub enable: Option<NodeId>,
    /// Reset.
    pub reset: Option<ResetInfo>,
    /// Reset signal name from sensitivity (e.g. `rst_ni` with `negedge`).
    pub reset_name: Option<String>,
    /// Reset edge when asynchronous reset is on the sensitivity list.
    pub reset_edge: Option<EdgeKind>,
    /// Pure combinational region.
    pub is_comb: bool,
}

/// Path endpoint markers (STA-like skeleton for frequency closure).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathEndpoint {
    /// Register clock pin (launch edge).
    RegClock {
        /// Sequential cell id (node or signal).
        cell: SignalId,
    },
    /// Register data/Q pin (launch Q or capture D).
    RegData {
        /// Sequential cell id.
        cell: SignalId,
    },
    /// Module input port (primary input startpoint).
    InputPort {
        /// Owning module.
        module: ModuleId,
        /// Port signal.
        port: SignalId,
    },
    /// Module output port (primary output endpoint).
    OutputPort {
        /// Owning module.
        module: ModuleId,
        /// Port signal.
        port: SignalId,
    },
}

impl PathEndpoint {
    /// Short label for reports / JSON (`startpoint` / `endpoint` fields).
    pub fn report_name(&self, module_name: &str) -> String {
        match self {
            PathEndpoint::RegClock { cell } => format!("{module_name}.reg{cell}/CP"),
            PathEndpoint::RegData { cell } => format!("{module_name}.reg{cell}/D"),
            PathEndpoint::InputPort { port, .. } => format!("{module_name}.in{port}"),
            PathEndpoint::OutputPort { port, .. } => format!("{module_name}.out{port}"),
        }
    }
}

/// Timing path class for frequency-closure accounting (STA-like).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PathKind {
    /// Primary input → primary output (often I/O constrained).
    #[default]
    InToOut,
    /// Register → register (core of frequency closure).
    RegToReg,
    /// Primary input → register.
    InToReg,
    /// Register → primary output.
    RegToOut,
}

impl PathKind {
    /// Derive path kind from start/end markers.
    pub fn from_endpoints(start: &PathEndpoint, end: &PathEndpoint) -> Self {
        use PathEndpoint::*;
        match (start, end) {
            (RegClock { .. } | RegData { .. }, RegData { .. } | RegClock { .. }) => {
                PathKind::RegToReg
            }
            (InputPort { .. }, OutputPort { .. }) => PathKind::InToOut,
            (InputPort { .. }, RegData { .. } | RegClock { .. }) => PathKind::InToReg,
            (RegClock { .. } | RegData { .. }, OutputPort { .. }) => PathKind::RegToOut,
            _ => PathKind::InToOut,
        }
    }
}

/// How a statement writes its LHS (IEEE 1800 blocking / NBA / continuous).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum AssignKind {
    /// Unknown / not an assignment (bare operator token).
    #[default]
    Unknown,
    /// Blocking `=` (combo temp, including in `always_ff`).
    Blocking,
    /// Blocking compound update (`+=`, `|=`, ...). RHS is normalized for
    /// measurement, but automatic source rewrites require separate support.
    BlockingCompound,
    /// Non-blocking `<=` (flop write).
    Nonblocking,
    /// Continuous `assign`.
    Continuous,
}

impl AssignKind {
    /// Flop definition (NBA).
    pub fn is_seq_def(self) -> bool {
        matches!(self, AssignKind::Nonblocking)
    }

    /// Combinational definition (blocking or continuous).
    pub fn is_comb_def(self) -> bool {
        matches!(
            self,
            AssignKind::Blocking | AssignKind::BlockingCompound | AssignKind::Continuous
        )
    }

    /// True when kind was not recovered from CST.
    pub fn is_unknown(&self) -> bool {
        matches!(self, AssignKind::Unknown)
    }
}

/// Kind of combinational / procedural region.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegionKind {
    /// `always_comb` body.
    AlwaysComb,
    /// `always_ff` data cloud.
    AlwaysFf,
    /// Continuous `assign`.
    ContAssign,
}

/// One combinational cloud / process cone.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CombRegion {
    /// Region id.
    pub id: RegionId,
    /// Owning module.
    pub module: ModuleId,
    /// Kind.
    pub kind: RegionKind,
    /// Named block label (`begin : name`) when present (CVA6 style).
    pub label: Option<String>,
    /// Process gating (clock/reset edges for `always_ff`).
    pub gate: GateInfo,
    /// Nodes in the region.
    pub nodes: Vec<NodeId>,
    /// Total FO4 (after attribute_costs).
    pub total_fo4: f64,
    /// Covering span.
    pub loc_span: SourceLoc,
    /// Multi-cycle tagged.
    pub multi_cycle: bool,
}

/// IR operator / statement node.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IrNode {
    /// Node id.
    pub id: NodeId,
    /// Operator class if applicable.
    pub op_class: Option<OperatorClass>,
    /// Bit width (may be defaulted).
    pub width: u32,
    /// Structural FO4 cost.
    pub fo4_cost: f64,
    /// Optional gating.
    pub gate: Option<GateInfo>,
    /// Source location.
    pub loc: SourceLoc,
    /// Fan-in node ids.
    pub fans_in: Vec<NodeId>,
    /// Fan-out node ids.
    pub fans_out: Vec<NodeId>,
    /// Width was defaulted.
    pub width_defaulted: bool,
    /// True when this node reads a value produced by a **sequential** (NBA)
    /// definition, i.e. its combinational cone launches from a register output.
    ///
    /// The def-use graph deliberately does **not** create an edge through a flop
    /// (defect M1), so this flag is how path extraction recovers the correct
    /// `reg→…` startpoint. See `architecture/OPTIMIZATION-LEVELS.md` §1.1(3).
    #[serde(default)]
    pub reads_reg: bool,
    /// LHS text when recovered from an assignment (expression-accurate emit).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lhs: Option<String>,
    /// RHS text when recovered from an assignment (expression-accurate emit).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rhs: Option<String>,
    /// Parsed RHS expression tree when available (denser IR / cost / emit).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rhs_expr: Option<crate::expr::Expr>,
    /// Parsed LHS expression tree when available.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lhs_expr: Option<crate::expr::Expr>,
    /// Case-item labels when this assign sits under a `case` arm (`ADD`, `SUB`, …).
    /// Populated by lower from CST `CaseItem` (preferred over source-line scan).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub case_labels: Vec<String>,
    /// True when the assign is under a `default:` case item.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub case_is_default: bool,
    /// Case selector expression when known (e.g. `fu_data_i.operation`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub case_selector: Option<String>,
    /// When true, [`crate::measure::attribute_costs`] must not recompute `fo4_cost`
    /// from `rhs_expr` / `op_class` (spine expand / half-split residuals).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub fo4_locked: bool,
    /// Blocking / NBA / continuous. NBA lhs is a flop; blocking in `always_ff`
    /// is a combo temp (PASS-STRATEGY: do not infer extra clock edges).
    #[serde(default, skip_serializing_if = "AssignKind::is_unknown")]
    pub assign_kind: AssignKind,
}

/// Timing path through a region.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingPath {
    /// Path id.
    pub id: PathId,
    /// Region.
    pub region_id: RegionId,
    /// Module.
    pub module: ModuleId,
    /// Start endpoint (launch / startpoint).
    pub start: PathEndpoint,
    /// End endpoint (capture / endpoint).
    pub end: PathEndpoint,
    /// Path class for closure (reg→reg vs I/O).
    pub path_kind: PathKind,
    /// Human startpoint name (e.g. `alu.reg0/CP`, `mod.in0`).
    pub startpoint: String,
    /// Human endpoint name (e.g. `alu.reg1/D`, `mod.out0`).
    pub endpoint: String,
    /// Nodes on the path.
    pub nodes: Vec<NodeId>,
    /// Total FO4.
    pub total_fo4: f64,
    /// Slack vs budget (negative = over budget).
    pub slack_fo4: f64,
    /// Max frequency (MHz) at which this path alone would close (margin applied).
    pub max_freq_mhz: f64,
    /// Hottest node location.
    pub primary_loc: SourceLoc,
    /// Multi-cycle path (excluded from default negative-slack ranking).
    pub multi_cycle: bool,
    /// Path class after post-emptive bottleneck classification.
    #[serde(default)]
    pub path_class: crate::path_class::PathClassKind,
    /// Raw sum FO4 before exclusive/atomic exception adjust (when adjusted).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_fo4_raw: Option<f64>,
    /// Short classification note / evidence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class_note: Option<String>,
    /// `svt-stage` stage of the first comb node on the path (`null` →
    /// unstaged `-`). A view field, not a closure input.
    #[serde(default)]
    pub stage_start: Option<String>,
    /// `svt-stage` stage of the last comb node on the path.
    #[serde(default)]
    pub stage_end: Option<String>,
}

/// Suggested transform.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpportunityKind {
    /// Insert pipeline register (latency-changing).
    InsertReg,
    /// Split assign / wire (no latency change).
    SplitAssign,
    /// Balance exclusive mux / priority select tree (latency-neutral).
    BalanceMux,
    /// `REG + narrow step` → precomputed candidate increments + one select
    /// (latency-neutral, exact; `select_increment` module, A88).
    SelectIncrement,
    /// A serial loop walk (find-first scan, conditional count, ring pointer
    /// walk) → its exact parallel form (latency-neutral; `loop_walk`, A101).
    LoopRewrite,
    /// An exact expression identity on one node — circular compare, zero
    /// detect of a difference, late select pushed through arithmetic
    /// (latency-neutral; `expr_rewrite`, A122).
    ExprRewrite,
}

/// Pipeline / rewrite opportunity.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Opportunity {
    /// Kind.
    pub kind: OpportunityKind,
    /// Related path.
    pub path_id: PathId,
    /// Insert after this node (cut site).
    pub insert_after: NodeId,
    /// FO4 before.
    pub estimated_fo4_before: f64,
    /// FO4 after (estimate).
    pub estimated_fo4_after: f64,
    /// Location.
    pub loc: SourceLoc,
    /// Human rationale.
    pub rationale: String,
    /// Needs clock in scope.
    pub requires_clock_in_scope: bool,
    /// Latency change (true for InsertReg).
    pub changes_latency: bool,
}

/// Frequency / FO4 budget target.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingTarget {
    /// MHz.
    pub target_mhz: f64,
    /// FO4 picoseconds.
    pub fo4_ps: f64,
    /// Margin 0..1.
    pub budget_margin: f64,
    /// Derived FO4 budget for a path.
    pub budget_fo4: f64,
}

impl TimingTarget {
    /// Build target and compute budget FO4.
    pub fn new(target_mhz: f64, fo4_ps: f64, budget_margin: f64) -> Self {
        let period_ns = if target_mhz > 0.0 {
            1000.0 / target_mhz
        } else {
            1.0
        };
        let budget_fo4 = (period_ns * 1000.0 / fo4_ps.max(1e-9)) * (1.0 - budget_margin);
        Self {
            target_mhz,
            fo4_ps,
            budget_margin,
            budget_fo4,
        }
    }
}

/// Version banner for reports.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VersionBanner {
    /// Package version.
    pub package: String,
    /// IR version.
    pub ir: String,
    /// Cost model id.
    pub cost_model: String,
    /// Parser pin hint.
    pub parser_pin: String,
    /// Measurement semantics ([`crate::MEASUREMENT_VERSION`]): how delay is computed,
    /// as opposed to which cost table was used.
    #[serde(default = "default_measurement")]
    pub measurement: String,
}

fn default_measurement() -> String {
    crate::MEASUREMENT_VERSION.to_string()
}

/// Module `#(...)` value or type parameter.
///
/// Type/default strings use SV scope form `pkg::name` when the AST shows a
/// package/class scope left of `::` — no project-specific package names.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TypedParameter {
    /// Parameter name.
    pub name: String,
    /// True for `parameter type T = …`.
    pub is_type_parameter: bool,
    /// Type reference, often `scope::type` when scoped.
    pub type_ref: Option<String>,
    /// Default expression, often `scope::name` when scoped.
    pub default_expr: Option<String>,
    /// Integer default text (`48`). Absent when the default is not an integer.
    /// `None` on an older blob means the field was not written.
    #[serde(default)]
    pub default_text: Option<String>,
}

/// A function body kept off the delay graph. `attribute_costs` does not read it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionBody {
    /// Function name.
    pub name: String,
    /// Text of the `return` expression. Empty when the function has no return.
    pub return_expr: String,
    /// Packed return dimension source, such as `[PKG_WIDTH-1:0]`.
    pub return_dimension: String,
    /// Integer `name = value` bindings visible in the enclosing scope.
    pub constants: Vec<(String, i64)>,
    /// The declaration's full text (header to `endfunction`), for the
    /// call-site cost of a multi-statement body (delay-v38): a find-first
    /// `pick_free(fr)` is an incrementer and an encode, not one gate.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub body_text: String,
}

/// One variable or net declaration. An empty vector that this lowerer wrote
/// is not the same as a missing vector on an older blob.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeclSite {
    /// Variable name.
    pub name: String,
    /// Type name (`logic`, or a user type such as `slot_t`).
    pub type_name: String,
    /// Packed dimension source, including literals (`[63:0]`, `[DEPTH-1:0][WIDTH-1:0]`).
    pub packed_text: String,
    /// Unpacked dimension source. Empty when there is none.
    pub unpacked_text: String,
    /// Source locus.
    pub loc: SourceLoc,
    /// Declared inside a `begin … end` block, a function/task body, a generate
    /// block, or as a `for` loop variable — not visible at module scope, so an
    /// emitted module-level wire or `type()` operand may not name it.
    #[serde(default)]
    pub block_local: bool,
    /// Nearest lexical scope, in original-source coordinates. None for module
    /// declarations or unresolved origins; unresolved bindings stay conservative.
    #[serde(default)]
    pub scope: Option<SourceLoc>,
    /// `for (int i = …)` loop variable: unrolled at elaboration, so it is a
    /// constant operand for width purposes (its `int` is not a 32-bit datapath).
    #[serde(default)]
    pub loop_var: bool,
}

/// ANSI/non-ANSI port summary for typed / parameterized ports.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModulePort {
    /// Port name.
    pub name: String,
    /// `input` / `output` / `inout` / `ref` / unknown.
    pub direction: String,
    /// Data type name (`logic`, a typedef, …).
    pub type_name: Option<String>,
    /// Packed-dimension hint when hierarchical (e.g. `[param.field-1:0]`).
    pub packed_dims: Option<String>,
    /// True when packed dims / type sizing use hierarchical `root.member` form
    /// (parameter or struct field access), independent of any particular SoC.
    pub uses_hierarchical: bool,
    /// Packed dimension source text. Not parsed from [`Self::packed_dims`].
    #[serde(default)]
    pub dimension_text: Option<String>,
}

/// `for (genvar i = 0; i < …; i++)` generate loop.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GenerateLoop {
    /// Genvar identifier (`i`).
    pub genvar: String,
    /// Bound hint when hierarchical (`root.member` left of compare), if known.
    pub bound_hint: Option<String>,
    /// Optional generate-block label.
    pub label: Option<String>,
    /// Source locus of the **whole** generate loop (header + body).
    pub loc: SourceLoc,
    /// Continuous assigns / statements counted inside (timing density hint).
    pub body_assign_count: u32,
    /// Procedural `for (int …)` inside an always block (unrolled by synthesis),
    /// as opposed to a `generate` loop.
    #[serde(default)]
    pub procedural: bool,
    /// Procedural loop header: initial value text (`0`) and condition text
    /// (`k < CVA6Cfg.NR_SB_ENTRIES`), for the trip count.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub init_text: Option<String>,
    /// See `init_text`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cond_text: Option<String>,
    /// Procedural loop: the loop statement's own source text (header + body)
    /// and the statement text that precedes it in the block, for the
    /// loop-walk shape detector (`loop_walk`). Not a delay input.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    /// See `text`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pre_text: Option<String>,
    /// The loop sits inside a function or task body (a module-scope vector
    /// cannot serve it; the loop-walk rewrite leaves it alone).
    #[serde(default)]
    pub in_function: bool,
}

/// Named port connection on a module instance (formal ↔ actual).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortConnection {
    /// Child-module formal port name (`.formal(actual)`).
    pub formal: String,
    /// Parent-side actual (first simple identifier when hierarchical, else text).
    pub actual: String,
}

/// One module instance found in a parent module body (P2 instance graph).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModuleInstance {
    /// Parent (instantiating) module id.
    pub parent_module: ModuleId,
    /// Parent module name.
    pub parent_name: String,
    /// Instance name (`u_leaf`).
    pub instance_name: String,
    /// Instantiated type (`proj_leaf`).
    pub child_type: String,
    /// Resolved child module id when the type is on the design (else `None`).
    pub child_module: Option<ModuleId>,
    /// Named port connections (ordered ports omitted in v1).
    pub connections: Vec<PortConnection>,
    /// Source locus of the instantiation.
    pub loc: SourceLoc,
    /// `Some(true)` when the instantiation has `#(...)`.
    /// `Some(false)` when it does not.
    /// `None` means the JSON field was absent (an older blob). That is not
    /// `Some(false)`.
    #[serde(default)]
    pub param_override_present: Option<bool>,
}

/// Hierarchical timing path: child path + parent path through an instance.
///
/// Prefer **port-bridged** stitch when named connections map a child `output`
/// formal to a parent net; otherwise fall back to a series upper-bound on the
/// worst local paths. Still structural FO4 — not STA.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrossModulePath {
    /// Path id (namespace shared with module-local paths for reports).
    pub id: PathId,
    /// Parent module name.
    pub parent_module: String,
    /// Instance name in the parent.
    pub instance_name: String,
    /// Child module type name.
    pub child_module: String,
    /// Child local path id (if any).
    pub child_path_id: Option<PathId>,
    /// Parent local path id (if any).
    pub parent_path_id: Option<PathId>,
    /// Combined FO4 (child + parent contributions).
    pub total_fo4: f64,
    /// Slack vs design budget.
    pub slack_fo4: f64,
    /// Max MHz limited by combined cost (margin applied at report time).
    pub max_freq_mhz: f64,
    /// Composite startpoint label.
    pub startpoint: String,
    /// Composite endpoint label.
    pub endpoint: String,
    /// Short rationale.
    pub rationale: String,
    /// Stitch mode: `port_bridged` when a child output formal is connected; else `series_upper_bound`.
    pub stitch_kind: String,
    /// Parent-side nets that bridge child outputs (actuals).
    pub bridge_nets: Vec<String>,
    /// Connection pairs as `formal=actual` for the bridge used.
    pub via_ports: Vec<String>,
}

/// One module's timing IR.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingModule {
    /// Module id.
    pub id: ModuleId,
    /// Module name (SV).
    pub name: String,
    /// Primary definition file.
    pub file: String,
    /// Nodes.
    pub nodes: BTreeMap<NodeId, IrNode>,
    /// Regions.
    pub regions: BTreeMap<RegionId, CombRegion>,
    /// Module `localparam` names.
    pub localparams: Vec<String>,
    /// Typed / type parameters (`parameter scope::type_t P = scope::default`).
    pub parameters: Vec<TypedParameter>,
    /// Module ports (including hierarchical-sized packed arrays).
    pub ports: Vec<ModulePort>,
    /// `for (genvar …)` generate loops.
    pub gen_loops: Vec<GenerateLoop>,
    /// Function names declared in the module.
    pub functions: Vec<String>,
    /// Function bodies. Empty when this lowerer saw none. Not a delay input.
    #[serde(default)]
    pub function_bodies: Vec<FunctionBody>,
    /// `import pkg::*` / package scopes referenced (any package name).
    pub package_imports: Vec<String>,
    /// Module instances nested in this module body.
    pub instances: Vec<ModuleInstance>,
    /// Variable and net declarations. Empty when this lowerer saw none.
    #[serde(default)]
    pub decls: Vec<DeclSite>,
    /// `parameter` / `localparam` name → default/value expression text
    /// (preprocessed frame). Width inference evaluates `[N-1:0]` through it.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub const_exprs: BTreeMap<String, String>,
    /// `typedef` name → data-type text (`logic [IdxW-1:0]`, `enum logic [1:0]`).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub typedef_texts: BTreeMap<String, String>,
    /// True when the module contains a procedural `if` or a generate-`if`.
    /// Area keeps both arms. Delay does not read this flag.
    #[serde(default)]
    pub config_branch: bool,
    /// Guards of a node (delay-v37): the predicate texts of the `if`s the
    /// assignment sits under within its block, plus the index expressions of
    /// a dynamically indexed LHS (`q[slot].f = …`). They are reads of the
    /// node — the select cone of an issue queue reaches `q_d` only through
    /// `if (grant[g]) q[slot_entry[g]].valid = 0` — and they cost: a guarded
    /// write is a mux on the guard. Empty for unguarded nodes. A guard
    /// decided above the node's enclosing loop (the `if` wraps the whole
    /// loop) is prefixed `^`: it is one select for all unrolled copies, so
    /// the trip multiplier must not scale it.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub guards: BTreeMap<NodeId, Vec<String>>,
    /// Conditional / case arms a node sits in (delay-v43), as
    /// `[statement_key, arm_index]` pairs; the key is the statement's
    /// original-source byte start. Two nodes in different arms of one
    /// statement are mutually exclusive: a read in one arm does not see a
    /// write made in the other, so the reference tree does not chain them.
    /// Empty for nodes outside any branch.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub branch_arms: BTreeMap<NodeId, Vec<[u32; 2]>>,
    /// Launch arrival (FO4) of the register outputs a node reads (delay-v43):
    /// the unbuffered Q-net delay of a flop driving many loads
    /// ([`crate::load`]). An arrival, not a latency — a node whose other
    /// inputs come later does not pay it. Filled by `attribute_costs`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub launch_fo4: BTreeMap<NodeId, f64>,
    /// Texts the module asserts one-hot: the arguments of every
    /// `$onehot0(…)` / `$onehot(…)` in its source (`grant[p]`). A rewrite
    /// that is exact only under a one-hot select (`OneHotSelect`) may fire
    /// only when its guard's base is in this list — invariant-tagged, the
    /// design's own assertion is the proof obligation (A104).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub onehot_facts: Vec<String>,
    /// Every `if` / `else if` predicate of the module with its source span
    /// (A122): comparisons in this codebase mostly live in guards, not in
    /// assignment RHS, so an exact identity must be able to rewrite one.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub guard_sites: Vec<GuardSite>,
    /// Declaration source text per declared port/variable name, captured for
    /// authored preparation rules (A135). Empty for ordinary analyses.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub decl_texts: BTreeMap<String, String>,
    /// In-file re-pipelining facts (A123): `// svt-pipe: …` comment pragmas
    /// collected over the module span, like the `$onehot` facts. They name
    /// the roles a register cut must carry (valid, id, kill, flush, carried
    /// signals, result side) and where a stage boundary is permitted or
    /// forbidden. Source declarations and derived representation facts are
    /// distinguished by `PipePragma::derived`, consumed by `InsertReg`.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pipe_pragmas: Vec<PipePragma>,
    /// `svt-stage:` region declarations collected over the module span
    /// (§19 stage-aware FO4 view). Additive metadata — the node→stage map
    /// is computed at report time from node locs, not stored in the IR.
    #[serde(default, skip_serializing_if = "crate::stage_pragma::ModuleStages::is_empty")]
    pub stage_decls: crate::stage_pragma::ModuleStages,
    /// Source span of module header.
    pub loc: SourceLoc,
}

/// One `// svt-pipe: <kind> [domain] key=value … flag …` pragma as written.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PipePragma {
    /// Checked source-preparation plan, present only on a derived ready fact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_local: Option<crate::row_local::RowLocalPlan>,
    /// Produced by pipeline preprocessing rather than read from source.
    /// Original pragmas remain alongside these facts for provenance/rebuild.
    #[serde(default)]
    pub derived: bool,
    /// Source directive (`protocol`, `carry`, `result`, `cut-ok`, `no-cut`,
    /// `require-contract`, `latency`, `representation`) or a derived fact kind.
    pub kind: String,
    /// Protocol domain name when the directive takes one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub domain: Option<String>,
    /// `key=value` arguments, in order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<(String, String)>,
    /// Bare words (carried signal names for `carry`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub words: Vec<String>,
    /// The pragma comment's own location.
    pub loc: SourceLoc,
}

/// One `if` predicate as written, with the span of the expression inside
/// the parentheses (not the statement). The text is what [`TimingModule::guards`]
/// records for the assignments the predicate encloses.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GuardSite {
    /// Complete original-source conditional statement (outer `if` only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub statement: Option<SourceStatement>,
    /// Predicate text, trimmed.
    pub text: String,
    /// Span of the predicate expression in the original source.
    pub loc: SourceLoc,
}

/// A concrete source statement retained for checked preprocessing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SourceStatement {
    /// Original-source span, not an offset into preprocessed parser text.
    pub loc: SourceLoc,
    /// Exact bytes at that span, used as the emitter's stale-source guard.
    pub text: String,
}

impl TimingModule {
    /// True when `a` and `b` sit in different arms of one conditional or case
    /// statement ([`Self::branch_arms`]): at most one of them executes.
    pub fn nodes_exclusive(&self, a: NodeId, b: NodeId) -> bool {
        let (Some(xa), Some(xb)) = (self.branch_arms.get(&a), self.branch_arms.get(&b)) else {
            return false;
        };
        xa.iter()
            .any(|[ka, ia]| xb.iter().any(|[kb, ib]| ka == kb && ia != ib))
    }

    /// True when every arm `writer` sits in also encloses `reader`: whenever
    /// the read executes, the write has executed before it.
    pub fn arms_enclose(&self, writer: NodeId, reader: NodeId) -> bool {
        let w = self
            .branch_arms
            .get(&writer)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        let r = self
            .branch_arms
            .get(&reader)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        w.iter().all(|x| r.contains(x))
    }

    /// Source text of the declaration (port or variable) binding `name`, when
    /// the lowerer retained it. Used by preparation rules that need qualifiers
    /// the summary fields drop (`signed`).
    pub fn source_decl_text(&self, name: &str) -> Option<&str> {
        self.decl_texts.get(name).map(String::as_str)
    }

    /// Genvar names whose generate-loop span covers `loc` (elaboration, not runtime `i`).
    pub fn genvar_names_at(&self, loc: &SourceLoc) -> Vec<String> {
        if loc.origin != crate::loc::OriginKind::UserFile {
            return Vec::new();
        }
        let b = loc.byte_start;
        self.gen_loops
            .iter()
            .filter(|g| {
                g.loc.origin == crate::loc::OriginKind::UserFile
                    && g.loc.file == loc.file
                    && g.loc.byte_end > g.loc.byte_start
                    && b >= g.loc.byte_start
                    && b < g.loc.byte_end
            })
            .map(|g| g.genvar.clone())
            .collect()
    }

    /// Names that are **not** visible at module scope: block-local declarations
    /// (`DeclSite::block_local`) and every generate / procedural `for` loop
    /// variable. An emitted module-level wire, a hoisted `always_comb`, or a
    /// `type(<expr>)` operand that names one of these does not elaborate.
    pub fn block_local_names(&self) -> std::collections::BTreeSet<String> {
        let mut out: std::collections::BTreeSet<String> = self
            .decls
            .iter()
            .filter(|d| d.block_local)
            .map(|d| d.name.clone())
            .collect();
        for g in &self.gen_loops {
            if !g.genvar.is_empty() {
                out.insert(g.genvar.clone());
            }
        }
        out
    }

    /// Root identifier of an expression leaf: `a.b[3]` → `a`; `pkg::X` stays
    /// package-scoped (always visible) and yields `None`.
    pub fn root_ident(name: &str) -> Option<&str> {
        if name.contains("::") {
            return None;
        }
        let root = name.split(['.', '[']).next().unwrap_or(name).trim();
        (!root.is_empty()).then_some(root)
    }

    /// True when `text` (an expression or an LHS) references a name that is not
    /// visible at module scope, so it cannot be hoisted into a module-level
    /// snippet. Unknown names are allowed: enum labels and parameters imported
    /// from packages are not declared in the module.
    pub fn text_refs_block_local(
        &self,
        text: &str,
        block_local: &std::collections::BTreeSet<String>,
    ) -> bool {
        if block_local.is_empty() {
            return false;
        }
        let expr = crate::expr::Expr::parse(text);
        let mut hit = false;
        expr.walk_idents(&mut |name| {
            if let Some(root) = Self::root_ident(name) {
                if block_local.contains(root) {
                    hit = true;
                }
            }
        });
        if hit {
            return true;
        }
        // The expression parser folds what it cannot read into opaque leaves;
        // scan the raw text too so a block-local name never slips through.
        let bytes = text.as_bytes();
        let has_escaped_ident = text.contains('\\');
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i].is_ascii_alphabetic() || matches!(bytes[i], b'_' | b'$') {
                let start = i;
                i += 1;
                while i < bytes.len()
                    && (bytes[i].is_ascii_alphanumeric() || matches!(bytes[i], b'_' | b'$'))
                {
                    i += 1;
                }
                let before = text[..start].trim_end();
                let after = text[i..].trim_start();
                // A member named `index` is not a local variable `index`.
                // Retain the conservative scan for escaped identifiers.
                let qualified = !has_escaped_ident
                    && (before.ends_with('.') || before.ends_with("::") || after.starts_with("::"));
                if !qualified && block_local.contains(&text[start..i]) {
                    return true;
                }
            } else {
                i += 1;
            }
        }
        false
    }
}

/// Package IR (localparams + functions + typedefs; not a timing path root).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingPackage {
    /// Package name.
    pub name: String,
    /// Definition file.
    pub file: String,
    /// Localparams / parameters in the package.
    pub localparams: Vec<String>,
    /// Function names.
    pub functions: Vec<String>,
    /// Function bodies. Not a delay input.
    #[serde(default)]
    pub function_bodies: Vec<FunctionBody>,
    /// Typedef / struct type names.
    pub typedefs: Vec<String>,
    /// Package `parameter` / `localparam` name → expression text.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub const_exprs: BTreeMap<String, String>,
    /// Package `typedef` name → data-type text.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub typedef_texts: BTreeMap<String, String>,
    /// Source span.
    pub loc: SourceLoc,
}

/// Full design IR.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimingDesign {
    /// Modules by id.
    pub modules: BTreeMap<ModuleId, TimingModule>,
    /// Name → id.
    pub module_names: BTreeMap<String, ModuleId>,
    /// Packages by name (read for localparams/functions; not timed as paths).
    pub packages: BTreeMap<String, TimingPackage>,
    /// Flat instance graph (also mirrored on each parent `TimingModule.instances`).
    pub instances: Vec<ModuleInstance>,
    /// Cross-module (hierarchical) paths from the instance graph.
    pub cross_module_paths: Vec<CrossModulePath>,
    /// Paths.
    pub paths: Vec<TimingPath>,
    /// Opportunities.
    pub opportunities: Vec<Opportunity>,
    /// Target budget.
    pub target: TimingTarget,
    /// Keys present in the host param-map (values not re-exported by default).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub param_map_keys: Vec<String>,
    /// Integer-valued host param-map entries (`CVA6Cfg.XLEN` → 64, `XLEN` → 64),
    /// the width inference's outermost constant scope.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub param_map_ints: BTreeMap<String, i64>,
    /// Elaborated net widths per module (`--width-map`), see `ParamMap::width_map`.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub width_map: crate::param_map::WidthMap,
    /// True when package-mode denser surface was requested.
    #[serde(default)]
    pub package_mode: bool,
    /// Post-emptive path exceptions / classifications (also denormalized on each path).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub path_exceptions: Vec<crate::path_class::PathException>,
    /// Parallel-timing scratchboards keyed by module name (every module + function).
    ///
    /// Timing basis: ASAP/ALAP FO4 on the procedural ref-tree; `cycle_count =
    /// ceil(makespan / budget_fo4)`. Not STA.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub parallel_timing: BTreeMap<String, crate::parallel_timing::ModuleParallelTiming>,
    /// Per-module algorithm-set cleanliness (explore → pick working solution).
    ///
    /// Timing basis: FO4 slack vs budget. Objective favours `always_ff` /
    /// `always_comb` density and penalises aggressiveness and timing fail.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub module_cleanliness: BTreeMap<String, crate::cleanliness::ModuleSolution>,
    /// Pre-pass plan (P1–P9). Artifacts abort correct.
    #[serde(
        default,
        skip_serializing_if = "crate::pass_strategy::PassPlan::is_empty_plan"
    )]
    pub pass_plan: crate::pass_strategy::PassPlan,
    /// Lower-emitted field names stored with this design.
    ///
    /// Absent or empty on a blob that predates the field. A missing name is
    /// not the same as a design that was lowered without instances.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub emitted_lower_fields: Vec<String>,
    /// Versions.
    pub versions: VersionBanner,
}

impl TimingDesign {
    /// Every instance of the design: the flat graph when it was populated,
    /// otherwise the per-module mirrors (a design rehydrated from the cache
    /// or a host JSON may carry only those).
    pub fn all_instances(&self) -> Vec<&ModuleInstance> {
        if !self.instances.is_empty() {
            return self.instances.iter().collect();
        }
        self.modules
            .values()
            .flat_map(|m| m.instances.iter())
            .collect()
    }

    /// Empty design with target.
    pub fn empty(target: TimingTarget) -> Self {
        Self {
            modules: BTreeMap::new(),
            module_names: BTreeMap::new(),
            packages: BTreeMap::new(),
            instances: Vec::new(),
            cross_module_paths: Vec::new(),
            paths: Vec::new(),
            opportunities: Vec::new(),
            target,
            param_map_keys: Vec::new(),
            param_map_ints: BTreeMap::new(),
            width_map: BTreeMap::new(),
            package_mode: false,
            path_exceptions: Vec::new(),
            parallel_timing: BTreeMap::new(),
            module_cleanliness: BTreeMap::new(),
            pass_plan: crate::pass_strategy::PassPlan::default(),
            emitted_lower_fields: emitted_lower_field_names()
                .iter()
                .map(|name| (*name).to_string())
                .collect(),
            versions: VersionBanner {
                package: crate::PACKAGE_VERSION.to_string(),
                ir: crate::IR_VERSION.to_string(),
                measurement: crate::MEASUREMENT_VERSION.to_string(),
                cost_model: "fo4-v1".into(),
                parser_pin: crate::PARSER_PIN_HINT.to_string(),
            },
        }
    }

    /// Localparam / parameter / param-map / imported-package names that seed P1.
    ///
    /// Mixed-case identifiers (`VpnLen`, `PtLevels`) are included. Genvars are
    /// not listed here — they are added per-node via [`TimingModule::genvar_names_at`].
    pub fn elaboration_const_names(&self, module: &TimingModule) -> Vec<String> {
        let mut names = Vec::new();
        names.extend(module.localparams.iter().cloned());
        names.extend(module.parameters.iter().map(|p| p.name.clone()));
        names.extend(self.param_map_keys.iter().cloned());
        for pkg_name in &module.package_imports {
            let key = pkg_name.split("::").next().unwrap_or(pkg_name);
            if let Some(pkg) = self.packages.get(key) {
                names.extend(pkg.localparams.iter().cloned());
            }
        }
        names
    }

    /// Names plus their resolved values (delay-v45): every
    /// [`elaboration_const_names`] entry evaluated through
    /// [`crate::width::WidthResolver`], which follows bound
    /// parameters, module `const_exprs` and imported-package
    /// `const_exprs` recursively. Only names with a value appear in
    /// the map; the ternary/generate fold reads it to pick the live
    /// arm instead of billing both.
    pub fn elaboration_const_seed(&self, module: &TimingModule) -> crate::expr::ConstSeed {
        let mut seed = crate::expr::ConstSeed::from_names(self.elaboration_const_names(module));
        let resolver =
            crate::width::WidthResolver::new(module, &self.packages, &self.param_map_ints);
        for name in self.elaboration_const_names(module) {
            if let Some(v) = resolver.const_value(&name) {
                seed.values.insert(name, v);
            }
        }
        for (name, _) in &module.const_exprs {
            if let Some(v) = resolver.const_value(name) {
                seed.values.insert(name.clone(), v);
            }
        }
        // Header `#(parameter …)` defaults live on `TypedParameter`
        // (scoped `default_expr` / raw `default_text`), not in
        // `const_exprs`.
        for p in &module.parameters {
            if seed.values.contains_key(&p.name) {
                continue;
            }
            let text = p
                .default_expr
                .as_deref()
                .or(p.default_text.as_deref());
            if let Some(v) = text.and_then(|t| resolver.eval_text(t)) {
                seed.values.insert(p.name.clone(), v);
            }
        }
        seed
    }
}

/// Line-attributed cost for reports.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LineCost {
    /// File path.
    pub file: String,
    /// 1-based line.
    pub line: u32,
    /// Sum FO4 on that line.
    pub fo4: f64,
}

/// Region report for ranking.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegionReport {
    /// Region.
    pub region_id: RegionId,
    /// Module name.
    pub module: String,
    /// Total FO4.
    pub total_fo4: f64,
    /// Location.
    pub loc: SourceLoc,
}
