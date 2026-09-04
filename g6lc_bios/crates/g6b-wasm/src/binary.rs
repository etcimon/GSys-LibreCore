// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! WASM binary encode/decode (MVP subset).

#![allow(missing_docs)]

/// One decoded module.
#[derive(Debug, Clone)]
pub struct Module {
    pub types: Vec<FuncType>,
    pub imports: Vec<Import>,
    pub func_types: Vec<u32>,
    pub mem_pages: u32,
    pub exports: Vec<Export>,
    pub bodies: Vec<Vec<Instr>>,
    pub memory: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct FuncType {
    pub params: u32,
    pub results: u32,
}

#[derive(Debug, Clone)]
pub struct Import {
    pub module: String,
    pub name: String,
    pub typeidx: u32,
}

#[derive(Debug, Clone)]
pub struct Export {
    pub name: String,
    pub kind: u8,
    pub idx: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Instr {
    End,
    Return,
    Drop,
    Nop,
    Call(u32),
    LocalGet(u32),
    LocalSet(u32),
    I32Const(i32),
    I32Add,
    I32Sub,
}

/// Decode a WASM binary.
pub fn decode(bytes: &[u8]) -> Result<Module, String> {
    if bytes.len() < 8 || &bytes[0..4] != b"\0asm" || bytes[4..8] != [1, 0, 0, 0] {
        return Err("not a WASM MVP module".into());
    }
    let mut m = Module {
        types: Vec::new(),
        imports: Vec::new(),
        func_types: Vec::new(),
        mem_pages: 0,
        exports: Vec::new(),
        bodies: Vec::new(),
        memory: Vec::new(),
    };
    let mut i = 8usize;
    while i < bytes.len() {
        let id = bytes[i];
        i += 1;
        let (size, ni) = uleb(bytes, i)?;
        i = ni;
        let end = i + size as usize;
        if end > bytes.len() {
            return Err("truncated section".into());
        }
        let payload = &bytes[i..end];
        match id {
            1 => decode_types(&mut m, payload)?,
            2 => decode_imports(&mut m, payload)?,
            3 => decode_funcs(&mut m, payload)?,
            5 => decode_mem(&mut m, payload)?,
            7 => decode_exports(&mut m, payload)?,
            10 => decode_code(&mut m, payload)?,
            11 => decode_data(&mut m, payload)?,
            _ => {}
        }
        i = end;
    }
    if m.mem_pages > 0 && m.memory.len() < (m.mem_pages as usize) * 65536 {
        m.memory.resize((m.mem_pages as usize) * 65536, 0);
    }
    Ok(m)
}

/// UI helper: `_start` calls `env.set_inner_text(id, val)` with strings in memory.
pub fn encode_ui_module(id: &str, val: &str) -> Vec<u8> {
    let mut mem = vec![0u8; 64];
    mem[..id.len()].copy_from_slice(id.as_bytes());
    let vo = 32usize;
    mem[vo..vo + val.len()].copy_from_slice(val.as_bytes());
    encode_module(id.len() as i32, val.len() as i32, vo as i32, &mem)
}

fn encode_module(id_len: i32, val_len: i32, val_off: i32, mem: &[u8]) -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    // type: (i32,i32,i32,i32)->()  and ()->()
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 4, 0x7f, 0x7f, 0x7f, 0x7f, 0]);
    types.extend_from_slice(&[0x60, 0, 0]);
    section(&mut out, 1, &types);

    let mut imports = Vec::new();
    push_uleb(&mut imports, 1);
    put_name(&mut imports, "env");
    put_name(&mut imports, "set_inner_text");
    imports.push(0x00);
    push_uleb(&mut imports, 0);
    section(&mut out, 2, &imports);

    let mut funcs = Vec::new();
    push_uleb(&mut funcs, 1);
    push_uleb(&mut funcs, 1);
    section(&mut out, 3, &funcs);

    let mut memory = Vec::new();
    push_uleb(&mut memory, 1);
    memory.push(0x00);
    push_uleb(&mut memory, 1);
    section(&mut out, 5, &memory);

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);

    let mut body = Vec::new();
    push_uleb(&mut body, 0); // locals
    body.push(0x41);
    push_ileb(&mut body, 0);
    body.push(0x41);
    push_ileb(&mut body, id_len);
    body.push(0x41);
    push_ileb(&mut body, val_off);
    body.push(0x41);
    push_ileb(&mut body, val_len);
    body.push(0x10);
    push_uleb(&mut body, 0);
    body.push(0x0b);
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, body.len() as u32);
    code.extend_from_slice(&body);
    section(&mut out, 10, &code);

    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.push(0x00);
    data.push(0x41);
    push_ileb(&mut data, 0);
    data.push(0x0b);
    push_uleb(&mut data, mem.len() as u32);
    data.extend_from_slice(mem);
    section(&mut out, 11, &data);
    out
}

