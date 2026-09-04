<script lang="ts" context="module">
  export function clickFieldReady() {
    return true
  }
</script>

<script lang="d">
  string msg = "idle";
  void go() { this.update.msg = "clicked"; }
  void onMount() { }
  void onUnmount() { }
</script>

<div class="click-field">
  <button type="button" on:click={go}>Go</button>
  <span>{msg}</span>
</div>
