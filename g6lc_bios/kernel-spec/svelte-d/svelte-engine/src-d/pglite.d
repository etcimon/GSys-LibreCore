module pglite;


import libwasm.types;
import libwasm.lodash;

import std.traits;

nothrow:
@safe:
PGLite PgLite() {
    return PGLite().initArgs(Eval("undefined")); // now
}

PGLite pgliteHandle(Handle handle) {
    return PGLite().initHandle(handle);
}
PGLite pgliteHandle(T)(ref T handle) if (is(T : JsHandle)) {
    return PGLite().initHandle(handle.handle);
}

PGLite PgLite(ARGS...)(auto ref ARGS args) if (ARGS.length > 0) {
    return PGLite().initArgs(args);
}

struct PGLite {
    private Lodash m_ld;
    private Handle m_saved;
    private bool m_dirty;
nothrow:
@safe:
    private PGLite initHandle(Handle h) {
        m_ld = Lodash(h, VarType.handle, 1024);
        return this;
    }

    private PGLite initArgs(ARGS...)(auto ref ARGS args)
    {
        m_ld = Lodash();
        m_ld.defaultTo(Eval("window.pglite"));
        m_ld.attempt(args);
        return this;
    }
     
    Handle save()(bool drop_previous = true) {
        if (m_saved && !m_dirty) return m_saved;
        scope(exit) m_dirty = false;
        if (m_saved && drop_previous) dropHandle!Handle(m_saved);
        m_saved = m_ld.execute!Handle();
        m_ld = Lodash(m_saved, VarType.handle, 1024);
        
        return m_saved;
    }

    JSON query(ARGS...)(string query, auto ref ARGS args) {
        return m_ld.attempt("query", query, args).execute!JSON();
    } 
    

}