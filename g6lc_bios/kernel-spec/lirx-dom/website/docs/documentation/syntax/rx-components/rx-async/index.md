# rx-async

```html
<rx-async
  expression="observable$"
  pending="templatePending"
  fulfilled="templateFulfilled"
  rejected="templateRejected"
></rx-async>
```

Short syntax:

```html
<rx-async
  expression="observable$"
>
  <div *async-pending>
    ...pendingContent
  </div>
  <div *async-fulfilled>
    ...fulfilledContent
  </div>
  <div *async-rejected>
    ...rejectedContent
  </div>
</rx-async>
```

This is used to display **conditionally** some elements depending on the state of an Observable.
Usually, it serves as a lazy loader for components, or to display loaders when dealing with async data.


Under the hoods, it creates a virtual Node which:

- subscribes to `observable$`
- and injects `templatePending`, `templateFulfilled` or `templateRejected` according to the received notification

:::note

The previously injected template is always removed from the DOM before the new one is appended.

:::

It has the following attributes:

- `expression`: the Observable to listen to
- `pending`: the template to inject until the *expression* hasn't sent any value
- `fulfilled`: the template to inject when the expression sends a `complete` Notification
- `rejected`: the template to inject when the expression sends an `error` Notification

The templates `pending`, `fulfilled` and `rejected` are all optional, but we must provide at least one.

It's converted to something similar to this:

```ts
new VirtualReactiveAsyncNode(
  observable$,
  templatePending,
  templateFulfilled,
  templateRejected,
).attach(parentNode);
```

It's possible to retrieve the received value or error through the template variable `value`:

```html
<rx-template
  name="fulfilled"
  let-value
>
  Fulfilled: {{ value }}
</rx-template>
```

```html
<rx-template
  name="rejected"
  let-value="error"
>
  Rejected: {{ error.message }}
</rx-template>
```


## Example

```html
<rx-async expression="singleWithNotification('Hello world !')">
  <div *async-pending>
    Pending...
  </div>
  <div *async-fulfilled="value">
    Fulfilled with: {{ value }}
  </div>
  <div *async-rejected="error">
    Rejected with: {{ error.message }}
  </div>
</rx-async>
```

Output:

```html
<div>
  Fulfilled with: Hello world !
</div>
```

---

**[Example file](https://github.com/lirx-js/dom-examples/tree/main/src/syntax/rx-async/component/rx-async-example.component.ts)**


### Alternative syntaxes

##### Using *async

```html
<tag-mame
  *async="observable$"
  ...otherAttributes
>
  ...content
</tag-mame>
```

<details>
  <summary>Which is equivalent to</summary>

```html

<rx-template
  name="uuid"
>
  <tag-mame
    ...otherAttributes
  >
    ...content
  </tag-mame>
</rx-template>

<rx-async
  expressiom="observable$"
  fulfilled="uuid"
></rx-async>
```

</details>

##### Using rx-async-pending, rx-async-fulfilled and rx-async-rejected with in-place template

```html
<rx-async
  expression="observable$"
>
  <rx-async-pending>
    ...pendingContent
  </rx-async-pending>
  <rx-async-fulfilled let-value>
    ...fulfilledContent
  </rx-async-fulfilled>
  <rx-async-rejected let-value="error">
    ...rejectedContent
  </rx-async-rejected>
</rx-async>
```

##### Using \*async-pending, \*async-fulfilled and \*async-rejected

```html
<rx-async
  expression="observable$"
>
  <div *async-pending>
    ...pendingContent
  </div>
  <div *async-fulfilled="value">
    ...fulfilledContent
  </div>
  <div *async-rejected="error">
    ...rejectedContent
  </div>
</rx-async>
```
