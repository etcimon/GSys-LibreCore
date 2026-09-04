<script lang="ts" context="module">
  /** IDE / tsserver. svelte-d attaches this as jsExports. */
  export function lodashReady() {
    return true
  }
</script>

<script lang="d">
  // libwasm Lodash IR — kept as libwasm D, not JS _.
  // Methods are those on struct Lodash in libwasm/source/libwasm/lodash.d.
  // A chain becomes a D value only via execute!T().

  string joinTags(Handle items)
  {
    return Lodash(items, VarType.handle, 256)
      .compact()
      .uniq()
      .map(Eval("String"))
      .join(",")
      .execute!string();
  }

  long countActive(Handle items)
  {
    return Lodash(items, VarType.handle, 256)
      .filter(Eval("{active: true}"))
      .size()
      .execute!long();
  }

  JSON firstOrEmpty(Handle items)
  {
    return Lodash(items, VarType.handle, 256)
      .defaultTo(Eval("[]"))
      .find(Eval("{ok: true}"))
      .execute!JSON();
  }

  JSON hostCall(Handle obj)
  {
    return Lodash(obj, VarType.handle, 256)
      .attempt("toJSON")
      .invoke("valueOf")
      .get("id")
      .execute!JSON();
  }

  string titleCase(string s)
  {
    return Lodash(s, VarType.string_, 128)
      .toLower()
      .trim()
      .execute!string();
  }

  long takeSize(Handle items)
  {
    return Lodash(items, VarType.handle, 256)
      .take(3)
      .size()
      .execute!long();
  }
</script>

<p class="px-4 text-sm opacity-70">libwasm Lodash demo (lang=d)</p>
