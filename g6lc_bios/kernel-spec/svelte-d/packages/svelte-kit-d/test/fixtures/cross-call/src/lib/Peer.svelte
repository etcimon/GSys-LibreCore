<script lang="d">
  import lib.Bridge : greet;

  string note = "";
  void copy() { this.update.note = greet("Peer"); }
</script>

<div class="peer">
  <button type="button" on:click={copy}>Copy</button>
  <span>{note}</span>
</div>
