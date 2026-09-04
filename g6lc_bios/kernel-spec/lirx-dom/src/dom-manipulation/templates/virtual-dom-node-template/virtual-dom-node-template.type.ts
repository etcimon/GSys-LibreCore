import { VirtualDOMNode } from '../../virtual-nodes/virtual-dom-node/virtual-dom-node.class';

export interface IVirtualDOMNodeTemplate<GArguments extends any[]> {
  (
    parentNode: VirtualDOMNode,
    ...args: GArguments
  ): void;
}

