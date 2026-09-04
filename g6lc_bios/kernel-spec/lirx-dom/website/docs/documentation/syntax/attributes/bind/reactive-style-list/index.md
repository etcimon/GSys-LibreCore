# Style List

```html
<div
  [style...]="$.styles$"
></div>
```

To define the **style of an element** updated by a [reactive value](/docs/documentation/syntax/reactive-value/) of type `IStylePropertiesMap`, write `[style...]`.

Only the previously received styles are removed, and the new ones added, so it's possible to cumulate this bind with `[style.prop-name]` for example.

It's converted to something similar to this:

```ts
toObservable($.styles$)((styles) => div.setAttribute('style', styles));
```

:::info

When possible, you should prefer the `[style.name]` [syntax](/docs/documentation/syntax/attributes/bind/reactive-style/),
as it tends to be more readable.

:::

## Example

```html
<div
  [style.font-size]="single('14px')"
  [style...]="single(new Map([['line-height', { value: '20px' }]]))"
></div>
```

Output:

```html
<div
  style="font-size: 14px; line-height: 20px"
></div>
```


:::info

To convert a "raw" list of style properties into a `IStylePropertiesMap`, you may use the function [toStylePropertiesMap](/docs/reference/to-style-properties-map/).

:::

---

#### Alternative syntax

```html
<div
  bind-style---="$.styles$"
></div>
```

Instead of using `[style...]` you may write `bind-style---`.
