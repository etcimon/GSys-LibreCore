// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RTL/RVFI text trace ingestion.
//!
//! `corev_apu/tb/rvfi_tracer.sv` writes one `trace_rvfi_hart_%h.dasm` file per hart.  The file is
//! human-readable and is *not* the raw RVFI struct; this module turns it into the `CommitRecord`
//! stream the D1 tandem layer already consumes.
//!
//! The dasm format is not self-describing for `pc_wdata` or `order`, so the parser derives them:
//! `pc_wdata` is the next record's `pc_rdata` (or `pc + instruction size` for the final record), and
//! `order` is the zero-based line index.  The final record is marked `halt` when its instruction is
//! `wfi` or `ebreak`.

#![forbid(unsafe_code)]

use crate::CommitRecord;
use std::path::Path;

/// Parse a dasm text stream and return the commit records in execution order.
///
/// `hart` is the hart identifier to stamp into each record.  The dasm file does not repeat it.
pub fn parse_dasm(input: &str, hart: u32) -> Result<Vec<CommitRecord>, String> {
    let mut partials = Vec::new();
    let mut expecting_detail: Option<PartialRecord> = None;

    for raw in input.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }

        if line.starts_with("core") {
            // A core line always starts a new record.  If a previous record was still waiting for a
            // detail line, that detail is missing; keep what we have with no register/memory info.
            if let Some(p) = expecting_detail.take() {
                partials.push(p);
            }
            let p = parse_core_line(line)?;
            expecting_detail = Some(p);
            continue;
        }

        if let Some(mut p) = expecting_detail.take() {
            if is_detail_line(line) {
                apply_detail_line(&mut p, line)?;
                partials.push(p);
                continue;
            }
            // The next line was not a detail; this is the start of some other record or debug
            // output.  Keep the partial record and re-process the current line.
            partials.push(p);
        }

        if line.contains("exception @") {
            let p = parse_exception_line(line)?;
            partials.push(p);
            continue;
        }

        // Anything else (debug signals, warning banners, cycle dumps) is ignored.
    }

    if let Some(p) = expecting_detail.take() {
        partials.push(p);
    }

    Ok(build_records(partials, hart))
}

/// Parse a dasm file on disk, inferring the hart from `trace_rvfi_hart_<hart>.dasm`.
pub fn parse_dasm_file(path: &Path) -> Result<Vec<CommitRecord>, String> {
    let hart = hart_from_path(path);
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {}", path.display(), e))?;
    parse_dasm(&text, hart)
}

fn hart_from_path(path: &Path) -> u32 {
    if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
        if let Some(rest) = stem.strip_prefix("trace_rvfi_hart_") {
            return u32::from_str_radix(rest, 16).unwrap_or(0);
        }
    }
    0
}

#[derive(Default, Debug, Clone)]
struct PartialRecord {
    pc_rdata: u64,
    insn: u32,
    prv: u8,
    trap: bool,
    cause: u64,
    rd_addr: u8,
    rd_wdata: u64,
    frd_addr: u8,
    frd_wdata: u64,
    mem_addr: Option<u64>,
    mem_wdata: Option<u64>,
}

fn parse_core_line(line: &str) -> Result<PartialRecord, String> {
    // core   0: 0x<pc> (0x<insn>) DASM(0x<insn>)
    // core   INTERRUPT 0: 0x<pc> (0x<insn>) DASM(0x<insn>)
    let parts: Vec<&str> = line.split_whitespace().collect();
    // The fourth token (index 3) is the pc/insn pair for the normal case, but the INTERRUPT case has
    // one extra token.  Find the token that contains ":".
    let colon_idx = parts
        .iter()
        .position(|p| p.ends_with(':'))
        .ok_or_else(|| format!("no colon token in core line: {line}"))?;
    if colon_idx + 2 >= parts.len() {
        return Err(format!("truncated core line: {line}"));
    }
    let pc = parse_hex(parts[colon_idx + 1])?;
    let insn = parse_hex(
        parts[colon_idx + 2]
            .trim_start_matches('(')
            .trim_end_matches(')'),
    )? as u32;
    Ok(PartialRecord {
        pc_rdata: pc,
        insn,
        ..Default::default()
    })
}

fn is_detail_line(line: &str) -> bool {
    // The first token is the one-hex-digit mode.
    let first = line.split_whitespace().next().unwrap_or("");
    first.len() == 1 && first.chars().next().is_some_and(|c| c.is_ascii_hexdigit())
}

