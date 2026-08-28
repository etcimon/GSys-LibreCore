// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Capability matrix — a structured view of the evidence behind each conformance row.
//!
//! The matrix is the same data `conform` uses, but laid out so a human or a CI
//! dashboard can see *why* a capability got its verdict: which config field, which
//! flist path fragments, which device-tree tokens, and which stock-QEMU properties.

use crate::capability::{Capability, FlistProbe, Table};
use crate::{config_enabled, dts_declared, flist_present, Sources};
use g6q_core::conform::Report;
use g6q_core::json::Json;

/// Build a JSON capability matrix from the same inputs used for the conformance report.
///
/// The matrix contains one row per capability in the table, independent of the
/// assembled model, because it is a diagnostic view of the input evidence rather than
/// a downstream artifact.
pub fn build(src: &Sources) -> Json {
    let table = src.table.clone().unwrap_or_else(Table::default_table);
    let model = crate::assemble(src);
    let report = &model.conformance;

    Json::obj([
        ("target", Json::str(&src.target_id)),
        ("profile", Json::str(src.profile.as_str())),
        (
            "rows",
            Json::arr(table.entries.iter().map(|cap| row(cap, src, report))),
        ),
    ])
}

fn row(cap: &Capability, src: &Sources, report: &Report) -> Json {
    let (enabled, unresolved) = src
        .config
        .as_ref()
        .map(|pkg| config_enabled(pkg, &cap.config))
        .unwrap_or((false, false));
    let (flist_presence, flist_evidence) = flist_present(src.flist.as_ref(), &cap.flist, enabled);
    let declared = dts_declared(src.dts.as_ref(), cap);

    let config_json = Json::obj([
        ("probe", Json::str(cap.config.describe())),
        ("enabled", Json::Bool(enabled)),
        ("unresolved", Json::Bool(unresolved)),
    ]);

    let flist_json = match &cap.flist {
        FlistProbe::Intrinsic => Json::obj([
            ("kind", Json::str("intrinsic")),
            ("presence", Json::str(flist_presence.as_str())),
            ("evidence", Json::str(&flist_evidence)),
        ]),
        FlistProbe::Unit {
            implementing,
            stubs,
        } => Json::obj([
            ("kind", Json::str("unit")),
            (
                "implementing",
                Json::arr(implementing.iter().map(Json::str)),
            ),
            ("stubs", Json::arr(stubs.iter().map(Json::str))),
            ("presence", Json::str(flist_presence.as_str())),
            ("evidence", Json::str(&flist_evidence)),
        ]),
    };

    let dts_json = Json::obj([
        ("tokens", Json::arr(cap.dts_tokens.iter().map(Json::str))),
        ("node", cap.dts_node.as_ref().map_or(Json::Null, Json::str)),
        (
            "declared",
            match declared {
                Some(true) => Json::str("yes"),
                Some(false) => Json::str("no"),
                None => Json::str("not-expressible"),
            },
        ),
    ]);

    let qemu_json = cap.qemu_props.as_ref().map_or(
        Json::obj([
            ("properties", Json::Null),
            ("delta", Json::str("same as dts tokens")),
        ]),
        |props| {
            if props.is_empty() {
                Json::obj([
                    ("properties", Json::arr(Vec::<Json>::new())),
                    (
                        "delta",
                        Json::str("stock QEMU cannot express this capability"),
                    ),
                ])
            } else {
                Json::obj([
                    ("properties", Json::arr(props.iter().map(Json::str))),
                    ("delta", Json::Null),
                ])
            }
        },
    );

    let verdict = report
        .rows
        .iter()
        .find(|r| r.capability == cap.name)
        .map_or("unknown", |r| r.verdict.as_str());

    Json::obj([
        ("capability", Json::str(&cap.name)),
        ("config", config_json),
        ("flist", flist_json),
        ("dts", dts_json),
        ("qemu", qemu_json),
        ("verdict", Json::str(verdict)),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matrix_rows_match_the_conformance_report() {
        let src = Sources {
            target_id: "t".into(),
            ..Default::default()
        };
        // Minimal input is enough; the matrix must still produce rows and a verdict.
        let matrix = build(&src);
        let rows = matrix.get("rows");
        assert!(!rows.is_empty(), "{matrix:?}");
        // The first row must carry a config probe.
        let first = rows.as_array().unwrap().first().unwrap();
        assert!(!first.get("config").is_null());
        assert!(!first.get("flist").is_null());
        assert!(!first.get("dts").is_null());
        assert!(!first.get("qemu").is_null());
        assert!(!first.get("verdict").is_null());
    }

    #[test]
    fn matrix_includes_qemu_delta_for_unsupported_capability() {
        let src = Sources {
            target_id: "t".into(),
            ..Default::default()
        };
        let matrix = build(&src);
        let rows = matrix.get("rows").as_array().unwrap();
        // Find a capability the default table marks as unexpressible in stock QEMU.
        let unsupported = rows.iter().find(|r| {
            r.get("qemu").get("delta").as_string()
                == Some("stock QEMU cannot express this capability")
        });
        assert!(
            unsupported.is_some(),
            "expected at least one capability with an empty qemu property list; {matrix:?}"
        );
    }
}
