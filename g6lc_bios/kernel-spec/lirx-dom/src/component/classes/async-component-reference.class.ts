import { AbstractComponent } from './abstract-component.class';
import {
  IVirtualComponentNodeSlotsMap,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { DEFAULT_SLOTS } from './types/slots/default-slots.constant';
import { IComponentVirtualComponentNode } from './types/component-virtual-component-node.type';
import { createNamesMismatchError } from '../errors/create-names-mismatch-error';
import {
  IDefaultNotificationsUnion,
  IObservable,
  fulfilledObservable,
  throwError,
  singleN,
  IFromPromiseFactoryCreatePromiseFunction,
  fromPromiseFactory,
  IFromPromiseFactoryObservableOptions,
} from '@lirx/core';

export type IAsyncComponent<GElement extends Element, GData extends object> = IObservable<IDefaultNotificationsUnion<AbstractComponent<GElement, GData>>>;

export class AsyncComponentReference<GElement extends Element, GData extends object> extends AbstractComponent<GElement, GData> {

  static fromPromiseFactory<GElement extends Element, GData extends object>(
    name: string,
    factory: IFromPromiseFactoryCreatePromiseFunction<AbstractComponent<GElement, GData>>,
    options?: IFromPromiseFactoryObservableOptions,
  ): AsyncComponentReference<GElement, GData> {
    return new AsyncComponentReference<GElement, GData>(
      name,
      fromPromiseFactory<AbstractComponent<GElement, GData>>(factory, options),
    );
  }

  #component: AbstractComponent<GElement, GData> | undefined;
  readonly #component$: IAsyncComponent<GElement, GData>;

  constructor(
    name: string,
    component$: IAsyncComponent<GElement, GData>,
  ) {
    super(name);

    this.#component$ = fulfilledObservable(component$, (component: AbstractComponent<GElement, GData>): IAsyncComponent<GElement, GData> => {
      if (this.#component === void 0) {
        if (component.name === name) {
          this.#component = component;
          return singleN(component);
        } else {
          return throwError(createNamesMismatchError(name, component.name));
        }
      } else if (component === this.#component) {
        return singleN(component);
      } else {
        return throwError(new Error(`The component '${this.name}' received two different references`));
      }
    });
  }

  get component$(): IAsyncComponent<GElement, GData> {
    return this.#component$;
  }

  override create(
    slots: IVirtualComponentNodeSlotsMap = DEFAULT_SLOTS,
  ): IComponentVirtualComponentNode<GElement, GData> {
    if (this.#component === void 0) {
      throw new Error(`The component '${this.name}' is not loaded`);
    } else {
      return this.#component.create(slots);
    }
  }
}
