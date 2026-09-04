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
    void doLog(uint) {}
    void libwasm_await__void(uint) {}
    uint libwasm_add__int(int) { return 0; }
    uint libwasm_add__uint(uint) { return 0; }
    uint libwasm_add__long(long) { return 0; }
    uint libwasm_add__ulong(ulong) { return 0; }
    uint libwasm_add__short(short) { return 0; }
    uint libwasm_add__ushort(ushort) { return 0; }
    uint libwasm_add__float(float) { return 0; }
    uint libwasm_add__double(double) { return 0; }
    uint libwasm_add__byte(byte) { return 0; }
    uint libwasm_add__ubyte(ubyte) { return 0; }
    uint libwasm_add__ints(int[]) { return 0; }
    uint libwasm_add__uints(uint[]) { return 0; }
    uint libwasm_copyObjectRef(uint h) { return h; }
    uint libasync_promise_all__promise(uint h) { return h; }
    uint libasync_promise_any__promise(uint h) { return h; }
    uint libasync_promise_allsettled__promise(uint h) { return h; }
    void libwasm_unset__function(string) {}
    uint libwasm_get__field(uint, string) { return 0; }
    uint libwasm_get_idx__field(uint, uint) { return 0; }
    bool libwasm_get__bool(uint) { return false; }
    int libwasm_get__int(uint) { return 0; }
    uint libwasm_get__uint(uint) { return 0; }
    long libwasm_get__long(uint) { return 0; }
    ulong libwasm_get__ulong(uint) { return 0; }
    short libwasm_get__short(uint) { return 0; }
    ushort libwasm_get__ushort(uint) { return 0; }
    float libwasm_get__float(uint) { return 0; }
    double libwasm_get__double(uint) { return 0; }
    byte libwasm_get__byte(uint) { return 0; }
    ubyte libwasm_get__ubyte(uint) { return 0; }
    void Static_Call_string__void(string, string, string) {}
    void Object_Call__void(uint, string) {}

    void Object_Call_string__void(uint, string method, string arg)
    {
        if (method == "innerText" || method == "textContent")
            g6b_text("status", arg);
        else if (method == "fetch")
            g6b_fetch(arg);
    }

    void Object_Call_uint__void(uint, string, uint) {}
    void Object_Call_int__void(uint, string, int) {}
    void Object_Call_bool__void(uint, string, bool) {}
    void Object_Call_double__void(uint, string, double) {}
    void Object_Call_float__void(uint, string, float) {}
    void Object_Call_Handle__void(uint, string, uint) {}
    void Object_Call_string_string__void(uint, string, string, string) {}
    void Object_Call_double_double__void(uint, string, double, double) {}

    uint Object_Call_string__Handle(uint, string method, string arg)
    {
        if (method == "fetch" || method == "getElementById")
        {
            if (method == "fetch")
                g6b_fetch(arg);
            else
                g6b_text(arg, "");
        }
        return 0;
    }

    uint Object_Call_uint__Handle(uint, string, uint) { return 0; }
    uint Object_Call_int__Handle(uint, string, int) { return 0; }
    uint Object_Call_bool__Handle(uint, string, bool) { return 0; }
    uint Object_Call_Handle__Handle(uint, string, uint) { return 0; }
    uint Object_Call_string_string__Handle(uint, string, string, string) { return 0; }

    Optional!string Object_Getter__OptionalString(uint, string) { return Optional!string(); }
    Optional!uint Object_Getter__OptionalUint(uint, string) { return Optional!uint(); }
    Optional!double Object_Getter__OptionalDouble(uint, string) { return Optional!double(); }
    Optional!bool Object_Getter__OptionalBool(uint, string) { return Optional!bool(); }
    Optional!string Object_Call_string__OptionalString(uint, string, string) { return Optional!string(); }
    EventHandler Object_Getter__EventHandler(uint, string) { return EventHandler(); }
    Optional!uint Object_Call_string__OptionalHandle(uint, string, string) { return Optional!uint(); }
    Optional!uint Object_Call_uint__OptionalHandle(uint, string, uint) { return Optional!uint(); }
    Optional!uint Object_Call_int__OptionalHandle(uint, string, int) { return Optional!uint(); }
    Optional!uint Object_Call_bool__OptionalHandle(uint, string, bool) { return Optional!uint(); }

    int Object_Getter__int(uint, string) { return 0; }
    uint Object_Getter__uint(uint, string) { return 0; }
    ushort Object_Getter__ushort(uint, string) { return 0; }
    bool Object_Getter__bool(uint, string) { return false; }
    float Object_Getter__float(uint, string) { return 0; }
    double Object_Getter__double(uint, string) { return 0; }
    bool Object_Call_string__bool(uint, string, string) { return false; }
    string Object_Call_string__string(uint, string, string) { return ""; }
    string Object_Call_uint__string(uint, string, uint) { return ""; }
    string Object_Call_uint_uint__string(uint, string, uint, uint) { return ""; }

    bool Object_VarArgCall__bool(uint, string, string, string) { return false; }
    string Object_VarArgCall__string(uint, string, string, string) { return ""; }
    int Object_VarArgCall__int(uint, string, string, string) { return 0; }
    uint Object_VarArgCall__uint(uint, string, string, string) { return 0; }
    short Object_VarArgCall__short(uint, string, string, string) { return 0; }
    ushort Object_VarArgCall__ushort(uint, string, string, string) { return 0; }
    uint Object_VarArgCall__Handle(uint, string, string, string) { return 0; }
    float Object_VarArgCall__float(uint, string, string, string) { return 0; }
    double Object_VarArgCall__double(uint, string, string, string) { return 0; }
    long Object_VarArgCall__long(uint, string, string, string) { return 0; }
    ulong Object_VarArgCall__ulong(uint, string, string, string) { return 0; }
    long getTimeStamp() { return 0; }

    uint JSON_parse_string(string) { return 0; }
    string JSON_stringify(uint) { return "{}"; }

    int setInterval(int, int, int) { return 0; }
    void clearTimeout(int) {}
    void clearInterval(int) {}

    uint libwasm_add__object() { return 0; }
    void libwasm_removeObject(uint) {}
    void Static_Call_Handle__void(string, string, uint) {}
}
