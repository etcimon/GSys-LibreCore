// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

use crate::{args::Args, resolve};
use g6q_core::model::{AiDescLayout, FlagField};
use g6q_core::{Json, TargetModel};
use g6q_vm::device::AiIsland;
use g6q_vm::gemm;
use g6q_vm::mem::{PhysMem, Region};
use g6q_vm::numfmt::{row_bytes, NumFmt};
use std::collections::BTreeSet;
use std::io::Read;

const MAX_REQUEST: u64 = 32 * 1024 * 1024;
const MAX_SCRATCH: u64 = 64 * 1024 * 1024;
const MAX_MACS: u64 = 64 * 1024 * 1024;

struct Job {
    id: String,
    m: u32,
    n: u32,
    k: u32,
    lda: u32,
    ldb: u32,
    numfmt: u32,
    opcode_class: u32,
    a: Vec<u8>,
    b: Vec<u8>,
}

fn known_fields(value: &Json, allowed: &[&str]) -> Result<(), String> {
    let Json::Obj(fields) = value else {
        return Err("expected an object".into());
    };
    for key in fields.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(format!("unknown field {key}"));
        }
    }
    Ok(())
}

fn uint(value: &Json, name: &str, default: Option<u32>) -> Result<u32, String> {
    match value {
        Json::Obj(fields) if !fields.contains_key(name) => {
            default.ok_or_else(|| format!("missing {name}"))
        }
        _ => match value.get(name) {
            Json::Int(v) => u32::try_from(*v).map_err(|_| format!("{name} must be u32")),
            _ => Err(format!("{name} must be u32")),
        },
    }
}

fn hex_decode(value: &Json, name: &str) -> Result<Vec<u8>, String> {
    let s = value
        .get(name)
        .as_string()
        .ok_or_else(|| format!("{name} must be a hex string"))?;
    if s.len() % 2 != 0 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(format!(
            "{name} must contain pairs of hex digits without a prefix"
        ));
    }
    s.as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let digit = |b: u8| (b as char).to_digit(16).unwrap() as u8;
            Ok(digit(pair[0]) * 16 + digit(pair[1]))
        })
        .collect()
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 15) as usize] as char);
    }
    out
}

