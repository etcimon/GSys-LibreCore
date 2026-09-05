// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host interpreter — the BIOS UI “JIT”.

#![allow(missing_docs)]

use crate::binary::{analyze, func_type, BodyInfo, Instr, Module, MAX_MEMORY_PAGES};
use crate::{
    IMPORT_FETCH, IMPORT_LOG, IMPORT_OBJECT_CALL, IMPORT_SET_INNER_TEXT, IMPORT_SET_VISIBLE,
};
use g6b_dom::Node;

/// Host imports (libwasm-shaped subset).
pub trait Host {
    fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String>;
    fn log(&mut self, msg: &str);
    fn set_visible(&mut self, id: &str, on: bool) -> Result<(), String>;
    /// Kernel HTTP proxy (libwasm fetch). Default paints nothing.
    fn fetch(&mut self, url: &str) -> Result<String, String> {
        let _ = url;
        Ok(String::new())
    }
}

/// DOM host used by the BIOS browser.
pub struct DomHost<'a> {
    pub dom: &'a mut Node,
}

impl Host for DomHost<'_> {
    fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String> {
        let n = self
            .dom
            .get_element_by_id(id)
            .ok_or_else(|| format!("no element id={id}"))?;
        n.set_inner_text(val);
        Ok(())
    }

    fn log(&mut self, _msg: &str) {}

    fn set_visible(&mut self, id: &str, on: bool) -> Result<(), String> {
        let n = self
            .dom
            .get_element_by_id(id)
            .ok_or_else(|| format!("no element id={id}"))?;
        n.set_visible(on);
        Ok(())
    }
}

/// Run exported `_start` (svelte-d / libwasm Spa boot).
pub fn run_start(m: &Module, host: &mut impl Host) -> Result<(), String> {
    let idx = m
        .exports
        .iter()
        .find(|e| e.name == "_start" && e.kind == 0)
        .map(|e| e.idx)
        .ok_or("no _start export")?;
    let ty = func_type(m, idx)?;
    if ty.params != 0 || ty.results != 0 {
        return Err("_start must have signature () -> ()".into());
    }
    run(m, idx, &[], host).map(|_| ())
}

/// Run function `idx` (import space first).
pub fn run(m: &Module, idx: u32, args: &[i32], host: &mut impl Host) -> Result<Vec<i32>, String> {
    run_with_fuel(m, idx, args, host, DEFAULT_FUEL)
}

pub const DEFAULT_FUEL: u64 = 100_000;
pub const MAX_FUEL: u64 = 1_000_000;
pub const MAX_CALL_DEPTH: usize = 64;

pub fn run_with_fuel(
    m: &Module,
    idx: u32,
    args: &[i32],
    host: &mut impl Host,
    fuel: u64,
) -> Result<Vec<i32>, String> {
    if fuel > MAX_FUEL {
        return Err("wasm fuel limit exceeds maximum".into());
    }
    let info = analyze(m)?;
    let mut memory = Vec::new();
    memory
        .try_reserve_exact(m.memory.len())
        .map_err(|_| "wasm memory allocation failed")?;
    memory.extend_from_slice(&m.memory);
    Runtime {
        m,
        info,
        host,
        fuel,
        memory,
    }
    .invoke(idx, args, 0)
}

struct Runtime<'a, H> {
    m: &'a Module,
    info: Vec<BodyInfo>,
    host: &'a mut H,
    fuel: u64,
    memory: Vec<u8>,
}

#[derive(Clone, Copy)]
struct Frame {
    height: usize,
    results: usize,
    start: usize,
    end: usize,
    is_loop: bool,
}

fn pop(stack: &mut Vec<i32>) -> Result<i32, String> {
    stack
        .pop()
        .ok_or_else(|| "wasm operand stack underflow".into())
}

fn preserve(stack: &mut Vec<i32>, height: usize, results: usize) -> Result<(), String> {
    let result = if results == 1 {
        Some(pop(stack)?)
    } else {
        None
    };
    if stack.len() < height {
        return Err("wasm control stack underflow".into());
    }
    stack.truncate(height);
    stack.extend(result);
    Ok(())
}

