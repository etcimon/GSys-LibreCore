import { IVirtualDOMNodeOrNull } from '../virtual-dom-node/virtual-dom-node-or-null.type';
import { VirtualDOMNode } from '../virtual-dom-node/virtual-dom-node.class';

/**
 * Represents an abstract Container Node in an abstract DOM.
 * This is used as a virtual container for many DOM Nodes.
 */
export class VirtualContainerNode extends VirtualDOMNode {
  override getSelfDOMNodes(): readonly Node[] {
    return Array.from(this.getChildren())
      .flatMap((child: VirtualDOMNode): readonly Node[] => {
        return child.getSelfDOMNodes();
      });
  }

  override getParentDOMNode(): ParentNode | null {
    const parentNode: IVirtualDOMNodeOrNull = this.parentNode;
    return (parentNode === null)
      ? null
      : parentNode.getParentDOMNode();
  }

  override getReferenceDOMNode(): Node | null {
    return (this.firstChild === null)
      ? this.getNextReferenceDOMNode()
      : this.firstChild.getReferenceDOMNode();
  }
}

