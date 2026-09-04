# EventListener

```html
<div
  (name)="$observer"
></div>
```

To **listen to events** emitted by an element, sent to an `Observer<Event>`, write `(name)`, where `name` is the type of this Event.

It's converted to something similar to this:

```ts
node.addEventListener('name', $observer);
```


## Example

```html
<div
  (click)="(event) => console.log(event)"
></div>
```

when the user clicks on the div -> output:

```text
MouseEvent
```

---

#### Alternative syntax

```html
<div
  on-click="$observer"
></div>
```

Instead of using parentheses you may prefix the event's type with `on-`.


