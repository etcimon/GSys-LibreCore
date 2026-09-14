// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! WASM MVP decoder, host interpreter (BIOS UI JIT), and RISC-V lower.
//! Spec: `kernel-spec/svelte-d` libwasm imports. No wasmtime / wasmi.

#![allow(missing_docs, non_snake_case)]

mod asyncify;
mod binary;
mod browser;
mod interp;
mod jcode;
mod jit;
mod json;
mod objects;
mod values;
mod webidl;

pub use asyncify::{
    asyncify_wat, find_fork_wasm_opt, reserve_asyncify_scratch, Asyncify, Step, STATE_NORMAL,
    STATE_REWINDING, STATE_UNWINDING, TRY_TABLE_AWAIT_WAT, UI_EVENT_THROW_WAT,
};
pub use binary::{
    decode, encode_empty_ui_module, encode_ui_module, instruction_budget, validate, Element,
    Export, FuncType, Import, Instr, Module, Table, ValType, BIOS_UI_CELL_BUDGET,
    MAX_CONTROL_DEPTH, MAX_FUNCTIONS, MAX_INSTRUCTIONS, MAX_INSTRUCTIONS_CEIL, MAX_LOCALS,
    MAX_MEMORY_PAGES, MAX_MODULE_BYTES, MAX_STACK,
};
pub use browser::{JsExportKind, JsExports, KernelPort};
pub use interp::{
    export_func, is_unhandled_d_abort, run, run_start, run_with_fuel, run_with_fuel_mut,
    table_funcref, DomHost, GuestFn, Host, Ldexec, LdexecInit, DEFAULT_FUEL, MAX_CALL_DEPTH,
    MAX_FUEL,
};
pub use jcode::{
    cell_bytes as jcode_cell_bytes, data_offset as jcode_data_offset, encode as jcode_encode,
    install_guest, op_coverage, test_module as jcode_test_module, OpCoverage, OpGap, EXT_AWAIT,
    EXT_CATCH, EXT_FETCH, EXT_LOG, EXT_SET_TEXT, EXT_SET_VISIBLE, EXT_THROW,
    FHDR_BYTES as JCODE_FHDR_BYTES, FHDR_F_IMPORT, HDR_BYTES as JCODE_HDR_BYTES, JIT_STK_BYTES,
    MAGIC as JCODE_MAGIC, MAX_JIT_CODE_BYTES, MAX_JIT_FUNCS, MAX_JIT_GLOBALS, MAX_JIT_LOCALS,
    MAX_JIT_MEM_PAGES, MAX_JIT_RECORDS, OFF_DATA_LEN, OFF_ENTRY, OFF_GLOB_LEN, OFF_MEM_PAGES,
    OFF_NFUNCS, OFF_NIMPORTS, OFF_NRECORDS, REC_BYTES as JCODE_REC_BYTES, R_CALL, R_CMP, R_CONST,
    R_DROP, R_EXCCHK, R_EXCCLR, R_EXT, R_GGET, R_GSET, R_I32ALU, R_I32DIV, R_I32ROT, R_I64ALU,
    R_I64DIV, R_I64ROT, R_JMP, R_JNZ, R_JZ, R_LGET, R_LOAD, R_LSET, R_LTEE, R_MEMGROW, R_MEMSIZE,
    R_NOP, R_RET, R_SELECT, R_STORE, R_THROW, R_TRAP, TRAP_BADFUNC, TRAP_DIV0, TRAP_EXC, TRAP_EXT,
    TRAP_FUEL, TRAP_OOB, TRAP_STK, TRAP_UNREACH, TRAP_UNSUP, TRAP_XLATE,
};
pub use jit::{
    data_image, install_start, jit_add_i32, jit_riscv, start_ops, MAX_JIT_INSTRUCTIONS,
    MAX_JIT_SLOTS, MAX_WASM_DATA,
};
pub use json::{
    libwasm_to_json_string, parse_libwasm_json, stringify_libwasm_json, vararg_from_json,
};
pub use objects::{
    is_root, ObjectTable, MAX_OBJECTS, OBJECT_BASE, OBJECT_ROOT_DOM, OBJECT_ROOT_SCOPE,
};
pub use values::{add_value, string_of, LibwasmValue, ObjectKind};
pub use webidl::{
    dom_exception, hierarchy_request_append_child, invalid_character_create_element,
    is_js_host_throw, is_valid_element_name, is_valid_request_url, js_throw_payload,
    request_type_error, type_error, HIERARCHY_REQUEST_ERR, INVALID_CHARACTER_ERR,
};

