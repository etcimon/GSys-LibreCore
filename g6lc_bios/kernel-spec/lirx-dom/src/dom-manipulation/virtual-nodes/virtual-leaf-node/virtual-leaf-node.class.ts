import { VirtualDOMNode } from '../virtual-dom-node/virtual-dom-node.class';
import { VirtualNode } from '../virtual-node/virtual-node.class';

/**
 * Represents an abstract Leaf Node in an abstract DOM.
 * A Leaf cannot be a used as a parent node.
 */
export abstract class VirtualLeafNode extends VirtualDOMNode {
  protected constructor() {
    super();
  }

  override acceptsChild(
    node: VirtualNode,
  ): boolean {
    return false;
  }

  override getParentDOMNode(): never {
    throw new Error(`Cannot be used as parent`);
  }
}