impl<H: Host> Runtime<'_, H> {
    fn grow_memory(&mut self, delta: u32) -> i32 {
        let old = (self.memory.len() / 65536) as u32;
        let limit = self
            .m
            .max_mem_pages
            .unwrap_or(MAX_MEMORY_PAGES)
            .min(MAX_MEMORY_PAGES);
        let Some(pages) = old.checked_add(delta).filter(|pages| *pages <= limit) else {
            return -1;
        };
        let len = pages as usize * 65536;
        if self
            .memory
            .try_reserve_exact(len - self.memory.len())
            .is_err()
        {
            return -1;
        }
        self.memory.resize(len, 0);
        old as i32
    }

    fn tick(&mut self) -> Result<(), String> {
        self.fuel = self.fuel.checked_sub(1).ok_or("wasm fuel exhausted")?;
        Ok(())
    }

    fn invoke(&mut self, idx: u32, args: &[i32], depth: usize) -> Result<Vec<i32>, String> {
        if depth >= MAX_CALL_DEPTH {
            return Err("wasm call depth limit".into());
        }
        self.tick()?;
        let ty = func_type(self.m, idx)?;
        if args.len() != ty.params as usize {
            return Err("wasm argument count mismatch".into());
        }
        let results = ty.results as usize;
        if (idx as usize) < self.m.imports.len() {
            return call_import(self.m, &self.memory, idx, args, self.host);
        }
        let local = idx as usize - self.m.imports.len();
        let mut locals = args.to_vec();
        locals.resize(args.len() + self.m.locals[local] as usize, 0);
        let body = &self.m.bodies[local];
        let mut stack = Vec::with_capacity(self.info[local].max_stack);
        let mut controls = vec![Frame {
            height: 0,
            results,
            start: 0,
            end: body.len() - 1,
            is_loop: false,
        }];
        let mut pc = 0;
        while pc < body.len() {
            self.tick()?;
            let ins = &body[pc];
            match ins {
                Instr::Nop => {}
                Instr::Unreachable => return Err("wasm unreachable trap".into()),
                Instr::I32Const(v) => stack.push(*v),
                Instr::LocalGet(i) => stack.push(locals[*i as usize]),
                Instr::LocalSet(i) | Instr::LocalTee(i) => {
                    let value = pop(&mut stack)?;
                    locals[*i as usize] = value;
                    if matches!(ins, Instr::LocalTee(_)) {
                        stack.push(value);
                    }
                }
                Instr::I32Load { .. }
                | Instr::I32Load8S { .. }
                | Instr::I32Load8U { .. }
                | Instr::I32Load16S { .. }
                | Instr::I32Load16U { .. } => {
                    let address = pop(&mut stack)?;
                    let (_, offset, width) =
                        ins.memory_access().ok_or("invalid memory instruction")?;
                    let range = memory_range(self.memory.len(), address, offset, width)?;
                    let bytes = &self.memory[range];
                    let value = match ins {
                        Instr::I32Load8S { .. } => i32::from(bytes[0] as i8),
                        Instr::I32Load8U { .. } => i32::from(bytes[0]),
                        Instr::I32Load16S { .. } => {
                            i32::from(i16::from_le_bytes([bytes[0], bytes[1]]))
                        }
                        Instr::I32Load16U { .. } => {
                            i32::from(u16::from_le_bytes([bytes[0], bytes[1]]))
                        }
                        _ => i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]),
                    };
                    stack.push(value);
                }
                Instr::I32Store { .. } | Instr::I32Store8 { .. } | Instr::I32Store16 { .. } => {
                    let value = pop(&mut stack)?;
                    let address = pop(&mut stack)?;
                    let (_, offset, width) =
                        ins.memory_access().ok_or("invalid memory instruction")?;
                    let range = memory_range(self.memory.len(), address, offset, width)?;
                    self.memory[range].copy_from_slice(&value.to_le_bytes()[..width]);
                }
                Instr::MemorySize => stack.push((self.memory.len() / 65536) as i32),
                Instr::MemoryGrow => {
                    let delta = pop(&mut stack)? as u32;
                    stack.push(self.grow_memory(delta));
                }
                Instr::Drop => {
                    pop(&mut stack)?;
                }
                Instr::Select => {
                    let condition = pop(&mut stack)?;
                    let b = pop(&mut stack)?;
                    let a = pop(&mut stack)?;
                    stack.push(if condition != 0 { a } else { b });
                }
                Instr::I32Eqz => {
                    let a = pop(&mut stack)?;
                    stack.push(i32::from(a == 0));
                }
                Instr::Call(callee) => {
                    let count = func_type(self.m, *callee)?.params as usize;
                    let base = stack
                        .len()
                        .checked_sub(count)
                        .ok_or("call argument underflow")?;
                    let args = stack.split_off(base);
                    stack.extend(self.invoke(*callee, &args, depth + 1)?);
                }
                Instr::Block(result) | Instr::Loop(result) | Instr::If(result) => {
                    let condition = if matches!(ins, Instr::If(_)) {
                        pop(&mut stack)?
                    } else {
                        1
                    };
                    controls.push(Frame {
                        height: stack.len(),
                        results: usize::from(*result),
                        start: pc + 1,
                        end: self.info[local].ends[pc],
                        is_loop: matches!(ins, Instr::Loop(_)),
                    });
                    if condition == 0 {
                        pc = self.info[local].alternatives[pc]
                            .map_or(self.info[local].ends[pc], |alt| alt + 1);
                        continue;
                    }
                }
                Instr::Else => {
                    pc = self.info[local].ends[pc];
                    continue;
                }
                Instr::End => {
                    let frame = controls.pop().ok_or("unmatched runtime end")?;
                    preserve(&mut stack, frame.height, frame.results)?;
                    if controls.is_empty() {
                        return Ok(stack);
                    }
                }
                Instr::Return => {
                    preserve(&mut stack, 0, results)?;
                    return Ok(stack);
                }
                Instr::Br(label) | Instr::BrIf(label) => {
                    let taken = !matches!(ins, Instr::BrIf(_)) || pop(&mut stack)? != 0;
                    if taken {
                        let target = controls.len() - *label as usize - 1;
                        let frame = controls[target];
                        preserve(
                            &mut stack,
                            frame.height,
                            if frame.is_loop { 0 } else { frame.results },
                        )?;
                        controls.truncate(target + usize::from(frame.is_loop));
                        if controls.is_empty() {
                            return Ok(stack);
                        }
                        pc = if frame.is_loop {
                            frame.start
                        } else {
                            frame.end + 1
                        };
                        continue;
                    }
                }
                other => {
                    let b = pop(&mut stack)?;
                    let a = pop(&mut stack)?;
                    stack.push(binary_op(other, a, b)?);
                }
            }
            pc += 1;
        }
        Err("missing runtime function end".into())
    }
}

