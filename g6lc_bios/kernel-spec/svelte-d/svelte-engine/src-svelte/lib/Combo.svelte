<script lang="ts" context="module">
  export function comboReady() {
    return true
  }
</script>

<script lang="d">
  bool show = true;
  bool other = false;
  bool on = false;
  string tone = "navy";
  string raw = "<i>z</i>";
  JsPromise!Any job;
  void go() { this.update.await_then = true; }
</script>

<div class="combo">
  {#if show}
    <p>Shown</p>
    {@html raw}
    {#each items as item, i}
      <li class:on={on} title="row">{item}</li>
    {:else}
      <p>Empty</p>
    {/each}
  {:else if other}
    <p>Other</p>
  {:else}
    <slot>fallback</slot>
  {/if}
  <button type="button" class="go" on:click={go}>Go</button>
  {#await job}
    <p>Wait</p>
  {:then v}
    <p>Done</p>
  {:catch e}
    <p>Err</p>
  {/await}
  <ClickField msg="hi" />
  <input bind:value={tone} class:on={on} id={tone} name="n" />
</div>
