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
    pub max_mem_pages: Option<u32>,
    pub exports: Vec<Export>,
    pub bodies: Vec<Vec<Instr>>,
    pub memory: Vec<u8>,
    pub locals: Vec<u32>,
    pub has_memory: bool,
}

pub const MAX_MODULE_BYTES: usize = 1 << 20;
pub const MAX_MEMORY_PAGES: u32 = 16;
pub const MAX_FUNCTIONS: usize = 256;
pub const MAX_LOCALS: usize = 256;
pub const MAX_STACK: usize = 256;
pub const MAX_CONTROL_DEPTH: usize = 64;
pub const MAX_INSTRUCTIONS: usize = 65_536;
const MAX_NAME_BYTES: usize = 256;

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
    LocalTee(u32),
    Unreachable,
    Block(bool),
    Loop(bool),
    If(bool),
    Else,
    Br(u32),
    BrIf(u32),
    Select,
    I32Eqz,
    I32Eq,
    I32Ne,
    I32LtS,
    I32LtU,
    I32GtS,
    I32GtU,
    I32LeS,
    I32LeU,
    I32GeS,
    I32GeU,
    I32Mul,
    I32DivS,
    I32DivU,
    I32RemS,
    I32RemU,
    I32And,
    I32Or,
    I32Xor,
    I32Shl,
    I32ShrS,
    I32ShrU,
    I32Rotl,
    I32Rotr,
    I32Load { align: u32, offset: u32 },
    I32Load8S { align: u32, offset: u32 },
    I32Load8U { align: u32, offset: u32 },
    I32Load16S { align: u32, offset: u32 },
    I32Load16U { align: u32, offset: u32 },
    I32Store { align: u32, offset: u32 },
    I32Store8 { align: u32, offset: u32 },
    I32Store16 { align: u32, offset: u32 },
    MemorySize,
    MemoryGrow,
}

impl Instr {
    pub(crate) fn memory_access(&self) -> Option<(u32, u32, usize)> {
        match *self {
            Self::I32Load { align, offset } | Self::I32Store { align, offset } => {
                Some((align, offset, 4))
            }
            Self::I32Load8S { align, offset }
            | Self::I32Load8U { align, offset }
            | Self::I32Store8 { align, offset } => Some((align, offset, 1)),
            Self::I32Load16S { align, offset }
            | Self::I32Load16U { align, offset }
            | Self::I32Store16 { align, offset } => Some((align, offset, 2)),
            _ => None,
        }
    }
}

/// Decode a WASM binary.
pub fn decode(bytes: &[u8]) -> Result<Module, String> {
    if bytes.len() < 8 || &bytes[0..4] != b"\0asm" || bytes[4..8] != [1, 0, 0, 0] {
        return Err("not a WASM MVP module".into());
    }
    if bytes.len() > MAX_MODULE_BYTES {
        return Err("wasm module byte limit".into());
    }
    let mut m = Module {
        types: Vec::new(),
        imports: Vec::new(),
        func_types: Vec::new(),
        mem_pages: 0,
        max_mem_pages: None,
        exports: Vec::new(),
        bodies: Vec::new(),
        memory: Vec::new(),
        locals: Vec::new(),
        has_memory: false,
    };
    let mut i = 8usize;
    let mut last = 0;
    while i < bytes.len() {
        let id = bytes[i];
        i += 1;
        let (size, ni) = uleb(bytes, i)?;
        i = ni;
        let end = i
            .checked_add(size as usize)
            .ok_or("section size overflow")?;
        let payload = bytes.get(i..end).ok_or("truncated section")?;
        if id != 0 {
            if id <= last {
                return Err("duplicate or out-of-order section".into());
            }
            last = id;
        }
        match id {
            0 => {
                name(payload, 0)?;
            }
            1 => decode_types(&mut m, payload)?,
            2 => decode_imports(&mut m, payload)?,
            3 => decode_funcs(&mut m, payload)?,
            5 => decode_mem(&mut m, payload)?,
            7 => decode_exports(&mut m, payload)?,
            10 => decode_code(&mut m, payload)?,
            11 => decode_data(&mut m, payload)?,
            _ => return Err(format!("unsupported wasm section {id}")),
        }
        i = end;
    }
    validate(&m)?;
    Ok(m)
}

