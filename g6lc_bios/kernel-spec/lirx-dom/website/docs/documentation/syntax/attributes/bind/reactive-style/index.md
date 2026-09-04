# Style

```html
<div
  [style.name]="$.style$"
></div>
```

To set an **element's css style** whose value is updated by a [reactive value](/docs/documentation/syntax/reactive-value/) of type `ISetStylePropertyOrStringOrNull`, write `[style.name]`,
where `name` is the style's property name.

If `null` is received, the property is removed. Else, the property is converted to a string and applied.

It's converted to something similar to this:

```ts
toObservable($.style$)((value) => div.style.setProperty('name', value));
```

## Examples

#### Observable of string

```html
<div
  [style.font-size]="single('14px')"
></div>
```

Output:

```html
<div
  style="font-size: 14px"
></div>
```

#### Observable of IStyleProperty

```html
<div
  [style.color]="single({ value: 'red', priority: 'important')"
></div>
```

Output:

```html
<div
  style="color: red !important"
></div>
```

---

#### Alternative syntax

```html
<div
  bind-style-name="$.style$"
></div>
```

Instead of using square brackets you may prefix the style's property name with `bind-style-`.