fn section(out: &mut Vec<u8>, id: u8, payload: &[u8]) {
    out.push(id);
    push_uleb(out, payload.len() as u32);
    out.extend_from_slice(payload);
}

fn put_name(out: &mut Vec<u8>, s: &str) {
    push_uleb(out, s.len() as u32);
    out.extend_from_slice(s.as_bytes());
}

fn decode_types(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    for _ in 0..n {
        if i >= p.len() || p[i] != 0x60 {
            return Err("bad functype".into());
        }
        i += 1;
        let (np, ni) = uleb(p, i)?;
        i = ni + np as usize;
        let (nr, ni) = uleb(p, i)?;
        i = ni + nr as usize;
        m.types.push(FuncType {
            params: np,
            results: nr,
        });
    }
    Ok(())
}

fn decode_imports(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    for _ in 0..n {
        let (modn, ni) = name(p, i)?;
        i = ni;
        let (field, ni) = name(p, i)?;
        i = ni;
        let kind = *p.get(i).ok_or("truncated import")?;
        i += 1;
        if kind != 0 {
            return Err("only func imports".into());
        }
        let (ty, ni) = uleb(p, i)?;
        i = ni;
        m.imports.push(Import {
            module: modn,
            name: field,
            typeidx: ty,
        });
    }
    Ok(())
}

fn decode_funcs(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    for _ in 0..n {
        let (ty, ni) = uleb(p, i)?;
        i = ni;
        m.func_types.push(ty);
    }
    Ok(())
}

fn decode_mem(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    if n == 0 {
        return Ok(());
    }
    let flags = *p.get(i).ok_or("mem flags")?;
    i += 1;
    let (min, _) = uleb(p, i)?;
    let _ = flags;
    m.mem_pages = min.max(1);
    Ok(())
}

fn decode_exports(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    for _ in 0..n {
        let (nm, ni) = name(p, i)?;
        i = ni;
        let kind = *p.get(i).ok_or("export kind")?;
        i += 1;
        let (idx, ni) = uleb(p, i)?;
        i = ni;
        m.exports.push(Export {
            name: nm,
            kind,
            idx,
        });
    }
    Ok(())
}

fn decode_code(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    for _ in 0..n {
        let (size, ni) = uleb(p, i)?;
        i = ni;
        let end = i + size as usize;
        let body = &p[i..end];
        let (nloc, mut j) = uleb(body, 0)?;
        for _ in 0..nloc {
            let (cnt, nj) = uleb(body, j)?;
            j = nj + 1; // skip valtype
            let _ = cnt;
        }
        m.bodies.push(decode_expr(&body[j..])?);
        i = end;
    }
    Ok(())
}

