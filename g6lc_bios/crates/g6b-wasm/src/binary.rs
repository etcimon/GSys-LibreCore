// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! WASM binary encode/decode (MVP subset).

#![allow(missing_docs)]

/// One decoded data segment.
#[derive(Debug, Clone)]
pub struct DataSegment {
    pub active: bool,
    pub offset: i32,
    pub bytes: Vec<u8>,
}

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
    pub tags: Vec<Tag>,
    pub globals: Vec<Global>,
    pub tables: Vec<Table>,
    pub elements: Vec<Element>,
    pub data_count: Option<u32>,
    pub data_segments: Vec<DataSegment>,
}

pub const MAX_MODULE_BYTES: usize = 1 << 20;
pub const MAX_MEMORY_PAGES: u32 = 64;
pub const MAX_FUNCTIONS: usize = 1024;
pub const MAX_LOCALS: usize = 4096;
pub const MAX_STACK: usize = 256;
pub const MAX_CONTROL_DEPTH: usize = 64;
pub const MAX_INSTRUCTIONS: usize = 65_536;
const MAX_NAME_BYTES: usize = 256;

/// WebAssembly value type accepted by the parser. The interpreter/JIT still
/// executes only `I32`; other types are parsed and then fail closed at
/// validation/execution time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ValType {
    I32,
    I64,
    F32,
    F64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FuncType {
    pub params: Vec<ValType>,
    pub results: Vec<ValType>,
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

#[derive(Debug, Clone)]
pub struct Tag {
    pub typeidx: u32,
}

/// One `try_table` catch clause (wasm exception-handling). Labels are `br`
/// depths **not counting** the `try_table` itself (label 0 = parent block),
/// matching Binaryen `visitTryTable`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TryTableCatch {
    /// `catch $tag $label` — branch with the tag payload.
    Catch { tag: u32, label: u32 },
    /// `catch_ref $tag $label` — payload plus exnref (not executed here).
    CatchRef { tag: u32, label: u32 },
    /// `catch_all $label`.
    CatchAll { label: u32 },
    /// `catch_all_ref $label`.
    CatchAllRef { label: u32 },
}

#[derive(Debug, Clone)]
pub struct Global {
    pub valtype: ValType,
    pub mutable: bool,
    pub value: i64,
}

