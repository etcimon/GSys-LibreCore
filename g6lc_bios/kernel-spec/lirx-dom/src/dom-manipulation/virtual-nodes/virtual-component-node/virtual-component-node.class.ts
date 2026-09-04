import { HTML_NAMESPACE_URI_CONSTANT } from '../../misc/namespace-uri/html-namespace-uri.constant';
import { VirtualReactiveElementNode } from '../virtual-reactive-element-node/virtual-reactive-element-node.class';
import { IVirtualComponentNodeSlotsMap } from './types/slots/virtual-component-node-slots-map.type';
import { IVirtualComponentNodeOptions } from './types/options/virtual-component-node-options.type';
import { IUnsubscribe } from '@lirx/unsubscribe';
import { subscribeToObservableUsingAnObservableOfObserver, IObservable, IObserver } from '@lirx/core';
import { InferDataOutputValue, InferDataOutputKeys, InferDataOutputs } from './data/outputs/infer-data-outputs.type';
import { InferDataInputGetValue, InferDataInputKeys, InferDataInputs, InferDataInputSetValue } from './data/inputs/infer-data-inputs.type';

/**
 * Represents an instance of a Component.
 * It has:
 * - a name
 * - some slots
 * - and some 'data'
 */
export class VirtualComponentNode<GElement extends Element, GData extends object> extends VirtualReactiveElementNode<GElement> {
  readonly #name: string;
  readonly #extends: string | undefined;
  readonly #slots: IVirtualComponentNodeSlotsMap;

  readonly #data: GData;

  constructor(
    {
      name,
      extends: _extends,
      namespaceURI = HTML_NAMESPACE_URI_CONSTANT,
      slots,
      data,
    }: IVirtualComponentNodeOptions<GData>,
  ) {
    super(
      namespaceURI,
      (_extends === void 0)
        ? name
        : _extends,
    );
    this.#name = name;
    this.#extends = _extends;
    this.#slots = slots;
    this.#data = data;

    if (_extends !== void 0) {
      this.setAttribute('is', name);
    }
  }

  get name(): string {
    return this.#name;
  }

  get extends(): string | undefined {
    return this.#extends;
  }

  get slots(): IVirtualComponentNodeSlotsMap {
    return this.#slots;
  }

  get data(): GData {
    return this.#data;
  }

  /* INPUTS */

  get inputs(): InferDataInputs<GData> {
    return this.#data as InferDataInputs<GData>;
  }

  inputValue<GKey extends InferDataInputKeys<GData>>(
    key: GKey,
  ): InferDataInputGetValue<GData[GKey]> {
    return this.inputs[key].value;
  }

  input$<GKey extends InferDataInputKeys<GData>>(
    key: GKey,
  ): IObservable<InferDataInputGetValue<GData[GKey]>> {
    return this.inputs[key].subscribe;
  }

  $input<GKey extends InferDataInputKeys<GData>>(
    key: GKey,
  ): IObserver<InferDataInputSetValue<GData[GKey]>> {
    return this.inputs[key].emit;
  }

  bindInputWithObservable<GKey extends InferDataInputKeys<GData>>(
    key: GKey,
    value$: IObservable<InferDataInputSetValue<GData[GKey]>>,
  ): IUnsubscribe {
    return this.onConnected((): IUnsubscribe => {
      return value$(this.$input<GKey>(key));
    });
  }

  /* OUTPUTS */

  get outputs(): InferDataOutputs<GData> {
    return this.#data as InferDataOutputs<GData>;
  }

  output$<GKey extends InferDataOutputKeys<GData>>(
    key: GKey,
  ): IObservable<InferDataOutputValue<GData[GKey]>> {
    return this.outputs[key].subscribe;
  }

  $output<GKey extends InferDataOutputKeys<GData>>(
    key: GKey,
  ): IObserver<InferDataOutputValue<GData[GKey]>> {
    return this.outputs[key].emit;
  }

  bindOutputWithObserver<GKey extends InferDataOutputKeys<GData>>(
    key: GKey,
    $value: IObserver<InferDataOutputValue<GData[GKey]>>,
  ): IUnsubscribe {
    return this.onConnected((): IUnsubscribe => {
      return this.output$<GKey>(key)($value);
    });
  }

  bindOutputWithObservableOfObserver<GKey extends InferDataOutputKeys<GData>>(
    key: GKey,
    $value: IObservable<IObserver<InferDataOutputValue<GData[GKey]>>>,
  ): IUnsubscribe {
    return this.onConnected((): IUnsubscribe => {
      return subscribeToObservableUsingAnObservableOfObserver<any>(
        this.output$<GKey>(key),
        $value,
      );
    });
  }
}

/*-------------------*/

/*-------------------*/

// interface TestConfig {
//   element: HTMLButtonElement;
//   inputs:
//     | ['i-a', boolean]
//     | ['o-a', number]
//     | ['o-b', string]
//   ,
// }
//
// const a = new VirtualComponentNode({
//   name: 'test',
//   slots: new Map(),
//   data: [
//     ['i-a', true],
//     'o-b',
//     ['o-a'],
//   ],
// });

// const a = new VirtualComponentNode({
//   name: 'test',
//   slots: new Map(),
//   data: {
//     a: signal(6),
//     b: input(6),
//     c: '',
//   },
// });
//
// const h = a.inputs.b;
// const g = a.input$('b');
//
// const h = a.outputs.b;
// //
// // a.properties.get('i-a');
// // a.properties.set('o-a', 4);
// //
// a.bindDataObserverWithObservable('a', single(8));
// // a.bindOutputWithObserver('a', (_: string) => {});
// // a.setReactiveOutput('i-a', (value: boolean) => {})
// // a.setReactiveOutput('o-a', (value: number) => {})