fn binary_op(ins: &Instr, a: i32, b: i32) -> Result<i32, String> {
    Ok(match ins {
        Instr::I32Add => a.wrapping_add(b),
        Instr::I32Sub => a.wrapping_sub(b),
        Instr::I32Mul => a.wrapping_mul(b),
        Instr::I32DivS => a.checked_div(b).ok_or("wasm integer division trap")?,
        Instr::I32DivU => (a as u32)
            .checked_div(b as u32)
            .ok_or("wasm integer division trap")? as i32,
        Instr::I32RemS => {
            if b == 0 {
                return Err("wasm integer remainder trap".into());
            }
            a.wrapping_rem(b)
        }
        Instr::I32RemU => (a as u32)
            .checked_rem(b as u32)
            .ok_or("wasm integer remainder trap")? as i32,
        Instr::I32And => a & b,
        Instr::I32Or => a | b,
        Instr::I32Xor => a ^ b,
        Instr::I32Shl => a.wrapping_shl(b as u32),
        Instr::I32ShrS => a.wrapping_shr(b as u32),
        Instr::I32ShrU => (a as u32).wrapping_shr(b as u32) as i32,
        Instr::I32Rotl => a.rotate_left(b as u32),
        Instr::I32Rotr => a.rotate_right(b as u32),
        Instr::I32Eq => i32::from(a == b),
        Instr::I32Ne => i32::from(a != b),
        Instr::I32LtS => i32::from(a < b),
        Instr::I32LtU => i32::from((a as u32) < b as u32),
        Instr::I32GtS => i32::from(a > b),
        Instr::I32GtU => i32::from((a as u32) > b as u32),
        Instr::I32LeS => i32::from(a <= b),
        Instr::I32LeU => i32::from((a as u32) <= b as u32),
        Instr::I32GeS => i32::from(a >= b),
        Instr::I32GeU => i32::from((a as u32) >= b as u32),
        _ => return Err("unsupported numeric operation".into()),
    })
}

