<script lang="ts" context="module">
  export function comboWideReady() {
    return true
  }
</script>

<script lang="d">
  bool off = false;
  bool open = false;
  bool paused = false;
  double vol = 0.5;
  int wide = 0;
  void onVis() { }
  void onEnter() { }
  void flip() { this.update.off = !off; }
</script>

<svelte:document on:visibilitychange={onVis} />
<svelte:body on:mouseenter={onEnter} />
<div class="combo-wide">
  <button type="button" on:click={flip}>Flip</button>
  {#if !off}
    <p>Shown</p>
  {/if}
  <math><mi>x</mi></math>
  <dialog bind:open={open}><p>Dlg</p></dialog>
  <audio bind:paused bind:volume={vol}></audio>
  <progress bind:value={wide}></progress>
  <canvas></canvas>
  <iframe src="about:blank"></iframe>
  <my-widget data-k="v"></my-widget>
</div>
