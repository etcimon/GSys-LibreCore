<script lang="ts" context="module">
  export function comboMediaReady() {
    return true
  }
</script>

<script lang="d">
  string lab = "play";
  string href = "#";
  string src = "x.mp4";
  bool off = false;
  bool paused = true;
  bool muted = true;
  void hit() { }
  void trip() { throwBoundary("boom"); }
  void reset() { resetBoundary(); }
  void oops(string e) { }
</script>

<div class="combo-media">
  <svg viewBox="0 0 10 10">
    <circle cx="5" cy="5" r="4" />
  </svg>
  <video src={src} bind:paused bind:muted></video>
  <a href={href} aria-label={lab}>Go</a>
  <button type="button" disabled={off} on:click|self|trusted={hit}>Hit</button>
  <button type="button" class="trip" on:click={trip}>Trip</button>
  <button type="button" class="reset" on:click={reset}>Reset</button>
  <img alt="pic" src="x.png" />
  <svelte:boundary onerror={oops}>
    {#snippet failed(error, reset)}
      <p class="fail-msg">{error}</p>
      <button type="button" class="retry" on:click={reset}>Retry</button>
    {/snippet}
    <p>Ok</p>
  </svelte:boundary>
</div>