/// UI helper: `_start` calls `env.set_inner_text(id, val)` with strings in memory.
pub fn encode_ui_module(id: &str, val: &str) -> Vec<u8> {
    let vo = id.len().max(32);
    let mut mem = vec![0u8; (vo + val.len()).max(64)];
    mem[..id.len()].copy_from_slice(id.as_bytes());
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
    push_uleb(&mut memory, mem.len().div_ceil(65536).max(1) as u32);
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

pub fn validate(m: &Module) -> Result<(), String> {
    analyze(m).map(|_| ())
}

pub(crate) fn func_type(m: &Module, idx: u32) -> Result<&FuncType, String> {
    let idx = idx as usize;
    let ty = if idx < m.imports.len() {
        m.imports[idx].typeidx
    } else {
        *m.func_types
            .get(idx - m.imports.len())
            .ok_or("bad function index")?
    };
    m.types
        .get(ty as usize)
        .ok_or_else(|| "bad function type index".into())
}

pub(crate) struct BodyInfo {
    pub ends: Vec<usize>,
    pub alternatives: Vec<Option<usize>>,
    pub max_stack: usize,
}

pub(crate) fn analyze(m: &Module) -> Result<Vec<BodyInfo>, String> {
    if m.types.len() > MAX_FUNCTIONS
        || m.imports.len() > 64
        || m.func_types.len() + m.imports.len() > MAX_FUNCTIONS
        || m.exports.len() > MAX_FUNCTIONS
        || m.bodies.len() != m.func_types.len()
        || m.locals.len() != m.bodies.len()
    {
        return Err("function/code count mismatch or resource limit".into());
    }
    if m.mem_pages > MAX_MEMORY_PAGES
        || (!m.has_memory && (m.mem_pages != 0 || m.max_mem_pages.is_some()))
        || m.max_mem_pages
            .is_some_and(|max| max < m.mem_pages || max > 65536)
        || m.memory.len() != m.mem_pages as usize * 65536
    {
        return Err("invalid memory size".into());
    }
    for ty in &m.types {
        if ty.params > 32 || ty.results > 1 {
            return Err("unsupported function signature".into());
        }
    }
    for (idx, im) in m.imports.iter().enumerate() {
        let ty = func_type(m, idx as u32)?;
        let params = match (im.module.as_str(), im.name.as_str()) {
            ("env", crate::IMPORT_SET_INNER_TEXT) => 4,
            ("env", crate::IMPORT_SET_VISIBLE) => 3,
            ("env", crate::IMPORT_LOG | crate::IMPORT_FETCH | crate::IMPORT_OBJECT_CALL) => 2,
            _ => return Err(format!("unsupported import {}.{}", im.module, im.name)),
        };
        if ty.params != params || ty.results != 0 {
            return Err("host import signature mismatch".into());
        }
    }
    let mut names = std::collections::BTreeSet::new();
    for ex in &m.exports {
        if ex.name.len() > MAX_NAME_BYTES || !names.insert(&ex.name) {
            return Err("duplicate or oversized export name".into());
        }
        match ex.kind {
            0 => {
                func_type(m, ex.idx)?;
            }
            2 if ex.idx == 0 && m.has_memory => {}
            _ => return Err("unsupported or invalid export".into()),
        }
    }
    let mut total = 0usize;
    let mut info = Vec::with_capacity(m.bodies.len());
    for (idx, body) in m.bodies.iter().enumerate() {
        total = total
            .checked_add(body.len())
            .ok_or("instruction count overflow")?;
        if total > MAX_INSTRUCTIONS {
            return Err("wasm instruction limit".into());
        }
        let ty = func_type(m, (m.imports.len() + idx) as u32)?;
        let locals = (ty.params as usize)
            .checked_add(m.locals[idx] as usize)
            .ok_or("wasm locals overflow")?;
        if locals > MAX_LOCALS {
            return Err("wasm locals limit".into());
        }
        info.push(validate_body(m, body, locals, ty.results as usize)?);
    }
    Ok(info)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ControlKind {
    Function,
    Block,
    Loop,
    If,
}

struct Control {
    kind: ControlKind,
    start: usize,
    height: usize,
    results: usize,
    unreachable: bool,
    alternative: Option<usize>,
}

fn pop_type(height: &mut usize, control: &Control) -> Result<(), String> {
    if *height == control.height {
        if control.unreachable {
            return Ok(());
        }
        return Err("wasm operand stack underflow".into());
    }
    *height -= 1;
    Ok(())
}

fn validate_body(
    m: &Module,
    body: &[Instr],
    locals: usize,
    results: usize,
) -> Result<BodyInfo, String> {
    let mut info = BodyInfo {
        ends: vec![0; body.len()],
        alternatives: vec![None; body.len()],
        max_stack: 0,
    };
    let mut controls = vec![Control {
        kind: ControlKind::Function,
        start: 0,
        height: 0,
        results,
        unreachable: false,
        alternative: None,
    }];
    let mut height = 0;
    for (pc, ins) in body.iter().enumerate() {
        let current = controls
            .last_mut()
            .ok_or("instructions after function end")?;
        match ins {
            Instr::Nop => {}
            Instr::I32Const(_) => height += 1,
            Instr::LocalGet(i) | Instr::LocalSet(i) | Instr::LocalTee(i) => {
                if *i as usize >= locals {
                    return Err("bad local index".into());
                }
                if !matches!(ins, Instr::LocalGet(_)) {
                    pop_type(&mut height, current)?;
                }
                if !matches!(ins, Instr::LocalSet(_)) {
                    height += 1;
                }
            }
            Instr::I32Load { .. }
            | Instr::I32Load8S { .. }
            | Instr::I32Load8U { .. }
            | Instr::I32Load16S { .. }
            | Instr::I32Load16U { .. }
            | Instr::I32Store { .. }
            | Instr::I32Store8 { .. }
            | Instr::I32Store16 { .. } => {
                let (align, _, width) = ins.memory_access().ok_or("invalid memory instruction")?;
                if !m.has_memory || align > width.trailing_zeros() {
                    return Err("missing memory or invalid memory alignment".into());
                }
                pop_type(&mut height, current)?;
                if matches!(
                    ins,
                    Instr::I32Store { .. } | Instr::I32Store8 { .. } | Instr::I32Store16 { .. }
                ) {
                    pop_type(&mut height, current)?;
                } else {
                    height += 1;
                }
            }
            Instr::MemorySize | Instr::MemoryGrow => {
                if !m.has_memory {
                    return Err("memory instruction without memory".into());
                }
                if matches!(ins, Instr::MemoryGrow) {
                    pop_type(&mut height, current)?;
                }
                height += 1;
            }
            Instr::Drop => pop_type(&mut height, current)?,
            Instr::Select => {
                for _ in 0..3 {
                    pop_type(&mut height, current)?;
                }
                height += 1;
            }
            Instr::I32Eqz => {
                pop_type(&mut height, current)?;
                height += 1;
            }
            Instr::Call(idx) => {
                let ty = func_type(m, *idx)?;
                for _ in 0..ty.params {
                    pop_type(&mut height, current)?;
                }
                height += ty.results as usize;
            }
            Instr::Block(result) | Instr::Loop(result) | Instr::If(result) => {
                if matches!(ins, Instr::If(_)) {
                    pop_type(&mut height, current)?;
                }
                if controls.len() >= MAX_CONTROL_DEPTH {
                    return Err("wasm control depth limit".into());
                }
                controls.push(Control {
                    kind: match ins {
                        Instr::Loop(_) => ControlKind::Loop,
                        Instr::If(_) => ControlKind::If,
                        _ => ControlKind::Block,
                    },
                    start: pc,
                    height,
                    results: usize::from(*result),
                    unreachable: false,
                    alternative: None,
                });
            }
            Instr::Else => {
                if current.kind != ControlKind::If || current.alternative.is_some() {
                    return Err("unmatched else".into());
                }
                for _ in 0..current.results {
                    pop_type(&mut height, current)?;
                }
                if height != current.height {
                    return Err("if result stack mismatch".into());
                }
                current.alternative = Some(pc);
                current.unreachable = false;
                info.alternatives[current.start] = Some(pc);
            }
            Instr::End => {
                if current.kind == ControlKind::If
                    && current.results != 0
                    && current.alternative.is_none()
                {
                    return Err("result if requires else".into());
                }
                for _ in 0..current.results {
                    pop_type(&mut height, current)?;
                }
                if height != current.height {
                    return Err("block result stack mismatch".into());
                }
                let frame = controls.pop().ok_or("unmatched end")?;
                if frame.kind != ControlKind::Function {
                    info.ends[frame.start] = pc;
                    if let Some(alt) = frame.alternative {
                        info.ends[alt] = pc;
                    }
                }
                height += frame.results;
            }
            Instr::Br(depth) | Instr::BrIf(depth) => {
                if matches!(ins, Instr::BrIf(_)) {
                    pop_type(&mut height, current)?;
                }
                let target = controls
                    .len()
                    .checked_sub(*depth as usize)
                    .and_then(|n| n.checked_sub(1))
                    .ok_or("bad branch depth")?;
                let arity = if controls[target].kind == ControlKind::Loop {
                    0
                } else {
                    controls[target].results
                };
                let current = controls.last_mut().ok_or("branch outside function")?;
                for _ in 0..arity {
                    pop_type(&mut height, current)?;
                }
                if matches!(ins, Instr::BrIf(_)) {
                    height += arity;
                } else {
                    height = current.height;
                    current.unreachable = true;
                }
            }
            Instr::Return | Instr::Unreachable => {
                if matches!(ins, Instr::Return) {
                    for _ in 0..results {
                        pop_type(&mut height, current)?;
                    }
                }
                height = current.height;
                current.unreachable = true;
            }
            Instr::I32Add
            | Instr::I32Sub
            | Instr::I32Mul
            | Instr::I32DivS
            | Instr::I32DivU
            | Instr::I32RemS
            | Instr::I32RemU
            | Instr::I32And
            | Instr::I32Or
            | Instr::I32Xor
            | Instr::I32Shl
            | Instr::I32ShrS
            | Instr::I32ShrU
            | Instr::I32Rotl
            | Instr::I32Rotr
            | Instr::I32Eq
            | Instr::I32Ne
            | Instr::I32LtS
            | Instr::I32LtU
            | Instr::I32GtS
            | Instr::I32GtU
            | Instr::I32LeS
            | Instr::I32LeU
            | Instr::I32GeS
            | Instr::I32GeU => {
                pop_type(&mut height, current)?;
                pop_type(&mut height, current)?;
                height += 1;
            }
        }
        info.max_stack = info.max_stack.max(height);
        if height > MAX_STACK {
            return Err("wasm operand stack limit".into());
        }
    }
    if !controls.is_empty() {
        return Err("missing function end".into());
    }
    Ok(info)
}

fn decode_types(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, MAX_FUNCTIONS)?;
    for _ in 0..n {
        if p.get(i) != Some(&0x60) {
            return Err("bad functype".into());
        }
        i += 1;
        let (np, ni) = count(p, i, 32)?;
        i = value_types(p, ni, np)?;
        let (nr, ni) = count(p, i, 1)?;
        i = value_types(p, ni, nr)?;
        m.types.push(FuncType {
            params: np,
            results: nr,
        });
    }
    finish(p, i)
}

fn value_types(p: &[u8], i: usize, n: u32) -> Result<usize, String> {
    let end = i.checked_add(n as usize).ok_or("type count overflow")?;
    let types = p.get(i..end).ok_or("truncated value types")?;
    if types.iter().any(|t| *t != 0x7f) {
        return Err("only i32 value types supported".into());
    }
    Ok(end)
}

fn count(p: &[u8], i: usize, max: usize) -> Result<(u32, usize), String> {
    let (n, i) = uleb(p, i)?;
    if n as usize > max {
        return Err("wasm resource count limit".into());
    }
    Ok((n, i))
}

fn finish(p: &[u8], i: usize) -> Result<(), String> {
    if i != p.len() {
        return Err("trailing section bytes".into());
    }
    Ok(())
}

fn decode_imports(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, 64)?;
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
    finish(p, i)
}