#[derive(Debug, Clone)]
pub struct Table {
    pub min: u32,
    pub max: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct Element {
    pub offset: i32,
    pub funcs: Vec<u32>,
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
    LocalTee(u32),
    GlobalGet(u32),
    GlobalSet(u32),
    I32Const(i32),
    I32Add,
    I32Sub,
    Unreachable,
    Block(Option<ValType>),
    Loop(Option<ValType>),
    If(Option<ValType>),
    Else,
    Br(u32),
    BrIf(u32),
    BrTable {
        labels: Vec<u32>,
        default: u32,
    },
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
    I32Load {
        align: u32,
        offset: u32,
    },
    I32Load8S {
        align: u32,
        offset: u32,
    },
    I32Load8U {
        align: u32,
        offset: u32,
    },
    I32Load16S {
        align: u32,
        offset: u32,
    },
    I32Load16U {
        align: u32,
        offset: u32,
    },
    I32Store {
        align: u32,
        offset: u32,
    },
    I32Store8 {
        align: u32,
        offset: u32,
    },
    I32Store16 {
        align: u32,
        offset: u32,
    },
    I64Const(i64),
    F32Const(u32),
    F64Const(u64),
    I64Load {
        align: u32,
        offset: u32,
    },
    I64Load8S {
        align: u32,
        offset: u32,
    },
    I64Load8U {
        align: u32,
        offset: u32,
    },
    I64Load16S {
        align: u32,
        offset: u32,
    },
    I64Load16U {
        align: u32,
        offset: u32,
    },
    I64Load32S {
        align: u32,
        offset: u32,
    },
    I64Load32U {
        align: u32,
        offset: u32,
    },
    F32Load {
        align: u32,
        offset: u32,
    },
    F64Load {
        align: u32,
        offset: u32,
    },
    I64Store {
        align: u32,
        offset: u32,
    },
    I64Store8 {
        align: u32,
        offset: u32,
    },
    I64Store16 {
        align: u32,
        offset: u32,
    },
    I64Store32 {
        align: u32,
        offset: u32,
    },
    F32Store {
        align: u32,
        offset: u32,
    },
    F64Store {
        align: u32,
        offset: u32,
    },
    /// Multi-type numeric op (i64/f32/f64 arithmetic or comparison). `op` is
    /// the raw WebAssembly opcode byte; a helper determines arity and result
    /// type at validate and run time.
    Numeric(u8),
    /// Multi-type conversion (`f32.convert_i32_u`, `i64.extend_i32_u`, etc.).
    Convert(u8),
    /// Nontrapping/saturating float-to-int truncation (`0xfc 0x00..0x07`).
    SaturatingTrunc(u8),
    /// Legacy exception handling: `throw $tag` pops the tag's payload values.
    Throw(u32),
    /// Legacy exception handling: `rethrow $label` rethrows the caught exception.
    Rethrow(u32),
    /// Legacy exception handling: `try` block (blocktype, then body).
    Try(Option<ValType>),
    /// Legacy exception handling: `catch $tag` begins a catch body.
    Catch(u32),
    /// Legacy exception handling: `catch_all` begins a catch-all body.
    CatchAll,
    /// Legacy exception handling: `delegate $label` ends a try by delegating.
    Delegate(u32),
    /// Exception handling: `try_table` (LDC 1.43). Catch dests are `br` labels.
    TryTable {
        result: Option<ValType>,
        catches: Vec<TryTableCatch>,
    },
    /// Exception handling: `throw_ref` (pops an exnref value).
    ThrowRef,
    /// Indirect call through a table: `call_indirect (type $idx) (table $idx)`.
    CallIndirect {
        typeidx: u32,
        tableidx: u32,
    },
    /// Bulk-memory / table opcodes (`0xfc` prefix).
    MemoryCopy,
    MemoryFill,
    MemoryInit(u32),
    DataDrop(u32),
    ElemDrop(u32),
    TableCopy {
        dst: u32,
        src: u32,
    },
    TableFill(u32),
    TableGet(u32),
    TableSet(u32),
    TableGrow(u32),
    TableSize(u32),
    TableInit {
        elem: u32,
        table: u32,
    },
    MemorySize,
    MemoryGrow,
    /// Parsed opcodes that are not yet executable by the bounded guest engine.
    /// The byte is the original opcode; any immediates are consumed during decode.
    Unsupported(u8),
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
            Self::I64Load { align, offset } | Self::I64Store { align, offset } => {
                Some((align, offset, 8))
            }
            Self::I64Load8S { align, offset }
            | Self::I64Load8U { align, offset }
            | Self::I64Store8 { align, offset } => Some((align, offset, 1)),
            Self::I64Load16S { align, offset }
            | Self::I64Load16U { align, offset }
            | Self::I64Store16 { align, offset } => Some((align, offset, 2)),
            Self::I64Load32S { align, offset }
            | Self::I64Load32U { align, offset }
            | Self::I64Store32 { align, offset } => Some((align, offset, 4)),
            Self::F32Load { align, offset } | Self::F32Store { align, offset } => {
                Some((align, offset, 4))
            }
            Self::F64Load { align, offset } | Self::F64Store { align, offset } => {
                Some((align, offset, 8))
            }
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
        tags: Vec::new(),
        globals: Vec::new(),
        tables: Vec::new(),
        elements: Vec::new(),
        data_count: None,
        data_segments: Vec::new(),
    };
    let mut i = 8usize;
    let mut seen = std::collections::BTreeSet::new();
    while i < bytes.len() {
        let id = bytes[i];
        i += 1;
        let (size, ni) = uleb(bytes, i)?;
        i = ni;
        let end = i
            .checked_add(size as usize)
            .ok_or("section size overflow")?;
        let payload = bytes.get(i..end).ok_or("truncated section")?;
        if id != 0 && !seen.insert(id) {
            return Err("duplicate section".into());
        }
        match id {
            0 => {
                name(payload, 0)?;
            }
            1 => decode_types(&mut m, payload)?,
            2 => decode_imports(&mut m, payload)?,
            3 => decode_funcs(&mut m, payload)?,
            4 => decode_tables(&mut m, payload)?,
            5 => decode_mem(&mut m, payload)?,
            6 => decode_globals(&mut m, payload)?,
            7 => decode_exports(&mut m, payload)?,
            9 => decode_elements(&mut m, payload)?,
            10 => decode_code(&mut m, payload)?,
            11 => decode_data(&mut m, payload)?,
            12 => decode_data_count(&mut m, payload)?,
            13 => decode_tags(&mut m, payload)?,
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

/// UI helper: `_start` is empty, so `__ui_dom` is not dirtied. Used to test
/// the GPU-surface `FbExpand1` fallback when the DOM has no visible rows.
pub fn encode_empty_ui_module() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    // type: ()->()
    let mut types = Vec::new();
    push_uleb(&mut types, 1);
    types.extend_from_slice(&[0x60, 0, 0]);
    section(&mut out, 1, &types);

    let mut funcs = Vec::new();
    push_uleb(&mut funcs, 1);
    push_uleb(&mut funcs, 0);
    section(&mut out, 3, &funcs);

    let mut memory = Vec::new();
    push_uleb(&mut memory, 1);
    memory.push(0x00);
    memory.push(0x01); // 1 page
    section(&mut out, 5, &memory);

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);

    let mut body = Vec::new();
    push_uleb(&mut body, 0); // locals
    body.push(0x0b); // end
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, body.len() as u32);
    code.extend_from_slice(&body);
    section(&mut out, 10, &code);
    out
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
        if ty.params.len() > 32 || ty.results.len() > 1 {
            return Err("unsupported function signature".into());
        }
    }
    for (idx, im) in m.imports.iter().enumerate() {
        let ty = func_type(m, idx as u32)?;
        if im.module != "env" {
            return Err(format!("unsupported import module {}", im.module));
        }
        // Most env imports are all-i32 and the exact name is not pre-checked
        // here; unhandled names fail closed at runtime in `invoke_import`
        // instead of during validation.  The libwasm ABI imports are the
        // documented exception: scalar box/unbox (B62) uses i64/f32/f64, and
        // the ldexec Lodash imports use i64/f64 (LIBWASM-ABI.md §2).
        let ldexec = im.name.starts_with("ldexec_");
        let libwasm = im.name.starts_with("libwasm_");
        let typed = ldexec || libwasm || im.name == "getTimeStamp";
        if ty.params.len() > if typed { 10 } else { 8 } || ty.results.len() > 1 {
            return Err("host import arity out of bounds".into());
        }
        let allowed = |t: &ValType| {
            *t == ValType::I32 || (typed && matches!(t, ValType::I64 | ValType::F32 | ValType::F64))
        };
        if !ty.params.iter().all(allowed) || !ty.results.iter().all(allowed) {
            return Err("host import value types must be i32".into());
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
            1 if (ex.idx as usize) < m.tables.len() => {}
            2 if ex.idx == 0 && m.has_memory => {}
            3 if (ex.idx as usize) < m.globals.len() => {}
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
        let locals = (ty.params.len())
            .checked_add(m.locals[idx] as usize)
            .ok_or("wasm locals overflow")?;
        if locals > MAX_LOCALS {
            return Err("wasm locals limit".into());
        }
        info.push(validate_body(m, body, locals, ty.results.len())?);
    }
    Ok(info)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum ControlKind {
    Function,
    Block,
    Loop,
    If,
    Try,
    TryTable,
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

pub(crate) fn numeric_is_unary(op: u8) -> bool {
    matches!(
        op,
        0x50 | 0x67..=0x69 | 0x79..=0x7b | 0x8b..=0x91 | 0x99..=0x9f | 0xc0..=0xc3
    )
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
        let controls_len = controls.len();
        let current = controls
            .last_mut()
            .ok_or("instructions after function end")?;
        match ins {
            Instr::Unsupported(op) => {
                return Err(format!("unsupported wasm opcode 0x{op:02x}"));
            }
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
            Instr::GlobalGet(idx) => {
                let _ = m.globals.get(*idx as usize).ok_or("bad global index")?;
                height += 1;
            }
            Instr::GlobalSet(idx) => {
                let g = m.globals.get(*idx as usize).ok_or("bad global index")?;
                if !g.mutable {
                    return Err("global.set on immutable global".into());
                }
                pop_type(&mut height, current)?;
            }
            Instr::Call(idx) => {
                let ty = func_type(m, *idx)?;
                for _ in 0..ty.params.len() {
                    pop_type(&mut height, current)?;
                }
                height += ty.results.len();
            }
            Instr::CallIndirect { typeidx, tableidx } => {
                if *tableidx as usize >= m.tables.len() {
                    return Err("bad table index".into());
                }
                let ty = m.types.get(*typeidx as usize).ok_or("bad type index")?;
                pop_type(&mut height, current)?; // table index
                for _ in 0..ty.params.len() {
                    pop_type(&mut height, current)?;
                }
                height += ty.results.len();
            }
            Instr::MemoryCopy | Instr::MemoryFill => {
                if !m.has_memory {
                    return Err("memory instruction without memory".into());
                }
                for _ in 0..3 {
                    pop_type(&mut height, current)?;
                }
            }
            Instr::MemoryInit(idx) => {
                if !m.has_memory {
                    return Err("memory instruction without memory".into());
                }
                let count = m.data_count.unwrap_or(m.data_segments.len() as u32);
                if *idx >= count {
                    return Err("bad data index".into());
                }
                for _ in 0..3 {
                    pop_type(&mut height, current)?;
                }
            }
            Instr::TableCopy { .. } | Instr::TableFill(_) => {
                for _ in 0..3 {
                    pop_type(&mut height, current)?;
                }
            }
            Instr::TableInit { elem, table } => {
                for _ in 0..3 {
                    pop_type(&mut height, current)?;
                }
                if *elem as usize >= m.elements.len() {
                    return Err("bad element index".into());
                }
                if *table as usize >= m.tables.len() {
                    return Err("bad table index".into());
                }
            }
            Instr::TableGet(table)
            | Instr::TableSet(table)
            | Instr::TableGrow(table)
            | Instr::TableSize(table) => {
                if *table as usize >= m.tables.len() {
                    return Err("bad table index".into());
                }
                match ins {
                    Instr::TableGet(_) => {
                        pop_type(&mut height, current)?;
                        height += 1;
                    }
                    Instr::TableSize(_) => height += 1,
                    Instr::TableSet(_) => {
                        pop_type(&mut height, current)?;
                        pop_type(&mut height, current)?;
                    }
                    Instr::TableGrow(_) => {
                        pop_type(&mut height, current)?;
                        pop_type(&mut height, current)?;
                        height += 1;
                    }
                    _ => unreachable!(),
                }
            }
            Instr::Block(result)
            | Instr::Loop(result)
            | Instr::If(result)
            | Instr::Try(result)
            | Instr::TryTable { result, .. } => {
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
                        Instr::Try(_) => ControlKind::Try,
                        Instr::TryTable { .. } => ControlKind::TryTable,
                        _ => ControlKind::Block,
                    },
                    start: pc,
                    height,
                    results: result.is_some() as usize,
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
            Instr::BrTable { labels, default } => {
                pop_type(&mut height, current)?;
                for &depth in labels.iter().chain(std::iter::once(default)) {
                    if depth as usize + 1 > controls_len {
                        return Err("bad branch depth".into());
                    }
                }
                height = current.height;
                current.unreachable = true;
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
            Instr::Throw(tag) => {
                if !current.unreachable {
                    let ty = m
                        .tags
                        .get(*tag as usize)
                        .and_then(|t| m.types.get(t.typeidx as usize))
                        .ok_or("bad tag index")?;
                    for _ in 0..ty.params.len() {
                        pop_type(&mut height, current)?;
                    }
                    current.unreachable = true;
                }
            }
            Instr::Rethrow(_) => {
                if !current.unreachable {
                    height = current.height;
                    current.unreachable = true;
                }
            }
            Instr::ThrowRef => {
                if !current.unreachable {
                    pop_type(&mut height, current)?;
                    current.unreachable = true;
                }
            }
            Instr::Catch(tag) => {
                if current.kind != ControlKind::Try {
                    return Err("catch outside try".into());
                }
                for _ in 0..current.results {
                    pop_type(&mut height, current)?;
                }
                if height != current.height {
                    return Err("try result stack mismatch at catch".into());
                }
                let ty = m
                    .tags
                    .get(*tag as usize)
                    .and_then(|t| m.types.get(t.typeidx as usize))
                    .ok_or("bad tag index")?;
                height = current.height + ty.params.len();
                current.alternative = Some(pc);
                info.alternatives[current.start] = Some(pc);
                current.unreachable = false;
            }
            Instr::CatchAll => {
                if current.kind != ControlKind::Try {
                    return Err("catch_all outside try".into());
                }
                for _ in 0..current.results {
                    pop_type(&mut height, current)?;
                }
                if height != current.height {
                    return Err("try result stack mismatch at catch_all".into());
                }
                height = current.height;
                current.alternative = Some(pc);
                info.alternatives[current.start] = Some(pc);
                current.unreachable = false;
            }
            Instr::Delegate(_) => {
                if current.kind != ControlKind::Try {
                    return Err("delegate outside try".into());
                }
                for _ in 0..current.results {
                    pop_type(&mut height, current)?;
                }
                if height != current.height {
                    return Err("try result stack mismatch at delegate".into());
                }
                let frame = controls.pop().ok_or("unmatched delegate")?;
                info.ends[frame.start] = pc;
                if let Some(alt) = frame.alternative {
                    info.ends[alt] = pc;
                }
                height += frame.results;
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
            Instr::DataDrop(idx) => {
                if *idx >= m.data_count.unwrap_or(0) {
                    return Err("bad data index".into());
                }
            }
            Instr::ElemDrop(idx) => {
                if *idx as usize >= m.elements.len() {
                    return Err("bad element index".into());
                }
            }
            Instr::I64Const(_) | Instr::F32Const(_) | Instr::F64Const(_) => height += 1,
            Instr::I64Load { .. }
            | Instr::I64Load8S { .. }
            | Instr::I64Load8U { .. }
            | Instr::I64Load16S { .. }
            | Instr::I64Load16U { .. }
            | Instr::I64Load32S { .. }
            | Instr::I64Load32U { .. }
            | Instr::F32Load { .. }
            | Instr::F64Load { .. }
            | Instr::I64Store { .. }
            | Instr::I64Store8 { .. }
            | Instr::I64Store16 { .. }
            | Instr::I64Store32 { .. }
            | Instr::F32Store { .. }
            | Instr::F64Store { .. } => {
                let (align, _, width) = ins.memory_access().ok_or("invalid memory instruction")?;
                if !m.has_memory || align > width.trailing_zeros() {
                    return Err("missing memory or invalid memory alignment".into());
                }
                pop_type(&mut height, current)?;
                if matches!(
                    ins,
                    Instr::I64Store { .. }
                        | Instr::I64Store8 { .. }
                        | Instr::I64Store16 { .. }
                        | Instr::I64Store32 { .. }
                        | Instr::F32Store { .. }
                        | Instr::F64Store { .. }
                ) {
                    pop_type(&mut height, current)?;
                } else {
                    height += 1;
                }
            }
            Instr::Numeric(op) => {
                if numeric_is_unary(*op) {
                    pop_type(&mut height, current)?;
                } else {
                    pop_type(&mut height, current)?;
                    pop_type(&mut height, current)?;
                }
                height += 1;
            }
            Instr::Convert(_) | Instr::SaturatingTrunc(_) => {
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
        let (params, ni) = value_types(p, ni, np)?;
        i = ni;
        let (nr, ni) = count(p, i, 1)?;
        let (results, ni) = value_types(p, ni, nr)?;
        i = ni;
        m.types.push(FuncType { params, results });
    }
    finish(p, i)
}

fn decode_valtype(b: u8) -> Result<ValType, String> {
    match b {
        0x7f => Ok(ValType::I32),
        0x7e => Ok(ValType::I64),
        0x7d => Ok(ValType::F32),
        0x7c => Ok(ValType::F64),
        _ => Err("unsupported wasm value type".into()),
    }
}

fn value_types(p: &[u8], i: usize, n: u32) -> Result<(Vec<ValType>, usize), String> {
    let end = i.checked_add(n as usize).ok_or("type count overflow")?;
    let bytes = p.get(i..end).ok_or("truncated value types")?;
    let mut types = Vec::with_capacity(n as usize);
    for &b in bytes {
        types.push(decode_valtype(b)?);
    }
    Ok((types, end))
}

fn count(p: &[u8], i: usize, max: usize) -> Result<(u32, usize), String> {
    let (n, i) = uleb(p, i)?;
    if n as usize > max {
        return Err(format!("wasm resource count limit: {n} > {max}"));
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
        match kind {
            0 => {
                let (ty, ni) = uleb(p, i)?;
                i = ni;
                m.imports.push(Import {
                    module: modn,
                    name: field,
                    typeidx: ty,
                });
            }
            3 => {
                // global import: valtype + mutability
                let vt = *p.get(i).ok_or("truncated global import value type")?;
                i += 1;
                let valtype = decode_valtype(vt)?;
                let mutable = *p.get(i).ok_or("truncated global import mutability")?;
                i += 1;
                if mutable > 1 {
                    return Err("invalid global import mutability".into());
                }
                m.globals.push(Global {
                    valtype,
                    mutable: mutable != 0,
                    value: 0,
                });
            }
            4 => {
                // tag import: attribute (must be 0) + type index
                let attr = *p.get(i).ok_or("truncated tag import attribute")?;
                i += 1;
                if attr != 0 {
                    return Err("unsupported tag import attribute".into());
                }
                let (ty, ni) = uleb(p, i)?;
                i = ni;
                m.tags.push(Tag { typeidx: ty });
            }
            _ => return Err(format!("unsupported import kind {kind}")),
        }
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

fn decode_tables(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, 1)?;
    for _ in 0..n {
        let kind = *p.get(i).ok_or("table kind")?;
        i += 1;
        if kind != 0x70 {
            return Err("only funcref tables supported".into());
        }
        let flags = *p.get(i).ok_or("table limits flags")?;
        i += 1;
        if flags > 1 {
            return Err("unsupported table limits flags".into());
        }
        let (min, ni) = count(p, i, MAX_FUNCTIONS)?;
        i = ni;
        let mut max = None;
        if flags == 1 {
            let (m, ni) = count(p, i, MAX_FUNCTIONS)?;
            i = ni;
            if m < min {
                return Err("table maximum below minimum".into());
            }
            max = Some(m);
        }
        m.tables.push(Table { min, max });
    }
    finish(p, i)
}

fn decode_globals(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, 256)?;
    for _ in 0..n {
        let vt = *p.get(i).ok_or("global type value type")?;
        i += 1;
        let valtype = decode_valtype(vt)?;
        let mutable = *p.get(i).ok_or("global type mutability")?;
        i += 1;
        if mutable > 1 {
            return Err("invalid global mutability".into());
        }
        let (val, ni) = decode_init_expr(p, i)?;
        i = ni;
        m.globals.push(Global {
            valtype,
            mutable: mutable != 0,
            value: val,
        });
    }
    finish(p, i)
}

fn decode_elements(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, MAX_FUNCTIONS)?;
    for _ in 0..n {
        let (flags, ni) = uleb(p, i)?;
        i = ni;
        if flags != 0 {
            return Err("only active MVP element segment (flags=0)".into());
        }
        // flags == 0 implies table 0 and an i32.const offset expression.
        let (offset, ni) = decode_init_expr(p, i)?;
        i = ni;
        let (count, ni) = count(p, i, MAX_FUNCTIONS)?;
        i = ni;
        let mut funcs = Vec::with_capacity(count as usize);
        for _ in 0..count {
            let (idx, ni) = uleb(p, i)?;
            i = ni;
            funcs.push(idx);
        }
        m.elements.push(Element {
            offset: offset as i32,
            funcs,
        });
    }
    finish(p, i)
}

fn decode_data_count(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, i) = count(p, 0, u32::MAX as usize)?;
    m.data_count = Some(n);
    finish(p, i)
}

/// Exception-handling tag section (id 13): vec of `{ 0x00, typeidx }`.
fn decode_tags(m: &mut Module, p: &[u8]) -> Result<(), String> {
    let (n, mut i) = count(p, 0, 256)?;
    for _ in 0..n {
        let attr = *p.get(i).ok_or("truncated tag attribute")?;
        i += 1;
        if attr != 0 {
            return Err("unsupported tag attribute".into());
        }
        let (ty, ni) = uleb(p, i)?;
        i = ni;
        m.tags.push(Tag { typeidx: ty });
    }
    finish(p, i)
}

fn decode_init_expr(p: &[u8], mut i: usize) -> Result<(i64, usize), String> {
    let opcode = *p.get(i).ok_or("truncated init expression")?;
    i += 1;
    let val = match opcode {
        0x41 => {
            let (v, ni) = ileb(p, i)?;
            i = ni;
            i64::from(v)
        }
        0x42 => {
            let (v, ni) = i64leb(p, i)?;
            i = ni;
            v
        }
        _ => return Err("init expression must be i32.const or i64.const".into()),
    };
    if p.get(i) != Some(&0x0b) {
        return Err("init expression must end with end".into());
    }
    i += 1;
    Ok((val, i))
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
    for fi in 0..n {
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
        let expr = body.get(j..).ok_or("truncated locals")?;
        let instrs = decode_expr(&m.types, expr).map_err(|e| format!("function {fi}: {e}"))?;
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
        match kind {
            0 => {
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
                let off_u = off as u32 as usize;
                let end = i.checked_add(len as usize).ok_or("data size overflow")?;
                let src = p.get(i..end).ok_or("data bytes")?;
                let mem_end = off_u.checked_add(src.len()).ok_or("data offset overflow")?;
                m.memory
                    .get_mut(off_u..mem_end)
                    .ok_or("data outside memory")?
                    .copy_from_slice(src);
                m.data_segments.push(DataSegment {
                    active: true,
                    offset: off,
                    bytes: src.to_vec(),
                });
                i = end;
            }
            1 => {
                let (len, ni) = uleb(p, i)?;
                i = ni;
                let end = i.checked_add(len as usize).ok_or("data size overflow")?;
                let src = p.get(i..end).ok_or("data bytes")?;
                m.data_segments.push(DataSegment {
                    active: false,
                    offset: 0,
                    bytes: src.to_vec(),
                });
                i = end;
            }
            _ => return Err("unsupported data segment kind".into()),
        }
    }
    finish(p, i)
}

fn decode_blocktype(
    types: &[FuncType],
    p: &[u8],
    i: &mut usize,
) -> Result<Option<ValType>, String> {
    let (bt, ni) = ileb(p, *i)?;
    *i = ni;
    match bt {
        -64 => Ok(None),
        -1 => Ok(Some(ValType::I32)),
        -2 => Ok(Some(ValType::I64)),
        -3 => Ok(Some(ValType::F32)),
        -4 => Ok(Some(ValType::F64)),
        idx if idx >= 0 => {
            let ty = types.get(idx as usize).ok_or("bad block type index")?;
            match ty.results.len() {
                0 => Ok(None),
                1 => Ok(Some(ty.results[0])),
                _ => Err("multi-value block type is not yet executable".into()),
            }
        }
        _ => Err("unsupported block type".into()),
    }
}

fn decode_expr(types: &[FuncType], p: &[u8]) -> Result<Vec<Instr>, String> {
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
                let result = decode_blocktype(types, p, &mut i)?;
                match op {
                    0x02 => Instr::Block(result),
                    0x03 => Instr::Loop(result),
                    _ => Instr::If(result),
                }
            }
            0x05 => Instr::Else,
            0x06 => {
                let bt = decode_blocktype(types, p, &mut i)?;
                Instr::Try(bt)
            }
            0x07 => {
                let (tag, ni) = uleb(p, i)?;
                i = ni;
                Instr::Catch(tag)
            }
            0x08 => {
                let (tag, ni) = uleb(p, i)?;
                i = ni;
                Instr::Throw(tag)
            }
            0x09 => {
                let (label, ni) = uleb(p, i)?;
                i = ni;
                Instr::Rethrow(label)
            }
            0x0a => Instr::ThrowRef,
            0x18 => {
                let (label, ni) = uleb(p, i)?;
                i = ni;
                Instr::Delegate(label)
            }
            0x19 => Instr::CatchAll,
            0x1f => {
                let bt = decode_blocktype(types, p, &mut i)?;
                let (count, ni) = uleb(p, i)?;
                i = ni;
                let mut catches = Vec::with_capacity(count as usize);
                for _ in 0..count {
                    let kind = *p.get(i).ok_or("truncated try_table catch")?;
                    i += 1;
                    let clause = match kind {
                        0 | 1 => {
                            let (tag, ni) = uleb(p, i)?;
                            i = ni;
                            let (label, ni) = uleb(p, i)?;
                            i = ni;
                            if kind == 0 {
                                TryTableCatch::Catch { tag, label }
                            } else {
                                TryTableCatch::CatchRef { tag, label }
                            }
                        }
                        2 | 3 => {
                            let (label, ni) = uleb(p, i)?;
                            i = ni;
                            if kind == 2 {
                                TryTableCatch::CatchAll { label }
                            } else {
                                TryTableCatch::CatchAllRef { label }
                            }
                        }
                        _ => return Err("bad try_table catch kind".into()),
                    };
                    catches.push(clause);
                }
                Instr::TryTable {
                    result: bt,
                    catches,
                }
            }
            0x0b => Instr::End,
            0x0c | 0x0d | 0x10 | 0x11 | 0x20..=0x24 => {
                let (idx, ni) = uleb(p, i)?;
                i = ni;
                match op {
                    0x0c => Instr::Br(idx),
                    0x0d => Instr::BrIf(idx),
                    0x10 => Instr::Call(idx),
                    0x11 => {
                        let (tableidx, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::CallIndirect {
                            typeidx: idx,
                            tableidx,
                        }
                    }
                    0x20 => Instr::LocalGet(idx),
                    0x21 => Instr::LocalSet(idx),
                    0x22 => Instr::LocalTee(idx),
                    0x23 => Instr::GlobalGet(idx),
                    _ => Instr::GlobalSet(idx),
                }
            }
            0x0e => {
                let (count, ni) = uleb(p, i)?;
                i = ni;
                let mut labels = Vec::with_capacity(count as usize);
                for _ in 0..count {
                    let (label, ni) = uleb(p, i)?;
                    i = ni;
                    labels.push(label);
                }
                let (default, ni) = uleb(p, i)?;
                i = ni;
                Instr::BrTable { labels, default }
            }
            0x0f => Instr::Return,
            0x1a => Instr::Drop,
            0x1b => Instr::Select,
            0x28..=0x3e => {
                let (align, ni) = uleb(p, i)?;
                let (offset, ni) = uleb(p, ni)?;
                i = ni;
                match op {
                    0x28 => Instr::I32Load { align, offset },
                    0x29 => Instr::I64Load { align, offset },
                    0x2a => Instr::F32Load { align, offset },
                    0x2b => Instr::F64Load { align, offset },
                    0x2c => Instr::I32Load8S { align, offset },
                    0x2d => Instr::I32Load8U { align, offset },
                    0x2e => Instr::I32Load16S { align, offset },
                    0x2f => Instr::I32Load16U { align, offset },
                    0x30 => Instr::I64Load8S { align, offset },
                    0x31 => Instr::I64Load8U { align, offset },
                    0x32 => Instr::I64Load16S { align, offset },
                    0x33 => Instr::I64Load16U { align, offset },
                    0x34 => Instr::I64Load32S { align, offset },
                    0x35 => Instr::I64Load32U { align, offset },
                    0x36 => Instr::I32Store { align, offset },
                    0x37 => Instr::I64Store { align, offset },
                    0x38 => Instr::F32Store { align, offset },
                    0x39 => Instr::F64Store { align, offset },
                    0x3a => Instr::I32Store8 { align, offset },
                    0x3b => Instr::I32Store16 { align, offset },
                    0x3c => Instr::I64Store8 { align, offset },
                    0x3d => Instr::I64Store16 { align, offset },
                    0x3e => Instr::I64Store32 { align, offset },
                    _ => unreachable!(),
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
            0x42 => {
                let (v, ni) = i64leb(p, i)?;
                i = ni;
                Instr::I64Const(v)
            }
            0x43 => {
                let b = p.get(i..i + 4).ok_or("truncated f32.const")?;
                i += 4;
                Instr::F32Const(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            }
            0x44 => {
                let b = p.get(i..i + 8).ok_or("truncated f64.const")?;
                i += 8;
                Instr::F64Const(u64::from_le_bytes([
                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                ]))
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
            0x50..=0x69 | 0x79..=0xa6 => Instr::Numeric(op),
            // 0xc0..=0xc4 are the sign-extension proposal (i32/i64.extend*_s).
            // LDC 1.43 emits them for D's byte/short casts, so they decode as
            // ordinary unary conversions.
            0xa7..=0xc4 => Instr::Convert(op),
            0xfc => {
                let (sub, ni) = uleb(p, i)?;
                i = ni;
                match sub {
                    0x0a => {
                        if p.get(i) != Some(&0) || p.get(i + 1) != Some(&0) {
                            return Err("memory.copy memory index must be zero".into());
                        }
                        i += 2;
                        Instr::MemoryCopy
                    }
                    0x0b => {
                        if p.get(i) != Some(&0) {
                            return Err("memory.fill memory index must be zero".into());
                        }
                        i += 1;
                        Instr::MemoryFill
                    }
                    0x08 => {
                        let (dataidx, ni) = uleb(p, i)?;
                        i = ni;
                        if p.get(i) != Some(&0) {
                            return Err("memory.init memory index must be zero".into());
                        }
                        i += 1;
                        Instr::MemoryInit(dataidx)
                    }
                    0x09 => {
                        let (dataidx, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::DataDrop(dataidx)
                    }
                    0x0c => {
                        let (elem, ni) = uleb(p, i)?;
                        i = ni;
                        let (table, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableInit { elem, table }
                    }
                    0x0d => {
                        let (elemidx, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::ElemDrop(elemidx)
                    }
                    0x0e => {
                        let (dst, ni) = uleb(p, i)?;
                        i = ni;
                        let (src, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableCopy { dst, src }
                    }
                    0x0f => {
                        let (table, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableFill(table)
                    }
                    0x10 => {
                        let (table, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableGet(table)
                    }
                    0x11 => {
                        let (table, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableSet(table)
                    }
                    0x12 => {
                        let (table, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableGrow(table)
                    }
                    0x13 => {
                        let (table, ni) = uleb(p, i)?;
                        i = ni;
                        Instr::TableSize(table)
                    }
                    0x00..=0x07 => Instr::SaturatingTrunc(sub as u8),
                    _ => {
                        skip_fc(sub, p, &mut i)?;
                        Instr::Unsupported(0xfc)
                    }
                }
            }
            other => {
                skip_opcode(other, p, &mut i)?;
                Instr::Unsupported(other)
            }
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

fn i64leb(p: &[u8], mut i: usize) -> Result<(i64, usize), String> {
    let mut r = 0i64;
    let mut sh = 0u32;
    loop {
        let b = *p.get(i).ok_or("i64leb")?;
        i += 1;
        if sh == 63 && (b & 0x80 != 0 || !matches!(b & 0x7f, 0 | 0x7f)) {
            return Err("i64leb overflow".into());
        }
        r |= i64::from(b & 0x7f) << sh;
        sh += 7;
        if b & 0x80 == 0 {
            if sh < 64 && (b & 0x40) != 0 {
                r |= -1i64 << sh;
            }
            return Ok((r, i));
        }
        if sh > 63 {
            return Err("i64leb overflow".into());
        }
    }
}

/// Skip the immediate bytes of an opcode that the bounded guest engine does not
/// yet execute, producing enough alignment information for `decode` to continue.
/// Control-flow opcodes that carry nested bodies (`0x02`–`0x04`, `0x06`, etc.)
/// are handled directly in `decode_expr`; this function returns an error for them
/// so `decode` stays well-aligned and fail-closed.
fn skip_opcode(op: u8, p: &[u8], i: &mut usize) -> Result<(), String> {
    match op {
        0x0e => {
            // br_table: vec(labelidx) + labelidx
            let (count, ni) = uleb(p, *i)?;
            *i = ni;
            for _ in 0..=count {
                let (_, ni) = uleb(p, *i)?;
                *i = ni;
            }
        }
        0x11 => {
            // call_indirect: typeidx + tableidx
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x12 | 0x14 | 0xd2 | 0xd5 | 0xd6 => {
            // return_call / call_ref / ref.func / br_on_null / br_on_non_null
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x13 => {
            // return_call_indirect: typeidx + tableidx
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x25 | 0x26 => {
            // table.get / table.set: tableidx
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x28..=0x3e => {
            // all load/store variants: align + offset
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x3f | 0x40 => {
            // memory.size / memory.grow: memidx (uleb)
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x42 => {
            // i64.const: signed LEB128
            let (_, ni) = i64leb(p, *i)?;
            *i = ni;
        }
        0x43 => {
            *i = i.checked_add(4).ok_or("truncated f32.const")?;
            p.get(*i - 4..*i).ok_or("truncated f32.const")?;
        }
        0x44 => {
            *i = i.checked_add(8).ok_or("truncated f64.const")?;
            p.get(*i - 8..*i).ok_or("truncated f64.const")?;
        }
        0x45..=0xc4 => {
            // one-byte numeric / comparison / conversion, including the
            // sign-extension proposal (i32/i64.extend8_s .. i64.extend32_s).
        }
        0xd0 => {
            // ref.null: reftype byte
            *i = i.checked_add(1).ok_or("truncated ref.null")?;
            p.get(*i - 1..*i).ok_or("truncated ref.null")?;
        }
        0xd1 | 0xd3 | 0xd4 => {
            // ref.is_null / ref.eq / ref.as_non_null: no immediates
        }
        0xfc => {
            let (sub, ni) = uleb(p, *i)?;
            *i = ni;
            skip_fc(sub, p, i)?;
        }
        0xfd => return Err("unsupported wasm opcode 0xfd (SIMD)".into()),
        0xc5..=0xcf | 0xd7..=0xdf | 0xe0..=0xeb | 0xfe..=0xff | 0x15 | 0x1c..=0x1e => {
            return Err(format!("unsupported wasm opcode {op:#x}"));
        }
        _ => return Err(format!("unsupported wasm opcode {op:#x}")),
    }
    Ok(())
}

fn skip_fc(sub: u32, p: &[u8], i: &mut usize) -> Result<(), String> {
    match sub {
        0x00..=0x07 => {
            // nontrapping float-to-int conversions: no further immediates
        }
        0x08 | 0x0c | 0x0e | 0x0a => {
            // two u32 immediates (data/elem/table/mem indexes)
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x09 | 0x0d | 0x0f | 0x10 | 0x11 | 0x12 => {
            // one u32 immediate
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        0x0b => {
            // memory.fill: memidx
            let (_, ni) = uleb(p, *i)?;
            *i = ni;
        }
        _ => return Err(format!("unsupported wasm sub-opcode 0xfc {sub:#x}")),
    }
    Ok(())
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
            &[0x06, 0x40, 0x0b, 0x0b],
            &[0xfc, 10, 0, 0, 0x0b],
        ] {
            assert!(
                decode(&numeric_with_memory(0, 1, 0, ops, Some((1, None)))).is_err(),
                "{ops:?}"
            );
        }
        // i64.load is now a parse-only, height-validated instruction.
        assert!(decode(&numeric_with_memory(
            0,
            1,
            0,
            &[0x41, 0, 0x29, 3, 0, 0x0b],
            Some((1, None))
        ))
        .is_ok());
        for ops in [&[0x3f, 0, 0x0b][..], &[0x41, 0, 0x40, 0, 0x0b]] {
            assert!(decode(&numeric(0, 1, 0, ops)).is_err());
            assert!(decode(&numeric_with_memory(0, 1, 0, ops, Some((0, Some(0))))).is_ok());
        }
        for (min, max, valid) in [
            (0, Some(0), true),
            (1, Some(0), false),
            (1, Some(65536), true),
            (1, Some(65537), false),
            (65, None, false),
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
        let m = decode(&wrong_type).unwrap();
        assert_eq!(
            crate::run(&m, 0, &[0], &mut crate::interp::tests::TestHost::default()).unwrap_err(),
            "non-i32 function type is not yet executable"
        );
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
        section(&mut bytes, 14, &[0]);
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
        for memory in [&[1, 0, 65][..], &[1, 3, 1], &[2, 0, 1, 0, 1], &[1, 1, 2, 1]] {
            let mut bytes = b"\0asm\x01\x00\x00\x00".to_vec();
            section(&mut bytes, 5, memory);
            assert!(decode(&bytes).is_err());
        }
        assert!(decode(&numeric(0, 0, MAX_LOCALS as u32 + 1, &[0x0b])).is_err());
        assert!(decode(&numeric(32, 0, MAX_LOCALS as u32 - 31, &[0x0b])).is_err());
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

    #[test]
    fn libwasm_artifact_decodes_and_runs_start_under_default_fuel() {
        // Only meaningful when the optional LDC/libwasm cell has been built.
        if !crate::bios_ui_libwasm_live() {
            return;
        }
        let bytes = crate::bios_ui_libwasm();
        // The real asyncified libwasm module is now structurally decodable and
        // the bounded interpreter executes its _start export end-to-end against
        // a no-op host (the DOM/HTTP/await imports are stubbed).
        let m = decode(bytes).expect("libwasm artifact should decode structurally");
        let start = m
            .exports
            .iter()
            .find(|e| e.kind == 0 && e.name == "_start")
            .map(|e| e.idx)
            .expect("_start export");
        let result = crate::run(
            &m,
            start,
            &[0],
            &mut crate::interp::tests::TestHost::default(),
        );
        match result {
            Ok(vals) => {
                assert!(
                    vals.is_empty(),
                    "_start should return no values, got {vals:?}"
                )
            }
            Err(err) => panic!("unexpected libwasm run error: {err}"),
        }
    }

    #[test]
    fn libwasm_cell_start_asyncify_await_then_eh_catch() {
        if !crate::bios_ui_libwasm_live() {
            return;
        }
        let m = decode(crate::bios_ui_libwasm()).expect("decode LDC cell");
        assert!(
            m.exports.iter().any(|e| e.name == "asyncify_get_state"),
            "svelte-engine wasm-opt --asyncify left control exports"
        );
        assert!(
            !m.tags.is_empty(),
            "env.__cpp_exception tag import for App.ready catch"
        );
        // Empty JSON arrays: parseJSON succeeds so rewind is the happy path
        // (KernelHost serves real /bios/menu JSON). Do not strip asyncify_*.
        let mut host = crate::interp::tests::TestHost {
            fetch_body: Some("[]".into()),
            ..Default::default()
        };
        crate::run_start(&m, &mut host).expect("LDC _start asyncify rewind + App.ready catch");
    }

    #[test]
    fn libwasm_cell_start_catch_swallows_bad_json_after_rewind() {
        if !crate::bios_ui_libwasm_live() {
            return;
        }
        let m = decode(crate::bios_ui_libwasm()).expect("decode LDC cell");
        // Default TestHost fetch returns the URL, not JSON. Flatten deleted
        // ready()'s catch around await; abort-stub unreachable becomes wasm-eh
        // throw and `_start` fail-softs after rewind (empty catch intent).
        let mut host = crate::interp::tests::TestHost::default();
        crate::run_start(&m, &mut host)
            .expect("per-await try around parseJSON swallows a non-JSON fetch body");
    }
}
