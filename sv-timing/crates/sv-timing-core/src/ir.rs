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
            (RegClock { .. } | RegData { .. }, RegData { .. } | RegClock { .. }) => PathKind::RegToReg,
            (InputPort { .. }, OutputPort { .. }) => PathKind::InToOut,
            (InputPort { .. }, RegData { .. } | RegClock { .. }) => PathKind::InToReg,
            (RegClock { .. } | RegData { .. }, OutputPort { .. }) => PathKind::RegToOut,
            _ => PathKind::InToOut,
        }
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
    /// Source locus of the generate loop.
    pub loc: SourceLoc,
    /// Continuous assigns / statements counted inside (timing density hint).
    pub body_assign_count: u32,
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
    /// `import pkg::*` / package scopes referenced (any package name).
    pub package_imports: Vec<String>,
    /// Module instances nested in this module body.
    pub instances: Vec<ModuleInstance>,
    /// Source span of module header.
    pub loc: SourceLoc,
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
    /// Typedef / struct type names.
    pub typedefs: Vec<String>,
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
    /// True when package-mode denser surface was requested.
    #[serde(default)]
    pub package_mode: bool,
    /// Post-emptive path exceptions / classifications (also denormalized on each path).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub path_exceptions: Vec<crate::path_class::PathException>,
    /// Versions.
    pub versions: VersionBanner,
}

impl TimingDesign {
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
            package_mode: false,
            path_exceptions: Vec::new(),
            versions: VersionBanner {
                package: crate::PACKAGE_VERSION.to_string(),
                ir: crate::IR_VERSION.to_string(),
                measurement: crate::MEASUREMENT_VERSION.to_string(),
                cost_model: "fo4-v1".into(),
                parser_pin: crate::PARSER_PIN_HINT.to_string(),
            },
        }
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