fn apply_detail_line(p: &mut PartialRecord, line: &str) -> Result<(), String> {
    // <mode> 0x<pc> (0x<insn>) [f<rd> 0x<wdata> | x<rd> 0x<wdata>] [mem ...]
    let mut tokens = line.split_whitespace().peekable();
    let mode = tokens.next().ok_or("empty detail line")?;
    p.prv = u8::from_str_radix(mode, 16).map_err(|_| format!("bad mode {mode}"))?;

    // PC token
    let _pc = tokens
        .next()
        .ok_or("missing pc in detail line")?
        .trim_end_matches(':');
    // The next token is (0x<insn>); consume it.
    let _ = tokens.next().ok_or("missing insn in detail line")?;

    while let Some(tok) = tokens.next() {
        if tok == "mem" {
            if let Some(addr) = tokens.next() {
                p.mem_addr = Some(parse_hex(addr)?);
            } else {
                return Err("mem without address".to_string());
            }
            if let Some(wdata) = tokens.peek() {
                if wdata.starts_with("0x") {
                    p.mem_wdata = Some(parse_hex(tokens.next().unwrap())?);
                }
            }
        } else if tok == "x" || tok.starts_with('x') {
            let addr = if tok == "x" {
                tokens.next().ok_or("missing integer register number")?
            } else {
                tok.strip_prefix('x').unwrap()
            };
            if !addr.is_empty() {
                p.rd_addr = addr
                    .parse()
                    .map_err(|_| format!("bad integer register {addr}"))?;
            }
            p.rd_wdata = tokens
                .next()
                .map(parse_hex)
                .ok_or("missing x write data")??;
        } else if tok == "f" || tok.starts_with('f') {
            let addr = if tok == "f" {
                tokens.next().ok_or("missing fp register number")?
            } else {
                tok.strip_prefix('f').unwrap()
            };
            if !addr.is_empty() {
                p.frd_addr = addr
                    .parse()
                    .map_err(|_| format!("bad fp register {addr}"))?;
            }
            p.frd_wdata = tokens
                .next()
                .map(parse_hex)
                .ok_or("missing f write data")??;
        }
    }

    Ok(())
}

fn parse_exception_line(line: &str) -> Result<PartialRecord, String> {
    // <CAUSE> exception @ 0x<pc> (0x<insn>)
    let mut tokens = line.split_whitespace();
    let cause_name = tokens.next().ok_or("empty exception line")?;
    let _at = tokens.next().ok_or("missing @ in exception line")?; // "exception"
    let _at2 = tokens.next().ok_or("missing @ in exception line")?; // "@"
    let pc = tokens
        .next()
        .map(parse_hex)
        .ok_or("missing pc in exception line")??;
    let insn = tokens
        .next()
        .map(|s| parse_hex(s.trim_start_matches('(').trim_end_matches(')')))
        .ok_or("missing insn in exception line")?? as u32;
    Ok(PartialRecord {
        pc_rdata: pc,
        insn,
        trap: true,
        cause: cause_name_to_code(cause_name),
        ..Default::default()
    })
}

fn build_records(partials: Vec<PartialRecord>, hart: u32) -> Vec<CommitRecord> {
    let mut out = Vec::with_capacity(partials.len());
    for (i, p) in partials.iter().enumerate() {
        let is_last = i == partials.len() - 1;
        let next_pc = partials.get(i + 1).map(|n| n.pc_rdata);
        let pc_wdata = match next_pc {
            Some(pc) => pc,
            None if p.trap => p.pc_rdata,
            None => p.pc_rdata + insn_size(p.insn) as u64,
        };
        let halt = is_last && is_halt_instruction(p.insn);
        out.push(CommitRecord {
            order: i as u64,
            hart,
            pc_rdata: p.pc_rdata,
            pc_wdata,
            insn: p.insn,
            trap: p.trap,
            cause: p.cause,
            prv: p.prv,
            halt,
            rd_addr: p.rd_addr,
            rd_wdata: p.rd_wdata,
            frd_addr: p.frd_addr,
            frd_wdata: p.frd_wdata,
        });
    }
    out
}

fn parse_hex(s: &str) -> Result<u64, String> {
    let s = s
        .strip_prefix("0x")
        .or_else(|| s.strip_prefix("0X"))
        .unwrap_or(s);
    u64::from_str_radix(s, 16).map_err(|_| format!("not a hex number: {s}"))
}

