import { VirtualDOMNode } from '../../virtual-nodes/virtual-dom-node/virtual-dom-node.class';
import {
  IGenericVirtualReactiveElementNode,
} from '../../virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';

export interface IVirtualReactiveElementNodeModifierFunction<GValue, GNode extends VirtualDOMNode> {
  (
    node: IGenericVirtualReactiveElementNode,
    value: GValue,
  ): GNode;
}
