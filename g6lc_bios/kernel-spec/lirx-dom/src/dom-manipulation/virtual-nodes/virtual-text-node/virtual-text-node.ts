import { VirtualLeafNode } from '../virtual-leaf-node/virtual-leaf-node.class';
import { linkDOMNodeWithVirtualDOMNode } from '../virtual-node/members/link/link-dom-node-with-virtual-dom-node';

/**
 * Represents an abstract Text Node in an abstract DOM.
 */
export class VirtualTextNode extends VirtualLeafNode {
  readonly #textNode: Text; // the associated DOM Text Node
  readonly #selfDOMNodes: [Text]; // computed

  constructor(
    value?: string,
  ) {
    super();
    this.#textNode = new Text(value);
    this.#selfDOMNodes = [
      this.#textNode,
    ];
    linkDOMNodeWithVirtualDOMNode(this.#textNode, this);
  }

  /**
   * Returns the DOM Text Node of this node.
   */
  get textNode(): Text {
    return this.#textNode;
  }

  /**
   * Returns the text content of this node.
   */
  get value(): string {
    return this.#textNode.data;
  }

  /**
   * Sets the text content of this node.
   */
  set value(
    input: string,
  ) {
    this.#textNode.data = input;
  }

  override getSelfDOMNodes(): readonly Node[] {
    return this.#selfDOMNodes;
  }

  override getReferenceDOMNode(): Node {
    return this.#textNode;
  }
}
