import { VirtualComponentNode } from '../../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';

export type IComponentVirtualComponentNode<GElement extends Element, GData extends object> =
  VirtualComponentNode<GElement, Readonly<GData>>
  ;
