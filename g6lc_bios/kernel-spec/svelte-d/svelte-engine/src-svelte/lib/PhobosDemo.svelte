<script lang="ts" context="module">
  export function phobosDemoReady() {
    return true
  }
</script>

<script lang="d">
  // wasm Phobos (spa-phobos / runtime-v1.43.0). Not std.file / std.stdio.
  import std.algorithm : sum;
  import std.conv : to;
  import std.range : iota;

  string label = "0";

  void go()
  {
    try
    {
      auto s = cast(int) iota(1, 5).sum;
      label = to!string(s);
      this.update.label = label;
    }
    catch (Exception)
    {
    }
  }
</script>

<div class="phobos-demo">
  <button type="button" on:click={go}>sum</button>
  <span>{label}</span>
</div>
