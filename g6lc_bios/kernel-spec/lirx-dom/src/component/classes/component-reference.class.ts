import { AbstractComponent } from './abstract-component.class';
import {
  IVirtualComponentNodeSlotsMap,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { DEFAULT_SLOTS } from './types/slots/default-slots.constant';
import { IComponentVirtualComponentNode } from './types/component-virtual-component-node.type';
import { createNamesMismatchError } from '../errors/create-names-mismatch-error';

export class ComponentReference<GElement extends Element, GData extends object> extends AbstractComponent<GElement, GData> {
  readonly #getComponent: () => AbstractComponent<GElement, GData>;

  constructor(
    name: string,
    getComponent: () => AbstractComponent<GElement, GData>,
  ) {
    super(name);

    this.#getComponent = getComponent;
  }

  override create(
    slots: IVirtualComponentNodeSlotsMap = DEFAULT_SLOTS,
  ): IComponentVirtualComponentNode<GElement, GData> {
    const component: AbstractComponent<GElement, GData> = this.#getComponent();
    if (component.name === this.name) {
      return component.create(slots);
    } else {
      throw createNamesMismatchError(this.name, component.name);
    }
  }
}
