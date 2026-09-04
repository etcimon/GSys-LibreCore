# Event

**Event attributes** are a category of attributes wrapped in curly brackets, `()`,
whose right hand side (the attributes' value) is an Observer receiving values sent by the Element.

The syntax looks like this:

```html
<div
  (name)="observable$"
></div>
```

When the Element is **connected** to the DOM, the *Event* is subscribed,
and its incoming values will be sent to the Observer.