fn decode_funcs(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, MAX_FUNCTIONS)?;
    for _ in 0..n {
        let (ty, ni) = uleb(p, i)?;
        i = ni;
        m.func_types.push(ty);
    }
    finish(p, i)
}

fn decode_mem(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, 1)?;
    if n == 0 {
        return finish(p, i);
    }
    let flags = *p.get(i).ok_or("mem flags")?;
    i += 1;
    if flags > 1 {
        return Err("unsupported memory flags".into());
    }
    let (min, ni) = count(p, i, MAX_MEMORY_PAGES as usize)?;
    i = ni;
    if flags == 1 {
        let (max, ni) = count(p, i, 65536)?;
        i = ni;
        if max < min {
            return Err("memory maximum below minimum".into());
        }
        m.max_mem_pages = Some(max);
    }
    finish(p, i)?;
    m.mem_pages = min;
    m.has_memory = true;
    m.memory.resize(min as usize * 65536, 0);
    Ok(())
}

fn decode_exports(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, MAX_FUNCTIONS)?;
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
    finish(p, i)
}

fn decode_code(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, MAX_FUNCTIONS)?;
    let mut total = 0;
    for _ in 0..n {
        let (size, ni) = uleb(p, i)?;
        i = ni;
        let end = i.checked_add(size as usize).ok_or("body size overflow")?;
        let body = p.get(i..end).ok_or("truncated body")?;
        let (nloc, mut j) = count(body, 0, MAX_LOCALS)?;
        let mut locals = 0;
        for _ in 0..nloc {
            let (cnt, nj) = count(body, j, MAX_LOCALS)?;
            value_types(body, nj, 1)?;
            j = nj + 1; // skip valtype
            locals += cnt;
            if locals as usize > MAX_LOCALS {
                return Err("wasm locals limit".into());
            }
        }
        let instrs = decode_expr(body.get(j..).ok_or("truncated locals")?)?;
        total += instrs.len();
        if total > MAX_INSTRUCTIONS {
            return Err("wasm instruction limit".into());
        }
        m.bodies.push(instrs);
        m.locals.push(locals);
        i = end;
    }
    finish(p, i)
}

