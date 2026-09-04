import {
  IVirtualComponentNodeSlotsMap,
} from '../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';

import { IComponentVirtualComponentNode } from './types/component-virtual-component-node.type';
import { VirtualComponentNode } from '../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';

/* CLASS */

export abstract class AbstractComponent<GElement extends Element, GData extends object> {
  readonly #name: string;

  protected constructor(
    name: string,
  ) {
    this.#name = name;
  }

  get name(): string {
    return this.#name;
  }

  abstract create(
    slots?: IVirtualComponentNodeSlotsMap,
  ): IComponentVirtualComponentNode<GElement, GData>;
}

export type IGenericAbstractComponent = AbstractComponent<any, any>;

/** INFER **/

export type InferAbstractComponentGElement<GComponent> =
  GComponent extends AbstractComponent<infer GElement, any>
    ? GElement
    : never;

export type InferAbstractComponentGData<GComponent> =
  GComponent extends AbstractComponent<any, infer GData>
    ? GData
    : never;

export type InferAbstractComponentVirtualComponentNode<GComponent> =
  GComponent extends AbstractComponent<infer GElement, infer GData>
    ? VirtualComponentNode<GElement, GData>
    : never;