fn call_import(
    m: &Module,
    memory: &[u8],
    idx: u32,
    args: &[i32],
    host: &mut impl Host,
) -> Result<Vec<i32>, String> {
    let im = m.imports.get(idx as usize).ok_or("import")?;
    if im.module != "env" {
        return Err(format!("unknown import module {}", im.module));
    }
    match (im.name.as_str(), args) {
        (IMPORT_SET_INNER_TEXT, [id_ptr, id_len, val_ptr, val_len]) => {
            let id = mem_str(memory, *id_ptr, *id_len)?;
            let val = mem_str(memory, *val_ptr, *val_len)?;
            host.set_inner_text(&id, &val)?;
        }
        (IMPORT_LOG, [ptr, len]) => host.log(&mem_str(memory, *ptr, *len)?),
        (IMPORT_SET_VISIBLE, [ptr, len, on]) => {
            host.set_visible(&mem_str(memory, *ptr, *len)?, *on != 0)?;
        }
        (IMPORT_FETCH | IMPORT_OBJECT_CALL, [ptr, len]) => {
            let _body = host.fetch(&mem_str(memory, *ptr, *len)?)?;
        }
        _ => return Err("unknown host import or argument mismatch".into()),
    }
    Ok(Vec::new())
}

fn memory_range(
    len: usize,
    address: i32,
    offset: u32,
    width: usize,
) -> Result<std::ops::Range<usize>, String> {
    let start = u64::from(address as u32) + u64::from(offset);
    let end = start
        .checked_add(width as u64)
        .ok_or("wasm memory address overflow")?;
    if end > len as u64 {
        return Err("wasm memory out of bounds".into());
    }
    Ok(start as usize..end as usize)
}

