<script lang="ts" context="module">
  export function panelReady() {
    return true
  }
  export const jsExports = {
    env: {
      panelReady: () => panelReady(),
    },
  }
</script>

<script lang="d">
  string title = "Panel";
  bool on = true;
  void finish() { this.emit(done); }
</script>

<div class="panel">
  <h2>{title}</h2>
  <slot>fallback</slot>
  <button type="button" on:click={finish}>Ok</button>
  <input bind:value={title} class:on />
</div>
