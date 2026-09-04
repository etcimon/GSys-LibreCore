<script lang="ts" context="module">
  export function comboSurfReady() {
    return true
  }
</script>

<script lang="d">
  bool on = false;
  string tone = "navy";
  string tag = "article";
  string rest = "data-k=v";
  Handle extra;
  void ping() { this.update.on = !on; }
  void focus(Handle h) { }
  void trip() { throwBoundary("boom"); }
  void reset() { resetBoundary(); }
  void oops(string e) { }
</script>

<div class="combo-surf">
  <button type="button" class="surf-ping" on:click|once={ping}>Ping</button>
  <button type="button" class="surf-trip" on:click={trip}>Trip</button>
  <span class="dir-on" class:on={on}>on</span>
  <div class="dir-style"><p style:color={tone}>Paint</p></div>
  <div class="dir-spread" {...rest} {...extra}>Spread</div>
  <section class="dir-use" use:focus>Use</section>
  <svelte:element this="section" class="spec-static">
    <span class="spec-static-kid">Stat</span>
  </svelte:element>
  <svelte:element this={tag} class="spec-dyn">
    <span class="spec-dyn-kid">Dyn</span>
  </svelte:element>
  <svelte:fragment>
    <span class="spec-frag">Frag</span>
  </svelte:fragment>
  <svelte:component this={ClickField} msg="hi" />
  <svelte:boundary onerror={oops}>
    {#snippet failed(error, reset)}
      <p class="bound-fail">{error}</p>
      <button type="button" class="bound-retry" on:click={reset}>Retry</button>
    {/snippet}
    <p class="bound-ok">Ok</p>
  </svelte:boundary>
</div>