/// Boot / generated-source marker.
pub const MARKER: &str = "WASM-JIT";

/// browser-ui compile products (svelte-d → svelte-engine-ws → Bun/TS).
pub const BIOS_UI_WASM: &[u8] = g6b_asm::BIOS_UI_WASM;
pub const BIOS_UI_JS: &str = include_str!("../../../browser-ui/out/bios-ui.js");
pub const BIOS_UI_CATALOG: &str = include_str!("../../../browser-ui/out/catalog.json");

/// Bytes of `browser-ui/out/bios-ui.wasm`.
pub fn bios_ui_wasm() -> &'static [u8] {
    BIOS_UI_WASM
}

/// Bytes of `browser-ui/out/bios-ui-libwasm.wasm` (LDC/libwasm wasm-eh cell).
/// Empty until `G6B_DUB_WASM=1 bun scripts/build.ts` runs locally.
pub fn bios_ui_libwasm() -> &'static [u8] {
    g6b_asm::BIOS_UI_LIBWASM
}

/// True when the libwasm lane artifact is a real WASM module.
pub fn bios_ui_libwasm_live() -> bool {
    bios_ui_libwasm().len() <= MAX_MODULE_BYTES && bios_ui_libwasm().starts_with(b"\0asm\x01\0\0\0")
}

/// `SVELTE-LIVE` / `SVELTE-STUB` / `SVELTE-REFUSED` markers from catalog.json.
pub fn svelte_live_markers() -> Vec<String> {
    json_str_array(BIOS_UI_CATALOG, "live")
        .into_iter()
        .map(|c| format!("SVELTE-LIVE {c}"))
        .collect()
}

/// Stub construct markers (`SVELTE-STUB {#await}`, …).
pub fn svelte_stub_markers() -> Vec<String> {
    json_str_array(BIOS_UI_CATALOG, "stub")
        .into_iter()
        .map(|c| format!("SVELTE-STUB {c}"))
        .collect()
}

fn json_str_array(s: &str, key: &str) -> Vec<String> {
    let pat = format!("\"{key}\"");
    let Some(i) = s.find(&pat) else {
        return Vec::new();
    };
    let rest = &s[i + pat.len()..];
    let Some(b) = rest.find('[') else {
        return Vec::new();
    };
    let Some(e) = rest[b..].find(']') else {
        return Vec::new();
    };
    rest[b + 1..b + e]
        .split(',')
        .filter_map(|p| {
            let p = p.trim().trim_matches('"');
            if p.is_empty() {
                None
            } else {
                Some(p.to_string())
            }
        })
        .collect()
}

