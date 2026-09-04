<script lang="ts" context="module">
  export function comboOrReady() {
    return true
  }
</script>

<script lang="d">
  bool left = false;
  bool right = true;
  double sy = 0;
  void boom() { }
</script>

<style>
  :global(.wide) { width: 100%; }
</style>

<svelte:window bind:scrollY={sy} on:resize={boom} />
<div class="combo-or">
  {#if left || right}
    <p>Either</p>
  {/if}
  {#await job}
    <p>Wait</p>
  {:then v}
    <p>{v}</p>
  {:catch e}
    <p>{e}</p>
  {/await}
  <slot name="aside">Side</slot>
  <picture>
    <source srcset="a.png" />
    <img alt="pic" src="b.png" />
  </picture>
  <fieldset>
    <legend>Box</legend>
    <meter min="0" max="10"></meter>
    <time datetime="2026-08-14">Aug</time>
  </fieldset>
  <select>
    <optgroup label="G">
      <option>O</option>
    </optgroup>
  </select>
</div>