fn parse_request(text: &str) -> Result<Vec<Job>, String> {
    if text.len() as u64 > MAX_REQUEST {
        return Err("request exceeds 32 MiB".into());
    }
    let (mut quoted, mut escaped, mut depth) = (false, false, 0u32);
    for b in text.bytes() {
        if quoted {
            if escaped {
                escaped = false;
            } else if b == b'\\' {
                escaped = true;
            } else if b == b'"' {
                quoted = false;
            }
        } else if b == b'"' {
            quoted = true;
        } else if b == b'{' || b == b'[' {
            depth += 1;
            if depth > 3 {
                return Err("request nesting exceeds schema".into());
            }
        } else if b == b'}' || b == b']' {
            depth = depth.checked_sub(1).ok_or("unbalanced request")?;
        }
    }
    let request = Json::parse(text)?;
    known_fields(&request, &["schema", "jobs"])?;
    if request.get("schema").as_string() != Some("g6q.tensor-eval.v1") {
        return Err("expected schema g6q.tensor-eval.v1".into());
    }
    let jobs = request
        .get("jobs")
        .as_array()
        .ok_or("jobs must be an array")?;
    if jobs.is_empty() || jobs.len() > 256 {
        return Err("jobs must contain 1..256 entries".into());
    }
    let mut ids = BTreeSet::new();
    let mut total_macs = 0u64;
    jobs.iter().map(|value| {
        known_fields(value, &["id", "m", "n", "k", "numfmt", "a_hex", "b_hex", "lda", "ldb", "opcode_class"])?;
        let id = value.get("id").as_string().ok_or("id must be a string")?.to_string();
        if id.is_empty() || id.len() > 256 || !ids.insert(id.clone()) {
            return Err("ids must be unique, nonempty and at most 256 bytes".into());
        }
        let m = uint(value, "m", None)?;
        let n = uint(value, "n", None)?;
        let k = uint(value, "k", None)?;
        let lda = uint(value, "lda", Some(k))?;
        let ldb = uint(value, "ldb", Some(k))?;
        if m == 0 || n == 0 || k == 0 || lda < k || ldb < k || lda > u16::MAX as u32 || ldb > u16::MAX as u32 {
            return Err(format!("{id}: positive geometry and K <= lda/ldb <= 65535 required"));
        }
        let macs = u64::from(m).checked_mul(u64::from(n)).and_then(|v| v.checked_mul(u64::from(k))).ok_or("MAC count overflow")?;
        total_macs = total_macs.checked_add(macs).ok_or("MAC count overflow")?;
        if total_macs > MAX_MACS { return Err("request exceeds 64 Mi MACs".into()); }
        let numfmt = uint(value, "numfmt", None)?;
        let a = hex_decode(value, "a_hex")?;
        let b = hex_decode(value, "b_hex")?;
        if let Some(fmt) = NumFmt::from_abi(numfmt).filter(|fmt| *fmt != NumFmt::Sp24) {
            for (name, bytes, rows, stride) in [("A", &a, m, lda), ("B", &b, n, ldb)] {
                let row = row_bytes(fmt, stride as u64);
                let needed = (rows as u64 - 1).checked_mul(row).and_then(|v| v.checked_add(row_bytes(fmt, k as u64))).ok_or("buffer extent overflow")?;
                let full = (rows as u64).checked_mul(row).ok_or("buffer extent overflow")?;
                if (bytes.len() as u64) < needed || bytes.len() as u64 > full {
                    return Err(format!("{id}: {name} length must be {needed}..{full} bytes for the format/stride"));
                }
            }
        }
        Ok(Job { id, m, n, k, lda, ldb, numfmt, opcode_class: uint(value, "opcode_class", Some(0))?, a, b })
    }).collect()
}

fn flag_bits(field: FlagField, value: u32) -> Result<u32, String> {
    if field.shift >= 32
        || field.mask == 0
        || field.mask > (u32::MAX >> field.shift)
        || value & !field.mask != 0
    {
        return Err("numeric flag value/layout is not representable".into());
    }
    Ok(value << field.shift)
}

