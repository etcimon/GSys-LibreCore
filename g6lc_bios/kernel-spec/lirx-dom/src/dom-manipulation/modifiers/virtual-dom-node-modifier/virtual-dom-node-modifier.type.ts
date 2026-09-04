import { VirtualDOMNode } from '../../virtual-nodes/virtual-dom-node/virtual-dom-node.class';

export interface IVirtualDOMNodeModifierFunction<GValue, GNode extends VirtualDOMNode> {
  (
    node: VirtualDOMNode,
    value: GValue,
  ): GNode;
}

export interface IVirtualDOMNodeModifier<GValue, GNode extends VirtualDOMNode> {
  readonly name: string;
  readonly apply: IVirtualDOMNodeModifierFunction<GValue, GNode>;
  readonly weight: number;
}

export type IGenericVirtualDOMNodeModifier = IVirtualDOMNodeModifier<any, any>;