fn decode_data(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, MAX_FUNCTIONS)?;
    if n != 0 && !m.has_memory {
        return Err("active data without memory".into());
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
        let off = off as u32 as usize;
        let end = i.checked_add(len as usize).ok_or("data size overflow")?;
        let src = p.get(i..end).ok_or("data bytes")?;
        let mem_end = off.checked_add(src.len()).ok_or("data offset overflow")?;
        m.memory
            .get_mut(off..mem_end)
            .ok_or("data outside memory")?
            .copy_from_slice(src);
        i = end;
    }
    finish(p, i)
}

fn decode_expr(p: &[u8]) -> Result<Vec<Instr>, String> {
    let mut i = 0usize;
    let mut out = Vec::new();
    while i < p.len() {
        if out.len() == MAX_INSTRUCTIONS {
            return Err("wasm instruction limit".into());
        }
        let op = p[i];
        i += 1;
        let ins = match op {
            0x00 => Instr::Unreachable,
            0x01 => Instr::Nop,
            0x02..=0x04 => {
                let result = match p.get(i) {
                    Some(0x40) => false,
                    Some(0x7f) => true,
                    _ => return Err("unsupported block type".into()),
                };
                i += 1;
                match op {
                    0x02 => Instr::Block(result),
                    0x03 => Instr::Loop(result),
                    _ => Instr::If(result),
                }
            }
            0x05 => Instr::Else,
            0x0b => Instr::End,
            0x0c | 0x0d | 0x10 | 0x20..=0x22 => {
                let (idx, ni) = uleb(p, i)?;
                i = ni;
                match op {
                    0x0c => Instr::Br(idx),
                    0x0d => Instr::BrIf(idx),
                    0x10 => Instr::Call(idx),
                    0x20 => Instr::LocalGet(idx),
                    0x21 => Instr::LocalSet(idx),
                    _ => Instr::LocalTee(idx),
                }
            }
            0x0f => Instr::Return,
            0x1a => Instr::Drop,
            0x1b => Instr::Select,
            0x28 | 0x2c..=0x2f | 0x36 | 0x3a | 0x3b => {
                let (align, ni) = uleb(p, i)?;
                let (offset, ni) = uleb(p, ni)?;
                i = ni;
                match op {
                    0x28 => Instr::I32Load { align, offset },
                    0x2c => Instr::I32Load8S { align, offset },
                    0x2d => Instr::I32Load8U { align, offset },
                    0x2e => Instr::I32Load16S { align, offset },
                    0x2f => Instr::I32Load16U { align, offset },
                    0x36 => Instr::I32Store { align, offset },
                    0x3a => Instr::I32Store8 { align, offset },
                    _ => Instr::I32Store16 { align, offset },
                }
            }
            0x3f | 0x40 => {
                if p.get(i) != Some(&0) {
                    return Err("memory index must be zero".into());
                }
                i += 1;
                if op == 0x3f {
                    Instr::MemorySize
                } else {
                    Instr::MemoryGrow
                }
            }
            0x41 => {
                let (v, ni) = ileb(p, i)?;
                i = ni;
                Instr::I32Const(v)
            }
            0x45 => Instr::I32Eqz,
            0x46 => Instr::I32Eq,
            0x47 => Instr::I32Ne,
            0x48 => Instr::I32LtS,
            0x49 => Instr::I32LtU,
            0x4a => Instr::I32GtS,
            0x4b => Instr::I32GtU,
            0x4c => Instr::I32LeS,
            0x4d => Instr::I32LeU,
            0x4e => Instr::I32GeS,
            0x4f => Instr::I32GeU,
            0x6a => Instr::I32Add,
            0x6b => Instr::I32Sub,
            0x6c => Instr::I32Mul,
            0x6d => Instr::I32DivS,
            0x6e => Instr::I32DivU,
            0x6f => Instr::I32RemS,
            0x70 => Instr::I32RemU,
            0x71 => Instr::I32And,
            0x72 => Instr::I32Or,
            0x73 => Instr::I32Xor,
            0x74 => Instr::I32Shl,
            0x75 => Instr::I32ShrS,
            0x76 => Instr::I32ShrU,
            0x77 => Instr::I32Rotl,
            0x78 => Instr::I32Rotr,
            other => return Err(format!("unsupported wasm opcode {other:#x}")),
        };
        out.push(ins);
    }
    Ok(out)
}

