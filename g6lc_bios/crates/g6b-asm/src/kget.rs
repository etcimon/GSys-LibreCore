// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Kernel-GET table (`__kget`) — the bounded `{url → response-body}` map the
// guest `KernelGet`/`LwFetch` resolve `env.fetch("/bios/menu/<id>")` against.
// The bodies are the *guest* bodies the live kernel fetch produces
// (`RouterPort::fetch_text`, then the `items[]` extraction for menu faces),
// baked at pack time (`g6b_kernel::kget_pack`) so the guest serves byte-
// identical JSON with no host router. This is the read-only side of the
// BIOS-protocol fetch contract; `/bios/store` POSTs stay a host path.
//
// ```text
// +0   u32  magic 'G6KG' (KGET_MAGIC)
// +4   u32  n_entry
// +8   u32  blob_off                    — offset of the url/body byte pool
// +12  u32  reserved
// +16  entry[n] × 16B {url_off,url_len, json_off,json_len}
// +blob_off   url bytes ++ body bytes
// ```
//
// All offsets are absolute byte offsets from `__kget`. `url_*` names the
// fetch path the cell passes (`/bios/menu/main`, …); `json_*` is the body
// `libwasm_await_value` hands the cell. `KernelGet` linearly scans `n_entry`
// (bounded by `KGET_MAX_ENTRIES`), byte-compares the url, and returns the
// matching `json_*` span — `0` when no entry matches (the caller then
// interns an empty resolution, never a dangling pointer).
//
// `KSTR_*` — the `libwasm_await_value` string pool. A resolved body is
// copied into `__wasm_mem` just past the cell's declared `mem_pages`, and
// `{len,ptr}` is written at the cell's `raw` argument. The pool is *above*
// the cell's own memory image but *below* the `__jit` OOB bound, so the
// cell dereferences `ptr` freely while its allocator (which cannot grow,
// `memory.grow` is fail-closed) never reaches it.
#![allow(missing_docs)]

/// `__kget+0` — 'G6KG'.
pub const KGET_MAGIC: u32 = u32::from_le_bytes(*b"G6KG");
/// Header bytes before the entry table.
pub const KGET_HDR: i32 = 16;
/// Entry stride (4 × u32).
pub const KGET_ENT: i32 = 16;
/// `__kget` byte ceiling — a bounded BIOS-read table, far under `.rodata`.
pub const KGET_MAX_BYTES: usize = 0x4_0000;
/// `__kget` entry ceiling — `setup_reads` lists a bounded read set.
pub const KGET_MAX_ENTRIES: u32 = 32;

// Header field offsets (u32 words at fixed byte offsets).
pub const KGET_OFF_N: i32 = 4;
pub const KGET_OFF_BLOB: i32 = 8;

// Entry field offsets (relative to an entry base).
pub const KGET_E_URL_OFF: i32 = 0;
pub const KGET_E_URL_LEN: i32 = 4;
pub const KGET_E_JSON_OFF: i32 = 8;
pub const KGET_E_JSON_LEN: i32 = 12;

/// `__kget` string pool bytes reserved past `__wasm_mem`'s declared
/// `mem_pages`. `memory.size` reports `mem_pages` (read from `__jit_in`, not
/// `OFF_MEMB`), so the cell's heap bound never reaches this tail while
/// `OFF_MEMB` (the OOB bound) still lets it dereference the `ptr` we hand out.
pub const KGET_KSTR_BYTES: u64 = 60 * 1024;

/// `__asyncify_data` scratch bytes reserved *below* the string pool in the
/// same `__wasm_mem` tail — 8-byte `{pos,end}` descriptor plus the 64KiB
/// operand-stack the cell's `asyncify_start_unwind` pushes into it. `LwAwaitVoid`
/// sets `__asyncify_data` to the region base (`mem_pages*64KiB`).
pub const KGET_ASTK_BYTES: u64 = 8 + 64 * 1024;

/// Total `__wasm_mem` tail reserved past `mem_pages` — asyncify scratch then
/// the string pool. `OFF_MEMB` covers the whole tail; `memory.size` stays
/// `mem_pages`.
pub const KGET_TAIL_BYTES: u64 = KGET_ASTK_BYTES + KGET_KSTR_BYTES;

/// Encode a `{url → body}` set into the `__kget` image. Shared by the host
/// packer (`g6b_kernel::kget_pack`, real menu/store bodies) and exec tests
/// (a synthetic read set), so the format has one writer. `Err` on a table
/// that would exceed `KGET_MAX_*` — the caller then ships no `__kget`.
pub fn build(entries: &[(String, String)]) -> Result<Vec<u8>, String> {
    if entries.is_empty() || entries.len() > KGET_MAX_ENTRIES as usize {
        return Err(format!("kernel-get entries {}", entries.len()));
    }
    let n = entries.len() as u32;
    let blob_off = KGET_HDR as usize + entries.len() * KGET_ENT as usize;
    let mut blob: Vec<u8> = Vec::new();
    let mut table: Vec<u8> = Vec::new();
    for (url, body) in entries {
        let uoff = (blob_off + blob.len()) as u32;
        blob.extend_from_slice(url.as_bytes());
        let joff = (blob_off + blob.len()) as u32;
        blob.extend_from_slice(body.as_bytes());
        table.extend_from_slice(&uoff.to_le_bytes());
        table.extend_from_slice(&(url.len() as u32).to_le_bytes());
        table.extend_from_slice(&joff.to_le_bytes());
        table.extend_from_slice(&(body.len() as u32).to_le_bytes());
    }
    let mut out = Vec::with_capacity(blob_off + blob.len());
    out.extend_from_slice(&KGET_MAGIC.to_le_bytes());
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(&(blob_off as u32).to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&table);
    out.extend_from_slice(&blob);
    if out.len() > KGET_MAX_BYTES {
        return Err(format!(
            "kernel-get table {} exceeds {}",
            out.len(),
            KGET_MAX_BYTES
        ));
    }
    Ok(out)
}
