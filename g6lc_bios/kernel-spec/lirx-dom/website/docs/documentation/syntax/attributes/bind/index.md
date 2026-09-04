# Bind

**Bind attributes** are a category of attributes wrapped in square brackets, `[]`,
whose right hand side (the attributes' value) is a [reactive value](/docs/documentation/syntax/reactive-value/) updating the "properties" of the Element (it may update a class, a property, an attribute, etc.).

The syntax looks like this:

```html
<div
  [name]="$.source$"
></div>
```

When the Element is **connected** to the DOM, the reactive value is subscribed,
and its incoming values will mutate the element's properties.
