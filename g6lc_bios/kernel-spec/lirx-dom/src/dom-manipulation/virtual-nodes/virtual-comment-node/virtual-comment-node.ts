import { VirtualLeafNode } from '../virtual-leaf-node/virtual-leaf-node.class';
import { linkDOMNodeWithVirtualDOMNode } from '../virtual-node/members/link/link-dom-node-with-virtual-dom-node';

/**
 * Represents an abstract Comment Node in an abstract DOM.
 */
export class VirtualCommentNode extends VirtualLeafNode {
  readonly #commentNode: Comment; // the associated DOM Comment Node
  readonly #selfDOMNodes: [Comment]; // computed

  constructor(
    value?: string,
  ) {
    super();
    this.#commentNode = new Comment(value);
    this.#selfDOMNodes = [
      this.#commentNode,
    ];
    linkDOMNodeWithVirtualDOMNode(this.#commentNode, this);
  }

  /**
   * Returns the DOM Comment Node of this node.
   */
  get commentNode(): Comment {
    return this.#commentNode;
  }

  /**
   * Returns the text content of this node.
   */
  get value(): string {
    return this.#commentNode.data;
  }

  /**
   * Sets the text content of this node.
   */
  set value(
    input: string,
  ) {
    this.#commentNode.data = input;
  }

  override getSelfDOMNodes(): readonly Node[] {
    return this.#selfDOMNodes;
  }

  override getReferenceDOMNode(): Node {
    return this.#commentNode;
  }
}
