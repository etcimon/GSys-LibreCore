# Attribute

```html
<div
  [attr.name]="$.attr$"
></div>
```

To set an **element's attribute** whose value is updated by a [reactive value](/docs/documentation/syntax/reactive-value/) of type `string | boolean | null`, write `[attr.name]`,
where `name` is the name of the attribute.

If `null` or `false` is received, the attribute is removed. 
Else, if it's `true`, then the attribute is set with an empty string value.
Finally, if a `string` is received, the attribute is set to this value.

It's converted to something similar to this:

```ts
toObservable($.attr$)((value) => div.setAttribute('name', value));
```

# Example

```html
<div
  [attr.aria-label]="single('my-label')"
></div>
```

Output:

```html
<div
  aria-label="my-label"
></div>
```

---

#### Alternative syntax

```html
<div
  bind-attr-name="$.attr$"
></div>
```

Instead of using square brackets you may prefix the attribute name with `bind-attr-`.