fn validate_contract(model: &TargetModel) -> Result<(), String> {
    let island = model
        .soc
        .ai_island
        .as_ref()
        .ok_or("model has no AI island")?;
    let layout = &island.desc_layout;
    if layout.operand_b_k_major != Some(true) {
        return Err(
            "tensor-eval requires published DESC_B_K_MAJOR=1 (operand_b_k_major=true)".into(),
        );
    }
    if layout.version.is_none() || layout.version.is_some_and(|v| v > u16::MAX as u64) {
        return Err("descriptor version unresolved or too wide".into());
    }
    if island.config.dtype_mask.is_none() {
        return Err("format grant mask unresolved".into());
    }
    if layout.desc_bytes == 0 || layout.desc_bytes > 4096 {
        return Err("descriptor extent must be 1..4096 bytes".into());
    }
    let flags = layout.flags_layout.ok_or("flags layout unresolved")?;
    if flags.dtype_combined {
        return Err("combined dtype flags are unresolved".into());
    }
    let numfmt = flags.numfmt.ok_or("numfmt layout unresolved")?;
    let numfmt_bits = flag_bits(numfmt, numfmt.mask)?;
    let mut occupied = numfmt_bits;
    let mut flag_fields = vec![FlagField {
        shift: flags.dtype_shift,
        mask: flags.dtype_mask,
    }];
    flag_fields.extend(flags.ew);
    flag_fields.extend(flags.accmode);
    if let Some(shift) = flags.sp24_bit {
        flag_fields.push(FlagField { shift, mask: 1 });
    }
    for field in flag_fields {
        let bits = flag_bits(field, field.mask)?;
        if occupied & bits != 0 {
            return Err("overlapping arithmetic flags".into());
        }
        occupied |= bits;
    }
    let mut used = vec![false; layout.desc_bytes as usize];
    for field in layout.fields.values() {
        let end = field
            .offset
            .checked_add(field.size)
            .ok_or("descriptor field overflow")?;
        if !matches!(field.size, 2 | 4 | 8)
            || end > layout.desc_bytes
            || field.offset % field.size != 0
            || field.bit_low != field.offset * 8
            || field.bit_high.checked_add(1) != Some(end * 8)
        {
            return Err("unsupported descriptor field geometry".into());
        }
        for byte in &mut used[field.offset as usize..end as usize] {
            if *byte {
                return Err("overlapping descriptor fields".into());
            }
            *byte = true;
        }
    }
    for (name, width) in [
        ("version", 2),
        ("op", 2),
        ("flags", 4),
        ("m", 4),
        ("n", 4),
        ("k", 4),
        ("ld_ab", 4),
        ("ptr_a", 8),
        ("ptr_b", 8),
        ("ptr_c", 8),
    ] {
        let field = layout
            .fields
            .get(name)
            .ok_or_else(|| format!("missing descriptor field {name}"))?;
        if field.size > width {
            return Err(format!("descriptor field {name} exceeds executor width"));
        }
    }
    if layout.op("OP_GEMM").is_none_or(|v| v > u16::MAX as u64) {
        return Err("OP_GEMM unresolved or too wide".into());
    }
    let mut statuses = BTreeSet::new();
    for name in ["ST_OK", "ST_ERR", "ST_BAD_VER", "ST_BAD_OP", "ST_BAD_FMT"] {
        let v = layout
            .status(name)
            .ok_or_else(|| format!("missing status {name}"))?;
        if v > u16::MAX as u64 || !statuses.insert(v) {
            return Err("status codes must be distinct u16 values".into());
        }
    }
    let (base, len) = model.soc.dram.ok_or("model DRAM unresolved")?;
    if len == 0 || base.checked_add(len).is_none() {
        return Err("invalid model DRAM extent".into());
    }
    Ok(())
}

fn put(desc: &mut [u8], layout: &AiDescLayout, name: &str, value: u64) -> Result<(), String> {
    let field = layout
        .fields
        .get(name)
        .ok_or_else(|| format!("missing field {name}"))?;
    if field.size < 8 && value >> (field.size * 8) != 0 {
        return Err(format!("{name} value exceeds published field width"));
    }
    desc[field.offset as usize..(field.offset + field.size) as usize]
        .copy_from_slice(&value.to_le_bytes()[..field.size as usize]);
    Ok(())
}

fn allocate(cursor: &mut u64, len: u64, end: u64) -> Result<u64, String> {
    let base = cursor.checked_add(63).ok_or("scratch alignment overflow")? & !63;
    *cursor = base
        .checked_add(len.max(1))
        .ok_or("scratch extent overflow")?;
    if *cursor > end {
        return Err("job scratch exceeds model DRAM".into());
    }
    Ok(base)
}

fn source(model: &TargetModel) -> Json {
    Json::obj([
        ("target_id", Json::str(&model.target_id)),
        ("profile", Json::str(model.profile.as_str())),
        ("faithful", Json::Bool(model.faithful)),
        (
            "model_fingerprint",
            Json::str(resolve::digest(&model.to_json().to_pretty())),
        ),
        ("provenance", model.provenance.to_json()),
    ])
}

