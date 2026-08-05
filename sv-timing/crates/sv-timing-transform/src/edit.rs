// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Edit trace — every automatic change is recorded with original file:line.

use serde::{Deserialize, Serialize};
use sv_timing_core::{NodeId, PathId, SourceLoc};

/// Kind of recorded edit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EditKind {
    /// Pipeline register insertion.
    InsertReg,
    /// Wire / assign split.
    SplitAssign,
    /// Local reorder.
    ReorderLocal,
    /// Associative expression rebalance (latency-neutral).
    RebalanceAssoc,
    /// Exclusive mux / priority-select balance (latency-neutral).
    BalanceMux,
    /// Name expansion / declaration materialization.
    ExpandName,
    /// Annotation only.
    Annotate,
}

/// One atomic edit.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EditRecord {
    /// Monotonic id within a run.
    pub id: u32,
    /// Kind.
    pub kind: EditKind,
    /// Origin locus in **source** RTL that justified the edit.
    pub origin: SourceLoc,
    /// Related path if any.
    pub path_id: Option<PathId>,
    /// Related node if any.
    pub node_id: Option<NodeId>,
    /// New identifier created (if any).
    pub new_name: Option<String>,
    /// FO4 before (path or region).
    pub fo4_before: Option<f64>,
    /// FO4 after estimate.
    pub fo4_after: Option<f64>,
    /// Human rationale.
    pub rationale: String,
    /// Optional replacement RHS for the origin assign line (BalanceMux / rebalance emit).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emit_rhs: Option<String>,
    /// Extra origin lines rewritten to an RHS (exclusive one-hot multi-arm wire-up).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub emit_rhs_extras: Vec<EmitRhsRewrite>,
    /// Optional dense always_comb / wire fragment injected before `endmodule`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emit_snippet: Option<String>,
}

/// Additional origin→RHS rewrite for multi-arm exclusive wire-up.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmitRhsRewrite {
    /// Source locus of the assign to rewrite.
    pub origin: SourceLoc,
    /// Replacement RHS text.
    pub emit_rhs: String,
}

/// Ordered edit history for a correct run.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EditTrace {
    /// Records in application order.
    pub records: Vec<EditRecord>,
}

impl EditTrace {
    /// Empty trace.
    pub fn new() -> Self {
        Self::default()
    }

    /// Append an edit (assigns id).
    pub fn record_edit(&mut self, mut rec: EditRecord) {
        rec.id = self.records.len() as u32;
        self.records.push(rec);
    }

    /// JSON export for debug.
    pub fn to_json_pretty(&self) -> Result<String, serde_json::Error> {
        serde_json::to_string_pretty(self)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::OriginKind;

    #[test]
    fn edit_trace_has_origin() {
        let mut t = EditTrace::new();
        t.record_edit(EditRecord {
            id: 0,
            kind: EditKind::SplitAssign,
            origin: SourceLoc {
                file: "a.sv".into(),
                start_line: 10,
                start_col: 1,
                end_line: 10,
                end_col: 5,
                byte_start: 0,
                byte_end: 1,
                origin: OriginKind::UserFile,
            },
            path_id: None,
            node_id: Some(3),
            new_name: Some("x_svt_w0".into()),
            fo4_before: Some(40.0),
            fo4_after: Some(20.0),
            rationale: "split".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        assert_eq!(t.records[0].origin.start_line, 10);
        assert!(t.to_json_pretty().unwrap().contains("a.sv"));
    }
}
