<script lang="ts" context="module">
  export function comboNextReady() {
    return true
  }
</script>

<script lang="d">
  string props = "x";
  void focus(Handle h) { }
  void attachFn(Handle h) { }
</script>

<div class="combo-next">
  <svelte:element this="section" use:focus transition:fade class="box" {...props}>
    <p>Dyn</p>
  </svelte:element>
  <svelte:fragment>
    <span>Frag</span>
  </svelte:fragment>
  <svelte:component this={ClickField} msg="hi">
    {#snippet children()}
      <em>site</em>
    {/snippet}
  </svelte:component>
  {@attach attachFn}
  <p in:fly out:fade animate:flip>Move</p>
  <svelte:boundary>
    <p>Safe</p>
  </svelte:boundary>
</div>
