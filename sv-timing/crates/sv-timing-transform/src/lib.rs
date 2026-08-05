// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Multi-pass auto-correct: worklist, pipeline cuts, reorder stubs, pass driver.

#![deny(missing_docs)]
#![forbid(unsafe_code)]

//! Bounded IR transforms for structural timing repair.
//!
//! Catalog: `architecture/AUTO-CORRECT-CORE-API.md`.  
//! Policy gates: `architecture/DESIGN.md` (allowlist, allow-latency, GateInfo).

pub mod case_recover;
pub mod edit;
pub mod pass;
pub mod pipeline;
pub mod worklist;

pub use edit::{EditKind, EditRecord, EditTrace, EmitRhsRewrite};
pub use pass::{run_correct_passes, PassContext, PassPolicy, TransformError, TransformResult};
pub use pipeline::{
    balance_mux_on_path, expand_expr_spine_for_path, insert_register, rebalance_associative_node,
    schedule_pipeline_cuts, select_pipeline_cuts, split_assign, CutPlan, CutPoint,
};
pub use worklist::{order_worklist, order_worklist_with_plan, WorkItem, WorklistPolicy};

/// Transform kinds planned for v1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransformKind {
    /// Insert a pipeline register (always latency-changing).
    InsertReg,
    /// Split a continuous assign / wire expression.
    SplitAssign,
    /// Balance exclusive mux / priority select (latency-neutral).
    BalanceMux,
    /// Local statement reorder (independent ops only).
    ReorderLocal,
}