fn mem_str(memory: &[u8], ptr: i32, len: i32) -> Result<String, String> {
    let range = memory_range(memory.len(), ptr, 0, len as u32 as usize)?;
    String::from_utf8(memory[range].to_vec()).map_err(|_| "wasm string is not UTF-8".into())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::binary::tests::{numeric, numeric_with_memory};
    use crate::{decode, encode_ui_module};

    #[derive(Default)]
    pub(crate) struct TestHost(pub usize);
    impl Host for TestHost {
        fn set_inner_text(&mut self, _: &str, _: &str) -> Result<(), String> {
            self.0 += 1;
            Ok(())
        }
        fn set_visible(&mut self, _: &str, _: bool) -> Result<(), String> {
            self.0 += 1;
            Ok(())
        }
        fn log(&mut self, _: &str) {
            self.0 += 1;
        }
    }

    fn eval(params: u32, locals: u32, ops: &[u8], args: &[i32]) -> Result<Vec<i32>, String> {
        let m = decode(&numeric(params, 1, locals, ops))?;
        run(&m, 0, args, &mut TestHost::default())
    }

    fn memory_eval(
        ops: &[u8],
        args: &[i32],
        min: u32,
        max: Option<u32>,
    ) -> Result<Vec<i32>, String> {
        let bytes = numeric_with_memory(args.len() as u32, 1, 1, ops, Some((min, max)));
        run(&decode(&bytes)?, 0, args, &mut TestHost::default())
    }

    #[test]
    fn memory_loads_stores_are_little_endian_unaligned_and_width_exact() {
        for (store, load, expected) in [
            (0x36, 0x28, 0x80ff_81feu32 as i32),
            (0x36, 0x2c, -2),
            (0x36, 0x2d, 254),
            (0x36, 0x2e, -32258),
            (0x36, 0x2f, 33278),
            (0x3a, 0x28, 254),
            (0x3b, 0x28, 33278),
        ] {
            let ops = [0x20, 0, 0x20, 1, store, 0, 2, 0x20, 0, load, 0, 2, 0x0b];
            assert_eq!(
                memory_eval(&ops, &[1, 0x80ff_81feu32 as i32], 1, None).unwrap(),
                [expected]
            );
        }
        for load in [0x28, 0x2c, 0x2d, 0x2e, 0x2f] {
            assert_eq!(
                memory_eval(&[0x41, 0, load, 0, 0, 0x0b], &[], 1, None).unwrap(),
                [0]
            );
        }
        assert_eq!(
            memory_eval(
                &[0x20, 0, 0x41, 0x7f, 0x3a, 0, 0, 0x20, 0, 0x2d, 0, 0, 0x0b],
                &[65535],
                1,
                None
            )
            .unwrap(),
            [255]
        );
    }

    #[test]
    fn memory_out_of_bounds_does_not_wrap_or_partially_store() {
        for (op, width) in [
            (0x28, 4),
            (0x2c, 1),
            (0x2d, 1),
            (0x2e, 2),
            (0x2f, 2),
            (0x36, 4),
            (0x3a, 1),
            (0x3b, 2),
        ] {
            let store = matches!(op, 0x36 | 0x3a | 0x3b);
            for (address, offset) in [(65537 - width, 0), (-1, 1), (1, u32::MAX), (i32::MIN, 0)] {
                let ins = match op {
                    0x28 => Instr::I32Load { align: 0, offset },
                    0x2c => Instr::I32Load8S { align: 0, offset },
                    0x2d => Instr::I32Load8U { align: 0, offset },
                    0x2e => Instr::I32Load16S { align: 0, offset },
                    0x2f => Instr::I32Load16U { align: 0, offset },
                    0x36 => Instr::I32Store { align: 0, offset },
                    0x3a => Instr::I32Store8 { align: 0, offset },
                    _ => Instr::I32Store16 { align: 0, offset },
                };
                let mut m =
                    decode(&numeric_with_memory(0, 0, 0, &[0x0b], Some((1, None)))).unwrap();
                m.memory.fill(0x55);
                m.bodies[0] = vec![Instr::I32Const(address)];
                if store {
                    m.bodies[0].push(Instr::I32Const(-1));
                }
                m.bodies[0].push(ins);
                if !store {
                    m.bodies[0].push(Instr::Drop);
                }
                m.bodies[0].push(Instr::End);
                let mut runtime = Runtime {
                    m: &m,
                    info: analyze(&m).unwrap(),
                    memory: m.memory.clone(),
                    host: &mut TestHost::default(),
                    fuel: DEFAULT_FUEL,
                };
                assert!(runtime
                    .invoke(0, &[], 0)
                    .unwrap_err()
                    .contains("out of bounds"));
                assert_eq!(runtime.memory, m.memory);
            }
        }
        assert!(memory_eval(&[0x41, 0, 0x2d, 0, 0, 0x0b], &[], 0, None).is_err());
    }

    #[test]
    fn memory_growth_respects_declared_max_global_cap_and_unsigned_delta() {
        let ops = [0x20, 0, 0x40, 0, 0x0b];
        for (min, max, delta, expected) in [
            (0, Some(0), 0, 0),
            (0, Some(0), 1, -1),
            (1, Some(2), 0, 1),
            (1, Some(2), 1, 1),
            (1, Some(2), 2, -1),
            (1, None, 15, 1),
            (1, None, 16, -1),
            (1, Some(65536), 16, -1),
            (16, None, 0, 16),
            (16, None, 1, -1),
            (1, None, -1, -1),
            (1, None, i32::MIN, -1),
        ] {
            assert_eq!(memory_eval(&ops, &[delta], min, max).unwrap(), [expected]);
        }
        let size = [0x20, 0, 0x40, 0, 0x1a, 0x3f, 0, 0x0b];
        assert_eq!(memory_eval(&size, &[1], 1, Some(2)).unwrap(), [2]);
        assert_eq!(memory_eval(&size, &[2], 1, Some(2)).unwrap(), [1]);
        let mut m = decode(&numeric_with_memory(
            0,
            1,
            0,
            &[0x3f, 0, 0x0b],
            Some((1, Some(2))),
        ))
        .unwrap();
        m.memory[0] = 42;
        m.bodies[0] = vec![
            Instr::I32Const(1),
            Instr::MemoryGrow,
            Instr::Drop,
            Instr::I32Const(65536),
            Instr::I32Load {
                align: 2,
                offset: 0,
            },
            Instr::End,
        ];
        let mut host = TestHost::default();
        let mut runtime = Runtime {
            m: &m,
            info: analyze(&m).unwrap(),
            memory: m.memory.clone(),
            host: &mut host,
            fuel: DEFAULT_FUEL,
        };
        assert_eq!(runtime.invoke(0, &[], 0).unwrap(), [0]);
        assert_eq!(runtime.memory[0], 42);
        assert!(runtime.memory[65536..].iter().all(|b| *b == 0));
        let before = runtime.memory.clone();
        assert_eq!(runtime.grow_memory(u32::MAX), -1);
        assert_eq!(runtime.memory, before);
        assert_eq!(m.memory.len(), 65536);
    }

    #[test]
    fn calls_and_host_imports_share_memory_but_runs_are_isolated() {
        let mut m = decode(&encode_ui_module("status", "hello")).unwrap();
        m.bodies.push(vec![
            Instr::I32Const(32),
            Instr::I32Const(i32::from(b'j')),
            Instr::I32Store8 {
                align: 0,
                offset: 0,
            },
            Instr::End,
        ]);
        m.locals.push(0);
        m.func_types.push(1);
        m.bodies[0].insert(0, Instr::Call(2));
        let mut root = Node::elem("div");
        root.id = Some("status".into());
        run_start(&m, &mut DomHost { dom: &mut root }).unwrap();
        assert_eq!(root.inner_text(), "jello");
        assert_eq!(&m.memory[32..37], b"hello");
        m.bodies[0].remove(0);
        run_start(&m, &mut DomHost { dom: &mut root }).unwrap();
        assert_eq!(root.inner_text(), "hello");
        let bytes = numeric_with_memory(
            0,
            1,
            1,
            &[
                0x41, 0, 0x28, 2, 0, 0x21, 0, 0x41, 0, 0x41, 7, 0x36, 2, 0, 0x20, 0, 0x0b,
            ],
            Some((1, None)),
        );
        let m = decode(&bytes).unwrap();
        for _ in 0..3 {
            assert_eq!(run(&m, 0, &[], &mut TestHost::default()).unwrap(), [0]);
        }
        let mut m = decode(&numeric_with_memory(
            0,
            1,
            0,
            &[0x3f, 0, 0x0b],
            Some((1, Some(2))),
        ))
        .unwrap();
        m.bodies[0] = vec![Instr::Call(1), Instr::Drop, Instr::MemorySize, Instr::End];
        m.bodies
            .push(vec![Instr::I32Const(1), Instr::MemoryGrow, Instr::End]);
        m.func_types.push(0);
        m.locals.push(0);
        for _ in 0..3 {
            assert_eq!(run(&m, 0, &[], &mut TestHost::default()).unwrap(), [2]);
        }
    }

    #[test]
    #[ignore = "requires Node.js native WebAssembly"]
    fn memory_semantics_match_native_webassembly() {
        use std::fmt::Write;
        let mut cases = Vec::new();
        for store in [0x36, 0x3a, 0x3b] {
            for load in [0x28, 0x2c, 0x2d, 0x2e, 0x2f] {
                let ops = [0x20, 0, 0x20, 1, store, 0, 1, 0x20, 0, load, 0, 1, 0x0b];
                let bytes = numeric_with_memory(2, 1, 0, &ops, Some((1, Some(2))));
                for address in [0, 2, 65532, 65535, -1] {
                    cases.push((bytes.clone(), vec![address, 0x80ff_81feu32 as i32]));
                }
            }
        }
        for (min, max) in [(0, 0), (0, 2), (1, 2)] {
            for ops in [
                &[0x20, 0, 0x40, 0, 0x0b][..],
                &[0x20, 0, 0x40, 0, 0x1a, 0x3f, 0, 0x0b],
            ] {
                for delta in [0, 1, 2, -1, i32::MIN] {
                    cases.push((
                        numeric_with_memory(1, 1, 0, ops, Some((min, Some(max)))),
                        vec![delta],
                    ));
                }
            }
        }
        let mut source = String::from("const cases=[");
        let mut expected = Vec::new();
        for (bytes, args) in &cases {
            write!(source, "{{bytes:{bytes:?},args:{args:?}}},").unwrap();
            let m = decode(bytes).unwrap();
            expected.push(match run(&m, 0, args, &mut TestHost::default()) {
                Ok(v) => v[0].to_string(),
                Err(_) => "trap".into(),
            });
        }
        source.push_str("];for(const c of cases){const m=new WebAssembly.Module(Uint8Array.from(c.bytes));const i=new WebAssembly.Instance(m);try{console.log(i.exports.main(...c.args))}catch(e){if(!(e instanceof WebAssembly.RuntimeError))throw e;console.log('trap')}}");
        let output = std::process::Command::new("node")
            .args(["-e", &source])
            .output()
            .expect("Node.js must be installed for native WASM comparisons");
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let actual = String::from_utf8(output.stdout).unwrap();
        assert_eq!(actual.lines().collect::<Vec<_>>(), expected);
        println!("native WebAssembly matched {} memory cases", cases.len());
    }

    #[test]
    fn locals_are_zero_initialized_and_tee_preserves_value() {
        assert_eq!(eval(0, 1, &[0x20, 0, 0x0b], &[]).unwrap(), [0]);
        assert_eq!(
            eval(1, 1, &[0x20, 0, 0x22, 1, 0x20, 1, 0x6c, 0x0b], &[7]).unwrap(),
            [49]
        );
        assert!(eval(1, 0, &[0x20, 0, 0x0b], &[]).is_err());
        assert!(eval(1, 0, &[0x20, 0, 0x0b], &[1, 2]).is_err());
    }

    #[test]
    fn typed_if_and_recursive_calls_return_only_declared_results() {
        let factorial = [
            0x20, 0, 0x45, 0x04, 0x7f, 0x41, 1, 0x05, 0x20, 0, 0x20, 0, 0x41, 1, 0x6b, 0x10, 0,
            0x6c, 0x0b, 0x0b,
        ];
        assert_eq!(eval(1, 0, &factorial, &[5]).unwrap(), [120]);
        assert_eq!(eval(1, 0, &factorial, &[0]).unwrap(), [1]);
        assert!(eval(1, 0, &factorial, &[1000])
            .unwrap_err()
            .contains("call depth"));
        assert_eq!(
            eval(0, 0, &[0x41, 11, 0x41, 7, 0x0f, 0x0b], &[]).unwrap(),
            [7]
        );
    }

    #[test]
    fn loops_branch_depth_and_block_results() {
        let sum = [
            0x02, 0x40, 0x03, 0x40, 0x20, 0, 0x45, 0x0d, 1, 0x20, 1, 0x20, 0, 0x6a, 0x21, 1, 0x20,
            0, 0x41, 1, 0x6b, 0x21, 0, 0x0c, 0, 0x0b, 0x0b, 0x20, 1, 0x0b,
        ];
        assert_eq!(eval(1, 1, &sum, &[10]).unwrap(), [55]);
        assert_eq!(eval(1, 1, &sum, &[0]).unwrap(), [0]);
        assert_eq!(
            eval(
                0,
                0,
                &[0x02, 0x7f, 0x41, 11, 0x41, 7, 0x0c, 0, 0x0b, 0x0b],
                &[]
            )
            .unwrap(),
            [7]
        );
        let m = decode(&numeric(0, 0, 0, &[0x03, 0x40, 0x0c, 0, 0x0b, 0x0b])).unwrap();
        assert!(run_with_fuel(&m, 0, &[], &mut TestHost::default(), 32)
            .unwrap_err()
            .contains("fuel exhausted"));
    }

    #[test]
    fn numeric_wrapping_shifts_comparisons_and_traps() {
        for (opcode, a, b, expected) in [
            (0x6a, i32::MAX, 1, i32::MIN),
            (0x6b, i32::MIN, 1, i32::MAX),
            (0x6c, i32::MAX, 2, -2),
            (0x74, 1, 33, 2),
            (0x75, -4, 1, -2),
            (0x76, -4, 1, 0x7fff_fffe),
            (0x77, i32::MIN, 1, 1),
            (0x78, 1, 1, i32::MIN),
            (0x48, -1, 0, 1),
            (0x49, -1, 0, 0),
            (0x6f, i32::MIN, -1, 0),
            (0x70, -1, 2, 1),
            (0x6e, -1, 2, i32::MAX),
        ] {
            assert_eq!(
                eval(2, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b], &[a, b]).unwrap(),
                [expected],
                "{opcode:#x}"
            );
        }
        for (opcode, args) in [
            (0x6d, [i32::MIN, -1]),
            (0x6d, [1, 0]),
            (0x6e, [1, 0]),
            (0x6f, [1, 0]),
            (0x70, [1, 0]),
        ] {
            assert!(eval(2, 0, &[0x20, 0, 0x20, 1, opcode, 0x0b], &args).is_err());
        }
        assert!(eval(0, 0, &[0x00, 0x0b], &[])
            .unwrap_err()
            .contains("unreachable"));
        for condition in [0, -1, 1] {
            assert_eq!(
                eval(1, 0, &[0x41, 7, 0x41, 9, 0x20, 0, 0x1b, 0x0b], &[condition]).unwrap(),
                [if condition == 0 { 9 } else { 7 }]
            );
        }
    }

    #[test]
    fn dom_visibility_retains_content_and_is_idempotent() {
        let mut root = Node::elem("body");
        let mut item = Node::elem("section");
        item.id = Some("item".into());
        item.children.push(Node::elem("p"));
        item.children[0].set_inner_text("retained");
        root.children.push(item);
        let mut host = DomHost { dom: &mut root };
        host.set_visible("item", false).unwrap();
        let item = host.dom.get_element_by_id("item").unwrap();
        assert!(item.hidden);
        assert_eq!(item.inner_text(), "retained");
        assert_eq!(item.children[0].name, "p");
        item.clear_dirty();
        host.set_visible("item", false).unwrap();
        assert!(!host.dom.get_element_by_id("item").unwrap().dirty);
        host.set_visible("item", true).unwrap();
        let item = host.dom.get_element_by_id("item").unwrap();
        assert!(!item.hidden);
        assert_eq!(item.inner_text(), "retained");
        assert!(host.set_visible("missing", false).is_err());
    }

    #[test]
    fn manually_emptied_body_is_rejected_before_runtime_frame_creation() {
        let mut m = decode(&numeric(0, 0, 0, &[0x0b])).unwrap();
        m.bodies[0].clear();
        m.exports[0].name = "_start".into();
        assert_eq!(crate::validate(&m).unwrap_err(), "missing function end");
        let outcome = std::panic::catch_unwind(|| {
            let mut host = TestHost::default();
            let direct = run(&m, 0, &[], &mut host).unwrap_err();
            let budgeted = run_with_fuel(&m, 0, &[], &mut host, 32).unwrap_err();
            let start = run_start(&m, &mut host).unwrap_err();
            assert_eq!(host.0, 0);
            (direct, budgeted, start)
        });
        let errors = outcome.expect("empty body must return errors without panicking");
        println!("empty body errors={errors:?}");
        assert_eq!(
            errors,
            (
                "missing function end".into(),
                "missing function end".into(),
                "missing function end".into()
            )
        );
    }

    #[test]
    fn validation_precedes_host_effects_and_pointer_errors_do_not_panic() {
        let mut m = decode(&encode_ui_module("status", "hello")).unwrap();
        let mut host = TestHost::default();
        m.bodies[0].push(Instr::Nop);
        assert!(run_start(&m, &mut host).is_err());
        assert_eq!(host.0, 0);
        m.bodies[0] = vec![
            Instr::I32Const(-1),
            Instr::I32Const(-1),
            Instr::I32Const(0),
            Instr::I32Const(0),
            Instr::Call(0),
            Instr::End,
        ];
        assert!(run_start(&m, &mut host).is_err());
        assert_eq!(host.0, 0);
        let mut m = decode(&encode_ui_module("status", "hello")).unwrap();
        m.memory[0] = 255;
        assert!(run_start(&m, &mut host).is_err());
        assert_eq!(host.0, 0);
        m.types[0].results = 1;
        assert!(run(&m, 0, &[0, 0, 0, 0], &mut host).is_err());
    }
}
