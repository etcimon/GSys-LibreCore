# Reactive Programming

Before going any further, you have to notice that `@lirx/dom` is a
**[Reactive Programming](https://core.lirx.org/docs/documentation/getting-started/reactive-programming/) based framework**.
Consequently, I strongly encourage you to read the documentation of [@lirx/core](https://core.lirx.org/) before.
This is a necessary step, if you want to understand how this framework works, and why it is so powerful.

In a few words, in the Reactive Programming world, **everything is a stream**.
These variables are called [Signals](https://core.lirx.org/docs/documentation/signals/introduction) and [Observables](https://core.lirx.org/docs/documentation/observables/what-is-an-observable/#definition-of-an-observable),
and will mutate over time. It may happen due to user interactions, api results, async tasks, timers, events, or any origin we prefer.

Then, we will combine them through **data pipelines**.
At that moment, the framework will automatically use the resulting Observables to manipulate the DOM in a very efficient manner:
*only the absolute minimal and optimized UI update is performed*.

As an example, if an event ends in the update of a Text node, then only this Text node will be updated.
There is no Virtual DOM re-rendering involved, no differ algorithm, and zero heavy computation:
**the framework takes care to compile and optimize everything upstream**,
guaranteeing optimal performances and robust applications.

> The drawback of these performances ? 

Well, learning Reactive Programming [is not an easy task](https://dev.to/mfcodeworks/comment/11agc), and it may discourage easily the new incomers.
It takes time to master, and requires to think very differently as everything is async.
They are truly similar to the Promises on their time: a completely new approach, but something we can't do without now.

In conclusion, this is an extremely powerful tool, and if you want to create really performants applications, then they are the way to go 👑.

### A few words about the other frameworks

We may notice than all the current frameworks try to **transition to a reactive model**: with the introduction of signal for example. 
This means that `@lirx/dom` took the right direction, and was built especially for this paradigm.
For example, `signals` natively exists and works immediately with this framework.

#### Coming from React ?

If you are a React developer, actually, you've already played with something very close to an Observable: the function `useState` is similar to a [Source](https://core.lirx.org/docs/documentation/getting-started/what-is-a-source/#let).

You set the state, and then, the DOM is updated. Well, `@lirx/dom` uses a similar pattern, but much more refined and precise, where only the relevant node is updated, instead of the whole Virtual DOM.

#### Coming from Angular ?

If you are an angular developer, you've probably already played with the Observables through the library: [RxJS](https://rxjs.dev/).
Typically, you'll use them, when you have to perform an HTTP request, send an event (`@Output` and `EventEmitter`), use the `async` pipe, or having some *Stores*.
Moreover, Angular recently introduced `signals` so you may start to play with them.

Well, `@lirx/dom` was build from scratch for Observables and signals. This gives it a very important performance boost, with a design natively and naturally working with them.



