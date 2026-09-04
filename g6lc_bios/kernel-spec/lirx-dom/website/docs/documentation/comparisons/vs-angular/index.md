# Differences with Angular

Angular is based on [Zones](https://angular.io/guide/zone).

A Zone, is a context, in which sync and async tasks keep the same context.
This mechanism is used by Angular to refresh the DOM tree when a Zone runs for a specific component.
If an sync or async task appends in the context of the component, it is refreshed:
its properties are reflected on the DOM, and its children may be updated too depending on their change detection strategy.

This design permits to update only the relevant Nodes, without the necessity to update all the component's Elements.
Thus, it is pretty efficient.

However, it has some drawbacks:

- Angular itself is heavy (usually around 50Kb minzipped)
- It includes ZoneJS which patches every async functions, and cannot support async/await (meaning de-optimized code transpilation)
- When a Zone triggers, all expressions in the html are evaluated and reflected on the nodes, even if we changed only one property.

In a few words, Angular is powerful, but massive: we can see it in its generated bundles, where their sizes are often larger that the concurrent frameworks.

### Reactive Programming

Angular uses [RxJS](https://angular.io/guide/rx-library) as a Reactive Programming library: for the `http` module or the `@Output()` decorator for example.
It encourages its usage, but do not constrain it. In consequence, most of the developers simply avoid Observables due to their important learning curve.
It's a shame because Observables are really powerful, and, if well-used, may strongly increase the performance of the application, especially when changing the [ChangeDetectionStrategy](https://angular.io/api/core/ChangeDetectionStrategy).

**They are so powerful**, that `@lirx/dom` just made them **mandatory** and are the roots of the framework.

Actually, if we were using Angular without ZoneJS and with only `OnPush` change detection strategies, we'll have something really similar to `@lirx/dom`.
In this case, `@lirx/dom` will win only because it has been fully developed and optimized for Observables, resulting in a lighter footprint (in memory, CPU, and bundle size).
Moreover, working exclusively with Observables, permits strong optimizations, with extremely precise updates, where just the relevant Nodes are updated.

### Templates and styling

`@lirx/dom` uses templates with a syntax close to the Angular one.
This way, if you are coming from Angular, templates will feel familiar.
The same is true for the style of your components, and the structure of your files and project.
Both are MVC frameworks and have in common some architecture designs.

In consequence, if you are an Angular developer, using `@lirx/dom` should probably be easier.
The hardest part will come from the pure Reactive Programming aspect.

