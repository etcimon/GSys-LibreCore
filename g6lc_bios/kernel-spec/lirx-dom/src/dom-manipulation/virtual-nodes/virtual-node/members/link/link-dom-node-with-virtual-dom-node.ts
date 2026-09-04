import { VirtualDOMNode } from '../../../virtual-dom-node/virtual-dom-node.class';

const DOM_NODE_TO_DOM_VIRTUAL_NODE_MAP = new WeakMap<Node, VirtualDOMNode>();

export function linkDOMNodeWithVirtualDOMNode(
  domNode: Node,
  virtualDOMNode: VirtualDOMNode,
): void {
  if (DOM_NODE_TO_DOM_VIRTUAL_NODE_MAP.has(domNode)) {
    throw new Error(`Node already linked to another VirtualDOMNode`);
  } else {
    DOM_NODE_TO_DOM_VIRTUAL_NODE_MAP.set(domNode, virtualDOMNode);
  }
}

export function unlinkDOMNodeWithVirtualDOMNode(
  domNode: Node,
): void {
  DOM_NODE_TO_DOM_VIRTUAL_NODE_MAP.delete(domNode);
}

export function getLinkedVirtualDOMNodeOfDOMNode(
  domNode: Node,
): VirtualDOMNode | null {
  return DOM_NODE_TO_DOM_VIRTUAL_NODE_MAP.get(domNode) ?? null;
}

export function getLinkedVirtualDOMNodeOfDOMNodeOrThrow(
  domNode: Node,
): VirtualDOMNode {
  const virtualDOMNode: VirtualDOMNode | null = getLinkedVirtualDOMNodeOfDOMNode(domNode);
  if (virtualDOMNode === null) {
    throw new Error(`Not linked with a VirtualDOMNode`);
  } else {
    return virtualDOMNode;
  }
}

// TODO debug only
// (globalThis as any).node = getLinkedVirtualDOMNodeOfDOMNodeOrThrow;
