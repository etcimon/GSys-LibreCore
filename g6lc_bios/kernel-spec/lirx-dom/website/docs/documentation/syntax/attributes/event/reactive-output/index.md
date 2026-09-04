# Output

```html
<my-component
  $(name)="$observer"
></my-component>
```

To listen to values emitted by a **custom element's output**, sent to an `Observer<any>`, write `$(name)`, where `name` is the name of this output.

When the output emits a value, the right-hand side (the Observer) receives this value.

It's converted to something similar to this:

```ts
node.setReactiveOutput('name', $observer);
```

#### Definition of a component's output

A *component's output* is a special property, used to provide some output data or events from a child component to a parent component.
We may think, for example, of an `app-datepicker` component, sending a `selectedDate` Event (of type: `Date`), to it's parent's component, when the user selects a date.


#### Creating an output

Into the component file (`.ts`), the output may be defined like this:

```ts
interface IMyComponentData {
  readonly name: Output<strig>;
}

export const MyComponent = new Component<HTMLElement, IMyComponentData, void>({
  name: 'my-component',
  componentData: (): IMyComponentData => ({
    name: output<string>(),
  }),
  templateData: (node: VirtualCustomElementNode<IMyComponentConfig>): void => {
    const $name = node.$output('name');

    // then we may play with the observer '$name' which reflects the emited data to the output 'name'
    node.on$('click')(() => {
      $name(`user-${Date.now()}`);
    });
  },
});
```

:::note

A component may have many outputs, with different types.

:::

---

#### Alternative syntax

```html
<my-component
  on-output-name="$observer"
></my-component>
```

Instead of using parentheses you may prefix the output's name with `on-output`.


