import { IGenericVirtualElementNode } from '../../dom-manipulation/virtual-nodes/virtual-element-node/generic-virtual-element-node.type';

export interface IComponentStyle {
  (
    node: IGenericVirtualElementNode,
  ): void;
}
