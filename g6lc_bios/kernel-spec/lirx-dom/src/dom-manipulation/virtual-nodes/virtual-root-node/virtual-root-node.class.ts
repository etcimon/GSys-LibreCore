import { VirtualDOMNode } from '../virtual-dom-node/virtual-dom-node.class';
import { linkDOMNodeWithVirtualDOMNode } from '../virtual-node/members/link/link-dom-node-with-virtual-dom-node';
import { IVirtualNodeOrNull } from '../virtual-node/virtual-node-or-null.type';
import { IObservable, single } from '@lirx/core';

let BODY_ROOT: VirtualRootNode<HTMLBodyElement>;

/**
 * Represents an abstract Root Node in an abstract DOM.
 */
export class VirtualRootNode<GRootNode extends ParentNode> extends VirtualDOMNode {

  /**
   * Returns the VirtualRootNode of the <body> element.
   */
  static get body(): VirtualRootNode<HTMLBodyElement> {
    if (BODY_ROOT === void 0) {
      BODY_ROOT = new VirtualRootNode<HTMLBodyElement>(document.body as HTMLBodyElement);
    }
    return BODY_ROOT;
  }

  readonly #isConnected$: IObservable<boolean>;
  readonly #rootNode: GRootNode; // the associated DOM Node
  readonly #selfDOMNodes: [GRootNode]; // computed

  constructor(
    rootNode: GRootNode,
    parentNode?: IVirtualNodeOrNull,
  ) {
    super(parentNode);
    this.#isConnected$ = single(true);
    this.#rootNode = rootNode;
    this.#selfDOMNodes = [
      this.#rootNode,
    ];
    linkDOMNodeWithVirtualDOMNode(this.#rootNode, this);
  }

  override get isConnected(): boolean {
    return true;
  }

  override get isConnected$(): IObservable<boolean> {
    return this.#isConnected$;
  }

  /**
   * Returns the associated DOM Node of this node.
   */
  get rootNode(): GRootNode {
    return this.#rootNode;
  }

  override acceptsParent(
    node: IVirtualNodeOrNull,
  ): boolean {
    return false;
  }

  override getSelfDOMNodes(): readonly Node[] {
    return this.#selfDOMNodes;
  }

  override getParentDOMNode(): ParentNode {
    return this.#rootNode;
  }

  override getReferenceDOMNode(): Node {
    return this.#rootNode;
  }
}

export type IGenericVirtualRootNode = VirtualRootNode<any>;