fn name(p: &[u8], i: usize) -> Result<(String, usize), String> {
    let (n, ni) = count(p, i, MAX_NAME_BYTES)?;
    let end = ni.checked_add(n as usize).ok_or("name size overflow")?;
    let s = p.get(ni..end).ok_or("truncated name")?;
    Ok((String::from_utf8(s.to_vec()).map_err(|_| "utf8 name")?, end))
}

fn uleb(p: &[u8], mut i: usize) -> Result<(u32, usize), String> {
    let mut r = 0u32;
    let mut sh = 0;
    loop {
        let b = *p.get(i).ok_or("uleb")?;
        i += 1;
        if sh == 28 && b & 0xf0 != 0 {
            return Err("uleb overflow".into());
        }
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
        if sh == 28 && (b & 0x80 != 0 || !matches!(b & 0x78, 0 | 0x78)) {
            return Err("ileb overflow".into());
        }
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

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn numeric(params: u32, results: u32, locals: u32, ops: &[u8]) -> Vec<u8> {
        numeric_with_memory(params, results, locals, ops, None)
    }

    pub(crate) fn numeric_with_memory(
        params: u32,
        results: u32,
        locals: u32,
        ops: &[u8],
        memory: Option<(u32, Option<u32>)>,
    ) -> Vec<u8> {
        let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
        let mut ty = vec![1, 0x60];
        push_uleb(&mut ty, params);
        ty.extend(std::iter::repeat_n(0x7f, params as usize));
        push_uleb(&mut ty, results);
        ty.extend(std::iter::repeat_n(0x7f, results as usize));
        section(&mut out, 1, &ty);
        section(&mut out, 3, &[1, 0]);
        if let Some((min, max)) = memory {
            let mut payload = vec![1, u8::from(max.is_some())];
            push_uleb(&mut payload, min);
            if let Some(max) = max {
                push_uleb(&mut payload, max);
            }
            section(&mut out, 5, &payload);
        }
        section(&mut out, 7, &[1, 4, b'm', b'a', b'i', b'n', 0, 0]);
        let mut body = vec![u8::from(locals != 0)];
        if locals != 0 {
            push_uleb(&mut body, locals);
            body.push(0x7f);
        }
        body.extend_from_slice(ops);
        let mut code = vec![1];
        push_uleb(&mut code, body.len() as u32);
        code.extend(body);
        section(&mut out, 10, &code);
        out
    }

    #[test]
    fn memory_immediates_types_and_limits_are_validated() {
        for (op, max_align, store) in [
            (0x28, 2, false),
            (0x2c, 0, false),
            (0x2d, 0, false),
            (0x2e, 1, false),
            (0x2f, 1, false),
            (0x36, 2, true),
            (0x3a, 0, true),
            (0x3b, 1, true),
        ] {
            for align in 0..=max_align + 1 {
                let mut ops = vec![0x41, 0];
                if store {
                    ops.extend([0x41, 1]);
                }
                ops.extend([op, align, 0, 0x0b]);
                let bytes = numeric_with_memory(0, u32::from(!store), 0, &ops, Some((1, Some(2))));
                assert_eq!(
                    decode(&bytes).is_ok(),
                    align <= max_align,
                    "{op:#x}/{align}"
                );
                assert!(decode(&numeric(0, u32::from(!store), 0, &ops)).is_err());
            }
        }
        for ops in [
            &[0x28, 2, 0, 0x0b][..],
            &[0x41, 0, 0x36, 2, 0, 0x0b],
            &[0x40, 0, 0x0b],
            &[0x3f, 1, 0x0b],
            &[0x41, 0, 0x40, 1, 0x0b],
            &[0x41, 0, 0x28, 2],
            &[0x41, 0, 0x28, 2, 0x80],
            &[0x41, 0, 0x28, 2, 0xff, 0xff, 0xff, 0xff, 0x10, 0x0b],
            &[0x41, 0, 0x29, 3, 0, 0x0b],
            &[0x06, 0x40, 0x0b, 0x0b],
            &[0xfc, 10, 0, 0, 0x0b],
        ] {
            assert!(
                decode(&numeric_with_memory(0, 1, 0, ops, Some((1, None)))).is_err(),
                "{ops:?}"
            );
        }
        for ops in [&[0x3f, 0, 0x0b][..], &[0x41, 0, 0x40, 0, 0x0b]] {
            assert!(decode(&numeric(0, 1, 0, ops)).is_err());
            assert!(decode(&numeric_with_memory(0, 1, 0, ops, Some((0, Some(0))))).is_ok());
        }
        for (min, max, valid) in [
            (0, Some(0), true),
            (1, Some(0), false),
            (1, Some(65536), true),
            (1, Some(65537), false),
            (17, None, false),
        ] {
            assert_eq!(
                decode(&numeric_with_memory(0, 0, 0, &[0x0b], Some((min, max)))).is_ok(),
                valid
            );
        }
        let mut m = decode(&numeric_with_memory(
            0,
            1,
            0,
            &[0x3f, 0, 0x0b],
            Some((1, Some(2))),
        ))
        .unwrap();
        assert_eq!(m.max_mem_pages, Some(2));
        m.max_mem_pages = Some(0);
        assert!(validate(&m).is_err());
        m.max_mem_pages = Some(65537);
        assert!(validate(&m).is_err());
        m.max_mem_pages = None;
        m.bodies[0] = vec![
            Instr::I32Const(0),
            Instr::I32Load {
                align: 3,
                offset: 0,
            },
            Instr::End,
        ];
        assert!(validate(&m).is_err());
        m.bodies[0] = vec![
            Instr::Unreachable,
            Instr::I32Load {
                align: 3,
                offset: 0,
            },
            Instr::End,
        ];
        assert!(validate(&m).is_err());
    }

    #[test]
    fn rejects_non_i32_types_and_bad_stacks() {
        let mut wrong_type = numeric(1, 0, 0, &[0x0b]);
        wrong_type[13] = 0x7e;
        assert!(decode(&wrong_type).is_err());
        for ops in [&[0x1a, 0x0b][..], &[0x41, 1, 0x0b], &[0x20, 0, 0x1a, 0x0b]] {
            assert!(decode(&numeric(0, 0, 0, ops)).is_err(), "{ops:?}");
        }
    }

    #[test]
    fn nested_unreachable_results_match_native_validation() {
        let bad_return = numeric(0, 0, 0, &[0x02, 0x7f, 0x41, 1, 0x0f, 0x0b, 0x0b]);
        let bad_branch = numeric(
            0,
            1,
            0,
            &[
                0x02, 0x7f, 0x41, 1, 0x02, 0x7f, 0x41, 2, 0x0c, 1, 0x0b, 0x0b, 0x0b,
            ],
        );
        for (bytes, hex) in [
            (&bad_return, "0061736d0100000001040160000003020100070801046d61696e00000a0a010800027f41010f0b0b"),
            (&bad_branch, "0061736d010000000105016000017f03020100070801046d61696e00000a10010e00027f4101027f41020c010b0b0b"),
        ] {
            use std::fmt::Write;
            let mut encoded = String::new();
            for b in bytes { write!(encoded, "{b:02x}").unwrap(); }
            assert_eq!(encoded, hex);
            let error = decode(bytes).unwrap_err();
            println!("native=false local=false error={error} hex={hex}");
            assert_eq!(error, "block result stack mismatch");
        }
        let valid: &[(u32, &[u8], &[i32])] = &[
            (0, &[0x02, 0x7f, 0x41, 1, 0x0f, 0x0b, 0x1a, 0x0b], &[]),
            (1, &[0x02, 0x7f, 0x41, 1, 0x0f, 0x0b, 0x0b], &[1]),
            (
                1,
                &[
                    0x02, 0x7f, 0x41, 1, 0x02, 0x7f, 0x41, 2, 0x0c, 1, 0x0b, 0x1a, 0x0b, 0x0b,
                ],
                &[2],
            ),
            (
                1,
                &[0x02, 0x7f, 0x02, 0x7f, 0x41, 2, 0x0c, 1, 0x0b, 0x0b, 0x0b],
                &[2],
            ),
        ];
        for (results, ops, expected) in valid {
            let m = decode(&numeric(0, *results, 0, ops)).unwrap();
            let actual =
                crate::run(&m, 0, &[], &mut crate::interp::tests::TestHost::default()).unwrap();
            println!("native=true local=true results={actual:?} ops={ops:02x?}");
            assert_eq!(&actual, expected);
        }
    }

    #[test]
    fn branch_and_return_operands_cannot_cross_current_frame_height() {
        for terminator in [&[0x0f][..], &[0x0c, 1]] {
            let mut invalid = vec![0x41, 1, 0x02, 0x40];
            invalid.extend_from_slice(terminator);
            invalid.extend([0x0b, 0x0b]);
            let error = decode(&numeric(0, 1, 0, &invalid)).unwrap_err();
            println!("native=false local=false error={error} ops={invalid:02x?}");
            assert_eq!(error, "wasm operand stack underflow");
            let mut valid = vec![0x41, 1, 0x02, 0x40, 0x41, 2];
            valid.extend_from_slice(terminator);
            valid.extend([0x0b, 0x0b]);
            let m = decode(&numeric(0, 1, 0, &valid)).unwrap();
            let actual =
                crate::run(&m, 0, &[], &mut crate::interp::tests::TestHost::default()).unwrap();
            println!("native=true local=true results={actual:?} ops={valid:02x?}");
            assert_eq!(actual, [2]);
        }
    }

    #[test]
    fn rejects_missing_end_and_trailing_instructions() {
        assert!(decode(&numeric(0, 0, 0, &[])).is_err());
        assert!(decode(&numeric(0, 0, 0, &[0x0b, 0x01])).is_err());
    }

    #[test]
    fn rejects_duplicate_unknown_and_trailing_sections() {
        let mut bytes = numeric(0, 0, 0, &[0x0b]);
        section(&mut bytes, 1, &[0]);
        assert!(decode(&bytes).is_err());
        let mut bytes = b"\0asm\x01\x00\x00\x00".to_vec();
        section(&mut bytes, 4, &[0]);
        assert!(decode(&bytes).is_err());
        let mut bytes = b"\0asm\x01\x00\x00\x00".to_vec();
        section(&mut bytes, 1, &[0, 0]);
        assert!(decode(&bytes).is_err());
    }

    #[test]
    fn rejects_leb_overflow_and_truncated_body_without_panic() {
        assert!(uleb(&[0xff, 0xff, 0xff, 0xff, 0x1f], 0).is_err());
        assert!(ileb(&[0xff, 0xff, 0xff, 0xff, 0x0f], 0).is_err());
        let mut bytes = b"\0asm\x01\x00\x00\x00".to_vec();
        section(&mut bytes, 10, &[1, 127, 0]);
        assert!(std::panic::catch_unwind(|| decode(&bytes))
            .unwrap()
            .is_err());
    }

    #[test]
    fn resource_limits_and_structural_types_are_enforced() {
        for memory in [&[1, 0, 17][..], &[1, 3, 1], &[2, 0, 1, 0, 1], &[1, 1, 2, 1]] {
            let mut bytes = b"\0asm\x01\x00\x00\x00".to_vec();
            section(&mut bytes, 5, memory);
            assert!(decode(&bytes).is_err());
        }
        assert!(decode(&numeric(0, 0, 257, &[0x0b])).is_err());
        assert!(decode(&numeric(32, 0, 225, &[0x0b])).is_err());
        let mut ops = vec![];
        for _ in 0..=MAX_STACK {
            ops.extend([0x41, 0]);
        }
        ops.extend(std::iter::repeat_n(0x1a, MAX_STACK + 1));
        ops.push(0x0b);
        assert!(decode(&numeric(0, 0, 0, &ops)).is_err());
        let mut ops = vec![];
        for _ in 0..MAX_CONTROL_DEPTH {
            ops.extend([0x02, 0x40]);
        }
        ops.extend(std::iter::repeat_n(0x0b, MAX_CONTROL_DEPTH + 1));
        assert!(decode(&numeric(0, 0, 0, &ops)).is_err());
        for ops in [
            &[0x10, 1, 0x0b][..],
            &[0x0c, 1, 0x0b],
            &[0x05, 0x0b],
            &[0x0c, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x0b],
            &[0x41, 0, 0x04, 0x7f, 0x41, 1, 0x0b, 0x1a, 0x0b],
            &[0x41, 0, 0x04, 0x40, 0x41, 1, 0x05, 0x0b, 0x0b],
        ] {
            assert!(decode(&numeric(0, 0, 0, ops)).is_err(), "{ops:?}");
        }
        let mut oversized = vec![0; MAX_MODULE_BYTES + 1];
        oversized[..8].copy_from_slice(b"\0asm\x01\x00\x00\x00");
        assert!(decode(&oversized).is_err());
    }

    #[test]
    fn signed_leb_boundaries_and_long_ui_strings_roundtrip() {
        for value in [i32::MIN, -65, -64, -1, 0, 63, 64, i32::MAX] {
            let mut bytes = vec![];
            push_ileb(&mut bytes, value);
            assert_eq!(ileb(&bytes, 0).unwrap(), (value, bytes.len()));
        }
        assert_eq!(
            uleb(&[0xff, 0xff, 0xff, 0xff, 0x0f], 0).unwrap().0,
            u32::MAX
        );
        assert_eq!(ileb(&[0xff, 0xff, 0xff, 0xff, 0x7f], 0).unwrap().0, -1);
        let m = decode(&encode_ui_module(&"a".repeat(100), &"b".repeat(200))).unwrap();
        assert_eq!(&m.memory[..100], vec![b'a'; 100]);
        assert_eq!(&m.memory[100..300], vec![b'b'; 200]);
    }

    #[test]
    fn truncations_and_deterministic_mutations_never_panic() {
        let bytes = encode_ui_module("status", "safe");
        for end in 0..bytes.len() {
            let _ = decode(&bytes[..end]);
        }
        for at in 8..bytes.len() {
            for value in [0, 1, 0x7f, 0x80, 0xff] {
                let mut mutated = bytes.clone();
                mutated[at] = value;
                if let Ok(m) = decode(&mutated) {
                    let _ = crate::run_with_fuel(
                        &m,
                        m.imports.len() as u32,
                        &[],
                        &mut crate::interp::tests::TestHost::default(),
                        64,
                    );
                }
            }
        }
    }

    #[test]
    fn rejects_data_outside_declared_memory() {
        let mut bytes = b"\0asm\x01\x00\x00\x00".to_vec();
        section(&mut bytes, 5, &[1, 0, 0]);
        section(&mut bytes, 11, &[1, 0, 0x41, 0, 0x0b, 1, 42]);
        assert!(decode(&bytes).is_err());
    }
}
