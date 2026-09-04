<script lang="ts" context="module">
  export function listEventsReady() {
    return true
  }
</script>

<script lang="d">
  string last = "";
  void pick(string name) { this.update.last = name; }
</script>

<section class="list-events">
  <p>{last}</p>
  <ul>
    {#each items as item}
      <li on:click={pick}>{item}</li>
    {:else}
      <p>Empty</p>
    {/each}
  </ul>
</section>
