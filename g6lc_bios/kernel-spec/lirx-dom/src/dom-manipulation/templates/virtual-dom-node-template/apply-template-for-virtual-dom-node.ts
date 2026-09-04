import { VirtualContainerNode } from '../../virtual-nodes/virtual-container-node/virtual-container-node.class';
import { VirtualDOMNode } from '../../virtual-nodes/virtual-dom-node/virtual-dom-node.class';
import { IVirtualDOMNodeTemplate } from './virtual-dom-node-template.type';

export function applyTemplateForVirtualDOMNode<GArguments extends any[]>(
  parentNode: VirtualDOMNode,
  template: IVirtualDOMNodeTemplate<GArguments>,
  args: GArguments,
  allowBatch: boolean = true,
): void {
  if (parentNode.isConnected && allowBatch) { // batch append child nodes to increase performances
    const container: VirtualContainerNode = new VirtualContainerNode();
    template(container, ...args);
    container.attach(parentNode);
  } else {
    template(parentNode, ...args);
  }
}

