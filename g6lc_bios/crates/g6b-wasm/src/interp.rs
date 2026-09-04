// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Host interpreter — the BIOS UI “JIT”.

#![allow(missing_docs)]

use crate::binary::{Instr, Module};
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
        if !on {
            n.set_inner_text("");
        }
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
    run(m, idx, &[], host).map(|_| ())
}

/// Run function `idx` (import space first).
pub fn run(m: &Module, idx: u32, args: &[i32], host: &mut impl Host) -> Result<Vec<i32>, String> {
    let nimp = m.imports.len() as u32;
    if idx < nimp {
        return call_import(m, idx, args, host).map(|v| v.into_iter().collect());
    }
    let local = (idx - nimp) as usize;
    let body = m.bodies.get(local).ok_or("bad func")?;
    let nparams = m
        .func_types
        .get(local)
        .and_then(|t| m.types.get(*t as usize))
        .map(|t| t.params)
        .unwrap_or(0) as usize;
    let mut locals = vec![0i32; nparams.max(args.len())];
    for (i, a) in args.iter().enumerate() {
        if i < locals.len() {
            locals[i] = *a;
        }
    }
    let mut stack = Vec::new();
    exec(m, body, &mut locals, &mut stack, host)?;
    Ok(stack)
}

fn exec(
    m: &Module,
    body: &[Instr],
    locals: &mut [i32],
    stack: &mut Vec<i32>,
    host: &mut impl Host,
) -> Result<(), String> {
    for ins in body {
        match ins {
            Instr::End | Instr::Nop => {}
            Instr::Return => return Ok(()),
            Instr::Drop => {
                stack.pop();
            }
            Instr::I32Const(v) => stack.push(*v),
            Instr::LocalGet(i) => {
                let v = *locals.get(*i as usize).ok_or("local.get")?;
                stack.push(v);
            }
            Instr::LocalSet(i) => {
                let v = stack.pop().ok_or("local.set stack")?;
                *locals.get_mut(*i as usize).ok_or("local.set")? = v;
            }
            Instr::I32Add => {
                let b = stack.pop().ok_or("add")?;
                let a = stack.pop().ok_or("add")?;
                stack.push(a.wrapping_add(b));
            }
            Instr::I32Sub => {
                let b = stack.pop().ok_or("sub")?;
                let a = stack.pop().ok_or("sub")?;
                stack.push(a.wrapping_sub(b));
            }
            Instr::Call(idx) => {
                let nimp = m.imports.len() as u32;
                if *idx < nimp {
                    let nparams = m
                        .imports
                        .get(*idx as usize)
                        .and_then(|im| m.types.get(im.typeidx as usize))
                        .map(|t| t.params)
                        .unwrap_or(0) as usize;
                    if stack.len() < nparams {
                        return Err("call args".into());
                    }
                    let args: Vec<i32> = stack.split_off(stack.len() - nparams);
                    let rets = call_import(m, *idx, &args, host)?;
                    stack.extend(rets);
                } else {
                    return Err("nested wasm call not in MVP JIT".into());
                }
            }
        }
    }
    Ok(())
}

fn call_import(
    m: &Module,
    idx: u32,
    args: &[i32],
    host: &mut impl Host,
) -> Result<Vec<i32>, String> {
    let im = m.imports.get(idx as usize).ok_or("import")?;
    if im.module != "env" {
        return Err(format!("unknown import module {}", im.module));
    }
    match im.name.as_str() {
        IMPORT_SET_INNER_TEXT => {
            let id = mem_str(
                m,
                args.first().copied().unwrap_or(0),
                args.get(1).copied().unwrap_or(0),
            )?;
            let val = mem_str(
                m,
                args.get(2).copied().unwrap_or(0),
                args.get(3).copied().unwrap_or(0),
            )?;
            host.set_inner_text(&id, &val)?;
            Ok(Vec::new())
        }
        IMPORT_LOG => {
            let s = mem_str(
                m,
                args.first().copied().unwrap_or(0),
                args.get(1).copied().unwrap_or(0),
            )?;
            host.log(&s);
            Ok(Vec::new())
        }
        IMPORT_SET_VISIBLE => {
            let id = mem_str(
                m,
                args.first().copied().unwrap_or(0),
                args.get(1).copied().unwrap_or(0),
            )?;
            host.set_visible(&id, args.get(2).copied().unwrap_or(0) != 0)?;
            Ok(Vec::new())
        }
        IMPORT_FETCH | IMPORT_OBJECT_CALL => {
            let url = mem_str(
                m,
                args.first().copied().unwrap_or(0),
                args.get(1).copied().unwrap_or(0),
            )?;
            let _body = host.fetch(&url)?;
            Ok(Vec::new())
        }
        other => Err(format!("unknown import env.{other}")),
    }
}

fn mem_str(m: &Module, ptr: i32, len: i32) -> Result<String, String> {
    let p = ptr as usize;
    let n = len as usize;
    let b = m.memory.get(p..p + n).ok_or("wasm oob")?;
    Ok(String::from_utf8_lossy(b).into_owned())
}
