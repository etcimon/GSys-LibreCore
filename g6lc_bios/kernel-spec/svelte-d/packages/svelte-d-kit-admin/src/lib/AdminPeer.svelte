<script lang="d">
  import lib.AdminBridge : label;

  string note = "";
  void copy() { this.update.note = label("Peer"); }
</script>

<div class="admin-peer">
  <button type="button" on:click={copy}>Copy</button>
  <span>{note}</span>
</div>
