<script lang="ts">
  export function pagePing(n: number = 1): number {
    return n + 1
  }
</script>

<script lang="d">
  int n = 0;
  void bump() { this.update.n = cast(int) pagePing(); }
</script>

<div class="page">
  <button type="button" on:click={bump}>Bump</button>
  <span>{n}</span>
</div>
