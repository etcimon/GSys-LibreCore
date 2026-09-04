# Reactive value

First, we'll define what is a `reactive value`. But keep in mind that it is just a definition, not an implementation.
The purpose is to use a common term across this documentation.

A `reactive value` is **a value able to change over time**.
Such a value is usually **bound to the DOM**, and if it changes, reflected on it.
For example, we may update the value of a `Text` node, depending on a `reactive value`.

Let's give some examples of reactive values and how to use them:

### Static value

A static value like `1` or `'Hello world !'` is a special kind of reactive value.
It's a reactive value being constant:

```html
<div>
  {{ 'Hello world !' }}
</div>
```

Output:


```html
<div>
  Hello world !
</div>
```

It may sometimes be useful when giving static data to child components:

```html
<app-child $[count]="5"></app-child>
```

Here `5` is our constant reactive value.

### Observable

[Observables](https://core.lirx.org/docs/documentation/getting-started/what-is-an-observable/) are our **main** reactive value sources, as they are the fundamental brick of **Reactive Programming**.
As an example, let's create an Observable sending the current date every second:

```ts
const date$ = map$$(interval(1000), () => new Date().toString());
```

Now, we may use it in our template:

```html
<div>
  {{ $.date$ }}
</div>
```

Just like that, the text present in the &ltdiv&gt will be updated every second with the current date.


### Signal

[Signals](https://core.lirx.org/docs/documentation/signals/introduction/) are another important source of reactive value, and an alternative of Observables.
Let's re-write the previous example using signals:

```ts
const date = signal('');
setTimeout(() => {
  date.set(new Date().toString());
}, 1000);
```

We may use it directly in our template, were the &ltdiv&gt's content will be updated automatically:

```html
<div>
  {{ $.date }}
</div>
```

#### Computed

Finally, it's frequent to `compute` values directly from our template instead of the associated `typescript` file.

In this situation, we may use the `=> expression` syntax:

```
computed-signal-reactive-value = *WSP "=>" *WSP expression
```

Which is converted to:

```ts
computed(() => expression)
```

Here's an example of a &ltdiv&gt displayed only if `count` is greater than 2

```ts
const count = signal(0);
setTimeout(() => {
  count.set(count() + 1);
}, 1000);
```

```html
<div *if="=> $.count() > 2">
  {{ $.count }}
</div>
```

