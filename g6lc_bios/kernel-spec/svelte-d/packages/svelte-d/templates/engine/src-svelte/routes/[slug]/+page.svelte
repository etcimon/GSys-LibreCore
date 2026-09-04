<script lang="ts" context="module">
  export function slugReady(slug: string) {
    return slug
  }
</script>

<script lang="d">
  // SvelteKit [slug] → libwasm URLRouter ":slug" (router.d max 64 params).
  // Layouts stay @child; this page is an entering callback, not a 2nd wasm.

  @entering!"/:slug"
  Optional!(Promise!void) enterSlug(ref RouterEvent ev)
  {
    auto id = ev.parameters["slug"];
    router().setTitle(id);
    return typeof(return).init;
  }

  void goPath(string path)
  {
    router().navigateTo(path);
  }

  void setKitBase()
  {
    router().setBasePath("");
  }
</script>

<section class="p-4">
  <p>kit param [slug] → libwasm :slug</p>
</section>
