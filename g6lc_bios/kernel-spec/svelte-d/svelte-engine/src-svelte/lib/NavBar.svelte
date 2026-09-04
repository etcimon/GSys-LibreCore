<script lang="ts" context="module">
  export function navBarReady() {
    return true
  }
</script>

<script lang="d">
  // Live chrome. Handwritten src-d/navbar.d stays the EH/PgLite golden.
  import pglite;

  string logo = "PsxAI";
  bool open = false;
  void toggle() { this.update.open = !open; }

  void onItem1() { console.log("Clicked: Item 1"); }
  void onItem2() { console.log("Clicked: Item 2"); }

  void onBtn()
  {
    try
    {
      throw new Exception("svelte-engine-eh");
    }
    catch (Exception e)
    {
      console.log(e.msg);
    }
    JSON res = PgLite().query("SELECT 1");
    console.log(res);
  }
</script>

<div class="navbar bg-base-100 shadow-sm">
  <div class="navbar-start">
    <button type="button" class="btn btn-ghost burger" on:click={toggle}>Menu</button>
    {#if open}
      <div class="burger-menu">
        {#each links as link}
          <li class="nav-link">{link}</li>
        {/each}
      </div>
    {/if}
    <a class="btn btn-ghost text-xl">{logo}</a>
  </div>
  <div class="navbar-center hidden lg:flex">
    <ul class="menu menu-horizontal px-1">
      <li><a on:click={onItem1}>Item 1</a></li>
      <li><a on:click={onItem2}>Item 2</a></li>
    </ul>
  </div>
  <div class="navbar-end">
    <a class="btn end-btn" on:click={onBtn}>Button</a>
  </div>
</div>
