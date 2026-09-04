import {
  IVirtualComponentNodeSlotsMap,
} from '../../../dom-manipulation/virtual-nodes/virtual-component-node/types/slots/virtual-component-node-slots-map.type';
import { VirtualComponentNode } from '../../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';

export interface ICreateCustomElementFunction<GElement extends Element, GData extends object> {
  (
    name: string,
    slots?: IVirtualComponentNodeSlotsMap,
  ): VirtualComponentNode<GElement, GData>;
}

export type IGenericCreateCustomElementFunction = ICreateCustomElementFunction<any, any>;