fn decode_data(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = uleb(p, 0)?;
    if m.memory.is_empty() {
        m.memory.resize(65536, 0);
        if m.mem_pages == 0 {
            m.mem_pages = 1;
        }
    }
    for _ in 0..n {
        let kind = *p.get(i).ok_or("data kind")?;
        i += 1;
        if kind != 0 {
            return Err("only active data".into());
        }
        if p.get(i) != Some(&0x41) {
            return Err("data offset i32.const".into());
        }
        i += 1;
        let (off, ni) = ileb(p, i)?;
        i = ni;
        if p.get(i) != Some(&0x0b) {
            return Err("data offset end".into());
        }
        i += 1;
        let (len, ni) = uleb(p, i)?;
        i = ni;
        let off = off as usize;
        let src = p.get(i..i + len as usize).ok_or("data bytes")?;
        if off + src.len() > m.memory.len() {
            m.memory.resize(off + src.len(), 0);
        }
        m.memory[off..off + src.len()].copy_from_slice(src);
        i += len as usize;
    }
    Ok(())
}

fn decode_expr(p: &[u8]) -> Result<Vec<Instr>, String> {
    let mut i = 0usize;
    let mut out = Vec::new();
    while i < p.len() {
        let op = p[i];
        i += 1;
        match op {
            0x0b => out.push(Instr::End),
            0x0f => out.push(Instr::Return),
            0x01 => out.push(Instr::Nop),
            0x1a => out.push(Instr::Drop),
            0x10 => {
                let (idx, ni) = uleb(p, i)?;
                i = ni;
                out.push(Instr::Call(idx));
            }
            0x20 => {
                let (idx, ni) = uleb(p, i)?;
                i = ni;
                out.push(Instr::LocalGet(idx));
            }
            0x21 => {
                let (idx, ni) = uleb(p, i)?;
                i = ni;
                out.push(Instr::LocalSet(idx));
            }
            0x41 => {
                let (v, ni) = ileb(p, i)?;
                i = ni;
                out.push(Instr::I32Const(v));
            }
            0x6a => out.push(Instr::I32Add),
            0x6b => out.push(Instr::I32Sub),
            other => return Err(format!("unsupported wasm opcode {other:#x}")),
        }
    }
    Ok(out)
}

fn name(p: &[u8], i: usize) -> Result<(String, usize), String> {
    let (n, ni) = uleb(p, i)?;
    let s = p.get(ni..ni + n as usize).ok_or("truncated name")?;
    Ok((
        String::from_utf8(s.to_vec()).map_err(|_| "utf8 name")?,
        ni + n as usize,
    ))
}

fn uleb(p: &[u8], mut i: usize) -> Result<(u32, usize), String> {
    let mut r = 0u32;
    let mut sh = 0;
    loop {
        let b = *p.get(i).ok_or("uleb")?;
        i += 1;
        r |= u32::from(b & 0x7f) << sh;
        if b & 0x80 == 0 {
            return Ok((r, i));
        }
        sh += 7;
        if sh > 28 {
            return Err("uleb overflow".into());
        }
    }
}

fn ileb(p: &[u8], mut i: usize) -> Result<(i32, usize), String> {
    let mut r = 0i32;
    let mut sh = 0;
    loop {
        let b = *p.get(i).ok_or("ileb")?;
        i += 1;
        r |= i32::from(b & 0x7f) << sh;
        sh += 7;
        if b & 0x80 == 0 {
            if sh < 32 && (b & 0x40) != 0 {
                r |= !0 << sh;
            }
            return Ok((r, i));
        }
        if sh > 28 {
            return Err("ileb overflow".into());
        }
    }
}

fn push_uleb(out: &mut Vec<u8>, mut v: u32) {
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
        }
        out.push(b);
        if v == 0 {
            break;
        }
    }
}

fn push_ileb(out: &mut Vec<u8>, mut v: i32) {
    loop {
        let mut b = (v as u8) & 0x7f;
        v >>= 7;
        let done = (v == 0 && (b & 0x40) == 0) || (v == -1 && (b & 0x40) != 0);
        if !done {
            b |= 0x80;
        }
        out.push(b);
        if done {
            break;
        }
    }
}