fn evaluate_job(job: &Job, model: &TargetModel, stamp: &Json) -> Result<Json, String> {
    let island = model.soc.ai_island.as_ref().unwrap();
    let layout = &island.desc_layout;
    let (base, len) = model.soc.dram.unwrap();
    let end = base + len;
    let mut cursor = base;
    let desc_addr = allocate(&mut cursor, layout.desc_bytes, end)?;
    let a_addr = allocate(&mut cursor, job.a.len() as u64, end)?;
    let b_addr = allocate(&mut cursor, job.b.len() as u64, end)?;
    let c_len = (job.m as u64) * (job.n as u64) * 4;
    let c_addr = allocate(&mut cursor, c_len, end)?;
    if cursor - base > MAX_SCRATCH {
        return Err("job scratch exceeds 64 MiB".into());
    }
    let mut desc = vec![0; layout.desc_bytes as usize];
    let flags_layout = layout.flags_layout.unwrap();
    let encoded_fmt = flag_bits(flags_layout.numfmt.unwrap(), job.numfmt);
    let mut flags = encoded_fmt.as_ref().copied().unwrap_or(0);
    if job.numfmt == NumFmt::Int4 as u32 {
        if let Some(ew) = flags_layout.ew {
            flags |= flag_bits(ew, 1)?;
        }
    }
    for (name, value) in [
        ("version", layout.version.unwrap()),
        ("op", layout.op("OP_GEMM").unwrap()),
        ("flags", flags as u64),
        ("m", job.m as u64),
        ("n", job.n as u64),
        ("k", job.k as u64),
        ("ld_ab", (job.lda | (job.ldb << 16)) as u64),
        ("ptr_a", a_addr),
        ("ptr_b", b_addr),
        ("ptr_c", c_addr),
    ] {
        put(&mut desc, layout, name, value)?;
    }
    let mut mem = PhysMem::new();
    mem.add(Region::from_file(desc_addr, &desc));
    mem.add(Region::from_file(a_addr, &job.a));
    mem.add(Region::from_file(b_addr, &job.b));
    let mut c = Region::new(c_addr, c_len);
    c.data.fill(0xa5);
    mem.add(c);
    let event = AiIsland::read_descriptor_event(&mem, desc_addr, 0, island)
        .ok_or("descriptor decode failed")?;
    let (status, writes, reason) = if encoded_fmt.is_err() {
        (
            layout.status("ST_BAD_FMT").unwrap() as u16,
            Vec::new(),
            "numfmt-not-representable".to_string(),
        )
    } else {
        match gemm::plan(&mem, &event, island) {
            Ok(result) if !result.skipped => (result.status, result.c_writes, String::new()),
            Ok(_) => return Err("GEMM unexpectedly skipped".into()),
            Err((reject, status)) => (status, Vec::new(), reject.as_str().to_string()),
        }
    };
    let executed = status as u64 == layout.status("ST_OK").unwrap() && !writes.is_empty();
    if executed && writes.len() as u64 * 4 != c_len {
        return Err("incomplete C write plan".into());
    }
    for (addr, _) in &writes {
        if *addr < c_addr || addr.checked_add(4).is_none_or(|v| v > c_addr + c_len) || addr % 4 != 0
        {
            return Err("C write outside scratch allocation".into());
        }
    }
    for (addr, word) in writes {
        mem.write_le::<4>(addr, word as u32 as u64)
            .map_err(|e| e.to_string())?;
    }
    let mut c_bytes = Vec::new();
    for off in 0..c_len {
        let byte = mem.read_le::<1>(c_addr + off).map_err(|e| e.to_string())? as u8;
        if executed {
            c_bytes.push(byte);
        } else if byte != 0xa5 {
            return Err("rejected job modified C".into());
        }
    }
    let status_name = layout
        .statuses
        .iter()
        .find(|(_, value)| **value == status as u64)
        .map(|(name, _)| name.as_str())
        .ok_or("unpublished result status")?;
    Ok(Json::obj([
        ("id", Json::str(&job.id)),
        ("numfmt", Json::Int(job.numfmt as i64)),
        (
            "numfmt_name",
            Json::str(NumFmt::from_abi(job.numfmt).map_or("unknown", NumFmt::as_str)),
        ),
        ("m", Json::Int(job.m as i64)),
        ("n", Json::Int(job.n as i64)),
        ("k", Json::Int(job.k as i64)),
        ("lda", Json::Int(job.lda as i64)),
        ("ldb", Json::Int(job.ldb as i64)),
        ("ldc", Json::Int(job.n as i64)),
        ("opcode_class", Json::Int(job.opcode_class as i64)),
        ("status", Json::Int(status as i64)),
        ("status_name", Json::str(status_name)),
        ("executed", Json::Bool(executed)),
        ("rejected", Json::Bool(!executed)),
        ("reason", Json::str(reason)),
        ("C_hex", Json::str(hex(&c_bytes))),
        (
            "descriptor_hex",
            Json::str(if encoded_fmt.is_ok() {
                hex(&desc)
            } else {
                String::new()
            }),
        ),
        ("scratch_bytes", Json::Int((cursor - base) as i64)),
        ("source", stamp.clone()),
    ]))
}