fn insn_size(insn: u32) -> u8 {
    if (insn & 0b11) == 0b11 {
        4
    } else {
        2
    }
}

fn is_halt_instruction(insn: u32) -> bool {
    // wfi  = 0x10500073
    // ebreak = 0x00100073
    matches!(insn, 0x1050_0073 | 0x0010_0073)
}

fn cause_name_to_code(name: &str) -> u64 {
    match name {
        "INSTR_ADDR_MISALIGNED" => 0x0,
        "INSTR_ACCESS_FAULT" => 0x1,
        "ILLEGAL_INSTR" => 0x2,
        "BREAKPOINT" => 0x3,
        "LD_ADDR_MISALIGNED" => 0x4,
        "LD_ACCESS_FAULT" => 0x5,
        "ST_ADDR_MISALIGNED" => 0x6,
        "ST_ACCESS_FAULT" => 0x7,
        "ENV_CALL_UMODE" => 0x8,
        "ENV_CALL_SMODE" => 0x9,
        "ENV_CALL_MMODE" => 0xb,
        "INSTR_PAGE_FAULT" => 0xc,
        "LOAD_PAGE_FAULT" => 0xd,
        "STORE_PAGE_FAULT" => 0xf,
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dasm_smoke_parses_to_records() {
        let text = "core   0: 0x1000 (0x00000293) DASM(0x00000293)\n\
                    3 0x1000 (0x00000293) x 5 0x0000000000000001\n\
                    core   0: 0x1004 (0x00000313) DASM(0x00000313)\n\
                    3 0x1004 (0x00000313) x 6 0x000000000000002a\n";
        let recs = parse_dasm(text, 0).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[0].pc_rdata, 0x1000);
        assert_eq!(recs[0].pc_wdata, 0x1004);
        assert_eq!(recs[0].insn, 0x0000_0293);
        assert_eq!(recs[0].rd_addr, 5);
        assert_eq!(recs[0].rd_wdata, 1);
        assert_eq!(recs[1].pc_rdata, 0x1004);
        assert_eq!(recs[1].pc_wdata, 0x1008);
    }

    #[test]
    fn dasm_exception_line_parses() {
        let text = "ILLEGAL_INSTR exception @ 0x1004 (0x00000000)\n";
        let recs = parse_dasm(text, 0).unwrap();
        assert_eq!(recs.len(), 1);
        assert!(recs[0].trap);
        assert_eq!(recs[0].cause, 2);
        assert_eq!(recs[0].pc_rdata, 0x1004);
        // Without a following record, the handler address is unknown; keep pc_rdata as a sentinel.
        assert_eq!(recs[0].pc_wdata, 0x1004);
    }

    #[test]
    fn dasm_last_wfi_is_halt() {
        let text = "core   0: 0x1000 (0x10500073) DASM(0x10500073)\n\
                    3 0x1000 (0x10500073)\n";
        let recs = parse_dasm(text, 0).unwrap();
        assert_eq!(recs.len(), 1);
        assert!(recs[0].halt);
        assert_eq!(recs[0].pc_wdata, 0x1004);
    }

    #[test]
    fn dasm_parses_real_cva6_trace() {
        let text = "core   0: 0x0000000000010000 (0xf1402573) DASM(f1402573)\n\
                     3 0x0000000000010000 (0xf1402573) x10 0x0000000000000001\n\
                     core   0: 0x0000000000010004 (0x00050463) DASM(00050463)\n\
                     3 0x0000000000010004 (0x00050463)\n\
                     core   0: 0x000000000001000c (0x00100413) DASM(00100413)\n\
                     3 0x000000000001000c (0x00100413) x 8 0x0000000000000001\n\
                     ILLEGAL_INSTR exception @ 0x0000000000010020 (0x0000)\n";
        let recs = parse_dasm(text, 0).unwrap();
        assert_eq!(recs.len(), 4);
        assert_eq!(recs[0].pc_rdata, 0x10000);
        assert_eq!(recs[0].rd_addr, 10);
        assert_eq!(recs[0].rd_wdata, 1);
        assert_eq!(recs[2].pc_rdata, 0x1000c);
        assert_eq!(recs[2].rd_addr, 8);
        assert!(recs[3].trap);
        assert_eq!(recs[3].cause, 2);
    }
}
