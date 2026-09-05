// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// G6LC BIOS adaptation: JS Object_Call_* imports become D stubs that call
// the g6b-wasm Host (`env.set_inner_text`, `env.fetch`). Local clone only
// (browser-ui/libwasm); kernel-spec/libwasm is never compiled.
module libwasm.g6b_kernel;

nothrow:
@safe:

import optional;
import libwasm.bindings.EventHandler : EventHandler, EventHandlerNonNull;


extern (C)
{
    void set_inner_text(uint id_ptr, uint id_len, uint val_ptr, uint val_len);
    void fetch(uint url_ptr, uint url_len);
    void console_log(uint ptr, uint len);
    void set_visible(uint id_ptr, uint id_len, int on);
}

private void g6b_text(string id, string val) @trusted
{
    set_inner_text(cast(uint) id.ptr, cast(uint) id.length, cast(uint) val.ptr, cast(uint) val.length);
}

private void g6b_fetch(string url) @trusted
{
    fetch(cast(uint) url.ptr, cast(uint) url.length);
}

extern (C) uint getRoot()
{
    return 1;
}

extern (C)
{
    void doLog(uint) { assert(0); }
    void libwasm_await__void(uint) { assert(0); }
    uint libwasm_add__int(int) { assert(0); }
    uint libwasm_add__uint(uint) { assert(0); }
    uint libwasm_add__long(long) { assert(0); }
    uint libwasm_add__ulong(ulong) { assert(0); }
    uint libwasm_add__short(short) { assert(0); }
    uint libwasm_add__ushort(ushort) { assert(0); }
    uint libwasm_add__float(float) { assert(0); }
    uint libwasm_add__double(double) { assert(0); }
    uint libwasm_add__byte(byte) { assert(0); }
    uint libwasm_add__ubyte(ubyte) { assert(0); }
    uint libwasm_add__ints(int[]) { assert(0); }
    uint libwasm_add__uints(uint[]) { assert(0); }
    uint libwasm_copyObjectRef(uint h) { assert(0); }
    uint libasync_promise_all__promise(uint h) { assert(0); }
    uint libasync_promise_any__promise(uint h) { assert(0); }
    uint libasync_promise_allsettled__promise(uint h) { assert(0); }
    void libwasm_unset__function(string) { assert(0); }
    uint libwasm_get__field(uint, string) { assert(0); }
    uint libwasm_get_idx__field(uint, uint) { assert(0); }
    bool libwasm_get__bool(uint) { assert(0); }
    int libwasm_get__int(uint) { assert(0); }
    uint libwasm_get__uint(uint) { assert(0); }
    long libwasm_get__long(uint) { assert(0); }
    ulong libwasm_get__ulong(uint) { assert(0); }
    short libwasm_get__short(uint) { assert(0); }
    ushort libwasm_get__ushort(uint) { assert(0); }
    float libwasm_get__float(uint) { assert(0); }
    double libwasm_get__double(uint) { assert(0); }
    byte libwasm_get__byte(uint) { assert(0); }
    ubyte libwasm_get__ubyte(uint) { assert(0); }
    void Static_Call_string__void(string, string, string) { assert(0); }
    void Object_Call__void(uint, string) { assert(0); }

    void Object_Call_string__void(uint, string method, string arg)
    {
        assert(0);
    }

    void Object_Call_uint__void(uint, string, uint) { assert(0); }
    void Object_Call_int__void(uint, string, int) { assert(0); }
    void Object_Call_bool__void(uint, string, bool) { assert(0); }
    void Object_Call_double__void(uint, string, double) { assert(0); }
    void Object_Call_float__void(uint, string, float) { assert(0); }
    void Object_Call_Handle__void(uint, string, uint) { assert(0); }
    void Object_Call_string_string__void(uint, string, string, string) { assert(0); }
    void Object_Call_double_double__void(uint, string, double, double) { assert(0); }

    uint Object_Call_string__Handle(uint, string method, string arg)
    {
        assert(0);
    }

    uint Object_Call_uint__Handle(uint, string, uint) { assert(0); }
    uint Object_Call_int__Handle(uint, string, int) { assert(0); }
    uint Object_Call_bool__Handle(uint, string, bool) { assert(0); }
    uint Object_Call_Handle__Handle(uint, string, uint) { assert(0); }
    uint Object_Call_string_string__Handle(uint, string, string, string) { assert(0); }

    Optional!string Object_Getter__OptionalString(uint, string) { assert(0); }
    Optional!uint Object_Getter__OptionalUint(uint, string) { assert(0); }
    Optional!double Object_Getter__OptionalDouble(uint, string) { assert(0); }
    Optional!bool Object_Getter__OptionalBool(uint, string) { assert(0); }
    Optional!string Object_Call_string__OptionalString(uint, string, string) { assert(0); }
    EventHandler Object_Getter__EventHandler(uint, string) { assert(0); }
    Optional!uint Object_Call_string__OptionalHandle(uint, string, string) { assert(0); }
    Optional!uint Object_Call_uint__OptionalHandle(uint, string, uint) { assert(0); }
    Optional!uint Object_Call_int__OptionalHandle(uint, string, int) { assert(0); }
    Optional!uint Object_Call_bool__OptionalHandle(uint, string, bool) { assert(0); }

    // String/Handle getters resolve to empty handles: the g6b DOM kernel
    // owns element creation, so JS-side object lookups have no meaning here.
    string Object_Getter__string(uint, string) { assert(0); }
    uint Object_Getter__Handle(uint, string) { assert(0); }
    Optional!uint Object_Getter__OptionalHandle(uint, string) { assert(0); }
    string libwasm_get__string(uint) { assert(0); }
    uint libwasm_add__string(string) { assert(0); }
    void libwasm_set__function(string, int, int) { assert(0); }
    int setTimeout(int, int, int) { assert(0); }
    void Object_Call_EventHandler__void(uint, string, bool, scope EventHandlerNonNull) { assert(0); }
    void Object_VarArgCall__void(uint, string, string, string) { assert(0); }

    int Object_Getter__int(uint, string) { assert(0); }
    uint Object_Getter__uint(uint, string) { assert(0); }
    ushort Object_Getter__ushort(uint, string) { assert(0); }
    bool Object_Getter__bool(uint, string) { assert(0); }
    float Object_Getter__float(uint, string) { assert(0); }
    double Object_Getter__double(uint, string) { assert(0); }
    bool Object_Call_string__bool(uint, string, string) { assert(0); }
    string Object_Call_string__string(uint, string, string) { assert(0); }
    string Object_Call_uint__string(uint, string, uint) { assert(0); }
    string Object_Call_uint_uint__string(uint, string, uint, uint) { assert(0); }

    bool Object_VarArgCall__bool(uint, string, string, string) { assert(0); }
    string Object_VarArgCall__string(uint, string, string, string) { assert(0); }
    int Object_VarArgCall__int(uint, string, string, string) { assert(0); }
    uint Object_VarArgCall__uint(uint, string, string, string) { assert(0); }
    short Object_VarArgCall__short(uint, string, string, string) { assert(0); }
    ushort Object_VarArgCall__ushort(uint, string, string, string) { assert(0); }
    uint Object_VarArgCall__Handle(uint, string, string, string) { assert(0); }
    float Object_VarArgCall__float(uint, string, string, string) { assert(0); }
    double Object_VarArgCall__double(uint, string, string, string) { assert(0); }
    long Object_VarArgCall__long(uint, string, string, string) { assert(0); }
    ulong Object_VarArgCall__ulong(uint, string, string, string) { assert(0); }
    long getTimeStamp() { assert(0); }

    uint JSON_parse_string(string) { assert(0); }
    string JSON_stringify(uint) { assert(0); }

    int setInterval(int, int, int) { assert(0); }
    void clearTimeout(int) { assert(0); }
    void clearInterval(int) { assert(0); }

    uint libwasm_add__object() { assert(0); }
    void libwasm_removeObject(uint) { assert(0); }
    void Static_Call_Handle__void(string, string, uint) { assert(0); }
}

// libc / GC kernel surface: druntime-wasm keeps these as `env.*` imports for
// the JS harness. In the g6b cell there is no JS kernel, so they are inert
// D definitions. `false`/empty results pick the conservative druntime path
// (array ops reallocate; errno stays 0; formatting writes nothing).
extern (C)
{
    bool gc_expandArrayUsed(void[] slice, size_t newUsed, bool atomic) { assert(0); }
    bool gc_shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic) { assert(0); }

    // ABI twin of druntime core.memory.BlkInfo_ (private to druntime).
    struct G6bBlkInfo { void* base; size_t size; uint attr; }

    pragma(mangle, "gc_query")
    G6bBlkInfo g6b_gc_query(return scope void* p) { assert(0); }

    __gshared int g6b_errno;

    ref int _errno() @system { return g6b_errno; }

    real strtold(inout(char)* nptr, inout(char)** endptr) @system
    {
        assert(0);
    }

    int snprintf(char* s, size_t n, const(char)* format, ...) @system
    {
        assert(0);
    }
}