fn evaluate(text: &str, model: &TargetModel) -> Result<Json, String> {
    let jobs = parse_request(text)?;
    validate_contract(model)?;
    let stamp = source(model);
    let results = jobs
        .iter()
        .map(|job| evaluate_job(job, model, &stamp))
        .collect::<Result<Vec<_>, _>>()?;
    let failed = results
        .iter()
        .filter(|job| job.get("executed") != &Json::Bool(true))
        .count();
    Ok(Json::obj([
        ("schema", Json::str("g6q.tensor-eval-result.v1")),
        ("backend", Json::str("b3-descriptor-executor")),
        ("qemu_guest", Json::Bool(false)),
        ("rtl_cycles", Json::Bool(false)),
        ("fp_exception_flags", Json::Bool(false)),
        ("source", stamp),
        ("model", model.to_json()),
        ("job_count", Json::Int(results.len() as i64)),
        ("failed_count", Json::Int(failed as i64)),
        ("executed_count", Json::Int((results.len() - failed) as i64)),
        ("jobs", Json::arr(results)),
    ]))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_model() -> TargetModel {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/ai");
        let args = Args::parse(vec![
            "tensor-eval".into(),
            "--target".into(),
            "software-exploration".into(),
            "--config-pkg".into(),
            root.join("ai_soc_config_pkg.sv")
                .to_string_lossy()
                .into_owned(),
            "--flist".into(),
            root.join("eval-manifest.f").to_string_lossy().into_owned(),
            "--dts".into(),
            root.join("board.dts").to_string_lossy().into_owned(),
        ]);
        g6q_ingest::assemble(&resolve::resolve(&args).unwrap().sources)
    }

    const JOBS: &str = include_str!("../../../fixtures/ai/tensor-eval-jobs.json");

    #[test]
    fn native_fixture_all_formats_and_rejections() {
        let mut model = fixture_model();
        model.soc.dram = Some((0x1_0000_0000, 0x1_0000_0000));
        let result = evaluate(JOBS, &model).unwrap();
        assert_eq!(result.get("failed_count"), &Json::Int(2));
        assert_eq!(result.get("executed_count"), &Json::Int(9));
        let jobs = result.get("jobs").as_array().unwrap();
        for (i, job) in jobs.iter().enumerate().take(7) {
            let want = if i < 2 {
                "010000000200000003000000030000000400000007000000"
            } else {
                "0000803f000000400000404000004040000080400000e040"
            };
            assert_eq!(job.get("C_hex").as_string(), Some(want));
            assert_eq!(job.get("status_name").as_string(), Some("ST_OK"));
            assert_eq!(job.get("scratch_bytes"), &Json::Int(216));
        }
        assert_eq!(jobs[7].get("C_hex").as_string(), Some("060000000f000000"));
        assert_eq!(jobs[8].get("C_hex").as_string(), Some("0000c07f"));
        for job in &jobs[9..] {
            assert_eq!(job.get("C_hex").as_string(), Some(""));
            assert_eq!(job.get("status_name").as_string(), Some("ST_BAD_FMT"));
            assert_eq!(job.get("executed"), &Json::Bool(false));
        }
        assert_eq!(result.get("model"), &model.to_json());
        assert_eq!(evaluate(JOBS, &model).unwrap(), result);
    }

    #[test]
    fn loaded_mask_and_layout_are_authoritative() {
        let mut model = fixture_model();
        model.soc.ai_island.as_mut().unwrap().config.dtype_mask = Some(3);
        let result = evaluate(JOBS, &model).unwrap();
        assert_eq!(result.get("executed_count"), &Json::Int(3));
        assert_eq!(result.get("failed_count"), &Json::Int(8));
        for fact in [None, Some(false)] {
            model
                .soc
                .ai_island
                .as_mut()
                .unwrap()
                .desc_layout
                .operand_b_k_major = fact;
            assert!(evaluate(JOBS, &model)
                .unwrap_err()
                .contains("DESC_B_K_MAJOR"));
        }
    }

    #[test]
    fn malformed_requests_never_become_success() {
        let base = r#"{"schema":"g6q.tensor-eval.v1","jobs":[{"id":"x","m":1,"n":1,"k":1,"numfmt":0,"a_hex":"01","b_hex":"01"}]}"#;
        assert!(parse_request(base).is_ok());
        for bad in [
            base.replace("\"m\":1", "\"m\":0"),
            base.replace("\"m\":1", "\"m\":true"),
            base.replace("\"m\":1", "\"m\":4294967296"),
            base.replace("\"m\":1", "\"m\":1,\"m\":2"),
            base.replace("\"m\":1", "\"m\":1,\"typo\":2"),
            base.replace("\"m\":1", "\"m\":1,\"lda\":0"),
            base.replace("\"m\":1", "\"m\":1,\"lda\":65536"),
            base.replace("\"m\":1", "\"m\":1,\"lda\":null"),
            base.replace("\"01\"", "\"0g\""),
            base.replace("\"01\"", "\"0\""),
            base.replace("\"01\"", "\"\""),
            base.replace("\"n\":1", "\"n\":1000000000"),
            "[".repeat(10000),
        ] {
            assert!(parse_request(&bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn model_relayout_and_memory_limits_are_checked() {
        let mut model = fixture_model();
        let layout = &mut model.soc.ai_island.as_mut().unwrap().desc_layout;
        for name in ["ptr_a", "ptr_b"] {
            let field = layout.fields.get_mut(name).unwrap();
            field.offset = if name == "ptr_a" { 32 } else { 24 };
            field.bit_low = field.offset * 8;
            field.bit_high = field.bit_low + 63;
        }
        assert!(evaluate(JOBS, &model).is_ok());
        model.soc.dram = Some((u64::MAX - 128, 256));
        assert!(evaluate(JOBS, &model).is_err());
        model.soc.dram = Some((0x100000, 100));
        assert!(evaluate(JOBS, &model).is_err());
    }
}

pub(crate) fn command(args: &Args) -> Result<(), String> {
    let request_path = args
        .value("request")
        .ok_or("tensor-eval requires --request JOBS.json")?;
    let result_path = args
        .value("result")
        .ok_or("tensor-eval requires --result RESULT.json")?;
    if request_path == result_path
        || std::fs::canonicalize(result_path)
            .ok()
            .is_some_and(|p| Some(p) == std::fs::canonicalize(request_path).ok())
    {
        return Err("request and result must be different files".into());
    }
    let outcome = (|| {
        let file =
            std::fs::File::open(request_path).map_err(|e| format!("cannot open request: {e}"))?;
        let mut text = String::new();
        file.take(MAX_REQUEST + 1)
            .read_to_string(&mut text)
            .map_err(|e| format!("cannot read request: {e}"))?;
        let resolved = resolve::resolve(args)?;
        let model = g6q_ingest::assemble(&resolved.sources);
        evaluate(&text, &model)
    })();
    let result = outcome.as_ref().cloned().unwrap_or_else(|error| {
        Json::obj([
            ("schema", Json::str("g6q.tensor-eval-result.v1")),
            ("backend", Json::str("b3-descriptor-executor")),
            ("qemu_guest", Json::Bool(false)),
            ("rtl_cycles", Json::Bool(false)),
            ("error", Json::str(error)),
            ("jobs", Json::arr([])),
        ])
    });
    std::fs::write(result_path, result.to_pretty())
        .map_err(|e| format!("cannot write result: {e}"))?;
    outcome.map(|_| ())
}
