# Introduction

`@lirx/dom` is **extremely performant** as it focuses on updating only what is relevant and nothing more,
running everytime the minimal javascript as possible.

Moreover, its [AOT compiler](/docs/documentation/aot-compiler/) allows optimizations while building the app, and generates smaller and faster builds.

This is **ideal for small to large applications** running in the browser where performances matter (ex: PWA).

In the following sections, we'll explore how `@lirx/dom` is different from its concurrents, and how it performs against them.

---

:::note

To compare the different frameworks, we've created the same application multiple times using the different technologies.

Each time we took the recommandations and best practices of the benchmarked framework, and tried to optimize as much as possible in order to have a fair comparison.

:::

:::note

Note that the benchmarks are not exhaustive. They won't cover every possible scenario, and results may vary according to your own applications and computers.
However, you will quickly see that `@lirx/dom` does not lie on its promises: it was done to be fast, and it really is !

:::

---
