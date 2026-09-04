# Input

```html
<my-component
  $[name]="$.input$"
></my-component>
```

To set a **custom element's input** whose value is updated by a [reactive value](/docs/documentation/syntax/reactive-value/), write `$[name]`, where `name` is the name of this input.

When the right-hand side (the reactive value) emits a value, the input is set with this value. 

It's converted to something similar to this:

```ts
node.bindInputWithObservable('name', $.input$);
```

#### Definition of a component's input

A *component's input* is a special property, used to provide some input data from a parent component to a child component.
We may think, for example, of a `app-progress` component, requiring a `progress` input (of type: `number`), to display a proportional progress bar.


#### Creating an input

Into the component file (`.ts`), the input may be defined like this:

```ts
interface IMyComponentData {
  readonly name: Input<string>;
}

export const MyComponent = new Component<HTMLElement, IMyComponentData, void>({
  name: 'my-component',
  componentData: (): IMyComponentData => ({
    name: input<string>(),
  }),
  templateData: (node: VirtualCustomElementNode<HTMLElement, IMyComponentData>): void => {
    const name$ = node.input$('name');
    
    // then we may play with the observable 'name$' which reflects the data sent to the input 'name'
    name$((name: string) => {
      console.log('name', name);
    });
  },
});
```

:::note

A component may have many inputs, with different types and optional default values.

:::

---

#### Alternative syntax

```html
<my-component
  bind-input-name="$.input$"
></my-element>
```

Instead of using square brackets you may prefix the input's name with `bind-input-`.