/// Import name matching the svelte-d / libwasm handle-table subset.
pub const IMPORT_SET_INNER_TEXT: &str = "set_inner_text";
pub const IMPORT_LOG: &str = "console_log";
pub const IMPORT_SET_VISIBLE: &str = "set_visible";
/// libwasm `Object_Call_string__Handle` / `fetch` → kernel HTTP router.
pub const IMPORT_FETCH: &str = "fetch";
/// libwasm etch_post(url, body) → the kernel router's **write** side. Host-gated:
/// the kernel accepts a body on /bios/store paths and refuses the rest.
pub const IMPORT_FETCH_POST: &str = "fetch_post";
pub const IMPORT_OBJECT_CALL: &str = "Object_Call_string__Handle";
/// `env.await` — claim a bounded pending slot (`WasmAwait`): the guest-side
/// correlate of `await <op>` — nonblocking, resolves on the kernel poll.
pub const IMPORT_AWAIT: &str = "await";
/// `env.throw` — reject a specific pending slot (`WasmThrow`): the
/// guest-side correlate of a thrown rejection reaching an awaiter.
pub const IMPORT_THROW: &str = "throw";
/// `env.catch` — query whether a slot was rejected (`WasmCatch`) -> i32;
/// the guest-side correlate of a Promise `.catch` predicate.
pub const IMPORT_CATCH: &str = "catch";
/// `env.addEventListener(target, type, listener, capture)`.
pub const IMPORT_ADD_EVENT_LISTENER: &str = "addEventListener";
/// `env.removeEventListener(listener)`.
pub const IMPORT_REMOVE_EVENT_LISTENER: &str = "removeEventListener";
/// `env.dispatchEvent(target, type, detail)` -> i32 (0 if default prevented).
pub const IMPORT_DISPATCH_EVENT: &str = "dispatchEvent";
/// `env.libwasm_await__void` — Binaryen Asyncify suspend on a Promise handle.
/// Param: i32 handle; result: none (rewinds and resumes via Asyncify state).
pub const IMPORT_LIBWASM_AWAIT_VOID: &str = "libwasm_await__void";
pub const IMPORT_CREATE_ELEMENT: &str = "createElement";
pub const IMPORT_APPEND_CHILD: &str = "appendChild";
pub const IMPORT_SET_PROPERTY: &str = "setProperty";
pub const IMPORT_HOLYC: &str = "holyc";
pub const IMPORT_REGISTER_ENDPOINT: &str = "register_endpoint";
/// `env.libwasm_await_supported() -> i32` — 1 when Asyncify exports are present.
pub const IMPORT_LIBWASM_AWAIT_SUPPORTED: &str = "libwasm_await_supported";
/// `env.libwasm_await_failed() -> i32` — 1 when the last `.await` rejected.
pub const IMPORT_LIBWASM_AWAIT_FAILED: &str = "libwasm_await_failed";
/// `env.libwasm_await_error(raw_result)` — write the reject reason string.
pub const IMPORT_LIBWASM_AWAIT_ERROR: &str = "libwasm_await_error";
/// `env.libwasm_await_value(raw_result)` — write the resolve value string.
pub const IMPORT_LIBWASM_AWAIT_VALUE: &str = "libwasm_await_value";
/// `env.libwasm_note_await_fail(handle)` — record `handle` as a rejection.
pub const IMPORT_LIBWASM_NOTE_AWAIT_FAIL: &str = "libwasm_note_await_fail";
/// `env.libwasm_note_await_ok(handle)` — record `handle` as a resolution.
pub const IMPORT_LIBWASM_NOTE_AWAIT_OK: &str = "libwasm_note_await_ok";
/// `env.libwasm_get__string(raw_result, handle)` — copy object string to guest.
pub const IMPORT_LIBWASM_GET_STRING: &str = "libwasm_get__string";
/// `env.libwasm_add__string(ptr, len) -> handle` — add a guest string to the
/// object table and return a handle.
pub const IMPORT_LIBWASM_ADD_STRING: &str = "libwasm_add__string";
/// `env.libwasm_add__object() -> handle` — a fresh empty host object (B61).
pub const IMPORT_LIBWASM_ADD_OBJECT: &str = "libwasm_add__object";
/// `env.libwasm_removeObject(handle)` — drop one `JsHandle` reference (B61).
pub const IMPORT_LIBWASM_REMOVE_OBJECT: &str = "libwasm_removeObject";
/// `env.libwasm_copyObjectRef(handle) -> handle` — `JsHandle` copy ctor (B61).
pub const IMPORT_LIBWASM_COPY_OBJECT_REF: &str = "libwasm_copyObjectRef";

// B62 scalar box/unbox.
pub const IMPORT_LIBWASM_ADD_BOOL: &str = "libwasm_add__bool";
pub const IMPORT_LIBWASM_ADD_INT: &str = "libwasm_add__int";
pub const IMPORT_LIBWASM_ADD_UINT: &str = "libwasm_add__uint";
pub const IMPORT_LIBWASM_ADD_LONG: &str = "libwasm_add__long";
pub const IMPORT_LIBWASM_ADD_ULONG: &str = "libwasm_add__ulong";
pub const IMPORT_LIBWASM_ADD_SHORT: &str = "libwasm_add__short";
pub const IMPORT_LIBWASM_ADD_USHORT: &str = "libwasm_add__ushort";
pub const IMPORT_LIBWASM_ADD_FLOAT: &str = "libwasm_add__float";
pub const IMPORT_LIBWASM_ADD_DOUBLE: &str = "libwasm_add__double";
pub const IMPORT_LIBWASM_ADD_BYTE: &str = "libwasm_add__byte";
pub const IMPORT_LIBWASM_ADD_UBYTE: &str = "libwasm_add__ubyte";
pub const IMPORT_LIBWASM_ADD_INTS: &str = "libwasm_add__ints";
pub const IMPORT_LIBWASM_ADD_UINTS: &str = "libwasm_add__uints";

