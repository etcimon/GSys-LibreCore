module jshost;

import libwasm;

nothrow:
@safe:

/// Target emit for IR `MomentCall`. Moment is a Lodash wrap of `window.moment`
/// (`libwasm/source/libwasm/moment.d`). Do not emit `new Date` or TS.
string formatNow(string fmt)
{
  return moment().format(fmt);
}

/// Target emit for IR `JsHostWrap` / `LodashChain` (same shape as `pglite.d`).
/// Chain JS `_` then `execute!T()` — the only way a chain becomes a D value
/// (`lodash.d` `execute`).
JSON lodashOf(Handle h)
{
  return Lodash(h, VarType.handle, 256).execute!JSON();
}
