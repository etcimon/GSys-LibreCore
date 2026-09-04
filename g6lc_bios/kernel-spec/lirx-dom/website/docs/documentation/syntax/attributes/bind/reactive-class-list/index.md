# Class List

```html
<div
  [class...]="$.classNames$"
></div>
```

To define the **css classes of an element** updated by a [reactive value](/docs/documentation/syntax/reactive-value/) of type `Set<string>`, write `[class...]`.

Only the previously received classes are removed, and the new ones added, so it's possible to cumulate this bind with `[class.my-class]` for example.

It's converted to something similar to this:

```ts
toObservable(classNames$)((classNames) => div.className = Array.from(classNames).join(' '));
```

:::info

When possible, you should prefer the `[class.name]` [syntax](/docs/documentation/syntax/attributes/bind/reactive-class/),
as it tends to be more readable.

:::

## Example

```html
<div
  [class.enabled]="single(true)"
  [class...]="single(new Set('a', 'b', 'c'))"
></div>
```

Output:

```html
<div
  class="enabled a b c"
></div>
```

:::info

To convert a "raw" list of class names into a Set of string, you may use the function [toClassNamesList](/docs/reference/to-class-names-list/).

:::

---

#### Alternative syntax

```html
<div
  bind-class---="$.classNames$"
></div>
```

Instead of using `[class...]` you may write `bind-class---`.
