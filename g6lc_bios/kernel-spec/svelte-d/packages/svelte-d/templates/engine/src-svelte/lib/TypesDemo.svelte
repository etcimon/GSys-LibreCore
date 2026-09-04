<script lang="ts" context="module">
  export function typesReady() {
    return true
  }
</script>

<script lang="d">
  // libwasm.types — Handle, Eval, JsHandle, JSON, VarType.

  Handle rootHandle()
  {
    return cast(Handle) 1;
  }

  Eval undef()
  {
    return Eval("undefined");
  }

  JSON wrapJson(Handle h)
  {
    return JSON(h);
  }

  VarType handleTy()
  {
    return VarType.handle;
  }

  JsHandle windowJs()
  {
    return JsHandle(2);
  }
</script>

<p class="px-4 text-sm opacity-70">libwasm types demo (lang=d)</p>