pub const IMPORT_LIBWASM_GET_BOOL: &str = "libwasm_get__bool";
pub const IMPORT_LIBWASM_GET_INT: &str = "libwasm_get__int";
pub const IMPORT_LIBWASM_GET_UINT: &str = "libwasm_get__uint";
pub const IMPORT_LIBWASM_GET_LONG: &str = "libwasm_get__long";
pub const IMPORT_LIBWASM_GET_ULONG: &str = "libwasm_get__ulong";
pub const IMPORT_LIBWASM_GET_SHORT: &str = "libwasm_get__short";
pub const IMPORT_LIBWASM_GET_USHORT: &str = "libwasm_get__ushort";
pub const IMPORT_LIBWASM_GET_FLOAT: &str = "libwasm_get__float";
pub const IMPORT_LIBWASM_GET_DOUBLE: &str = "libwasm_get__double";
pub const IMPORT_LIBWASM_GET_BYTE: &str = "libwasm_get__byte";
pub const IMPORT_LIBWASM_GET_UBYTE: &str = "libwasm_get__ubyte";

// B63 property registry (declared now, fail-closed until implemented).
pub const IMPORT_LIBWASM_GET_FIELD: &str = "libwasm_get__field";
pub const IMPORT_LIBWASM_GET_IDX_FIELD: &str = "libwasm_get_idx__field";

#[cfg(test)]
mod tests {
    use super::*;
    use g6b_dom::Node;

    #[test]
    fn ui_module_sets_dom() {
        let bytes = encode_ui_module("status", "UI-BOOT");
        let m = decode(&bytes).unwrap();
        let mut root = Node::elem("body");
        let mut p = Node::elem("p");
        p.id = Some("status".into());
        p.set_inner_text("boot");
        root.children.push(p);
        run_start(
            &m,
            &mut DomHost {
                dom: &mut root,
                handles: Vec::new(),
            },
        )
        .unwrap();
        assert_eq!(
            root.get_element_by_id("status").unwrap().inner_text(),
            "UI-BOOT"
        );
    }

    #[test]
    fn jit_add_lowers_to_add() {
        let m = jit_add_i32();
        let s = m.to_asm();
        assert!(s.contains("purpose=wasm-jit"), "{s}");
        assert!(s.contains("\tadd\t"), "{s}");
        let (w, _) = m.to_words(0).unwrap();
        assert!(w.len() >= 2);
    }

    #[test]
    fn rejects_bad_magic() {
        assert!(decode(b"XXXX").is_err());
    }

    #[test]
    fn bios_ui_wasm_starts_and_catalog_live() {
        assert_eq!(&BIOS_UI_WASM[..4], b"\0asm");
        let m = decode(BIOS_UI_WASM).unwrap();
        assert!(m.exports.iter().any(|e| e.name == "_start"));
        assert!(m.imports.iter().any(|i| i.name == IMPORT_SET_INNER_TEXT));
        let live = svelte_live_markers();
        assert!(live.iter().any(|s| s.contains("FileMgr")), "{live:?}");
        assert!(live.iter().any(|s| s.contains("NodeDef")), "{live:?}");
        assert!(live.iter().any(|s| s.contains("Settings")), "{live:?}");
        assert!(BIOS_UI_JS.contains("UI-BOOT"));
        assert!(!BIOS_UI_JS.contains("kernel.holyc"));
        assert!(!BIOS_UI_JS.contains("kernel.register"));
        assert!(BIOS_UI_JS.contains("/bios/menu/settings"));
        let mut root = Node::elem("body");
        let mut p = Node::elem("p");
        p.id = Some("status".into());
        root.children.push(p);
        struct SkipMissing<'a> {
            dom: &'a mut Node,
        }
        impl Host for SkipMissing<'_> {
            fn set_inner_text(&mut self, id: &str, val: &str) -> Result<(), String> {
                if let Some(n) = self.dom.get_element_by_id(id) {
                    n.set_inner_text(val);
                }
                Ok(())
            }
            fn log(&mut self, _msg: &str) {}
            fn set_visible(&mut self, _id: &str, _on: bool) -> Result<(), String> {
                Ok(())
            }
        }
        run_start(&m, &mut SkipMissing { dom: &mut root }).unwrap();
        assert_eq!(
            root.get_element_by_id("status").unwrap().inner_text(),
            "UI-BOOT: read-only setup"
        );
    }
}
