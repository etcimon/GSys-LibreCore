import {
  createMulticastReplayLastSource,
  distinctObservable,
  IMulticastReplayLastSource,
  IObservable,
  shareObservableWithMulticastReplayLastSource,
  single,
  switchMapObservable,
} from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import { IVirtualNodeOrNull } from './virtual-node-or-null.type';

/**
 * Represents an abstract Node in a Tree.
 */
export abstract class VirtualNode {
  #$parentNode$: IMulticastReplayLastSource<IVirtualNodeOrNull>;
  #previousNode: IVirtualNodeOrNull;
  #nextNode: IVirtualNodeOrNull;
  #firstChild: IVirtualNodeOrNull;
  #lastChild: IVirtualNodeOrNull;

  #isConnected$: IObservable<boolean> | undefined; // lazy

  constructor(
    parentNode: IVirtualNodeOrNull = null,
  ) {
    // INFO lazy loading this prop doesn't improve perfs
    this.#$parentNode$ = createMulticastReplayLastSource<IVirtualNodeOrNull>(parentNode);
    this.#previousNode = null;
    this.#nextNode = null;
    this.#firstChild = null;
    this.#lastChild = null;
  }

  /**
   * Returns an Observable sending the parent of this node.
   * This is useful to detect changes in the parent node.
   */
  get parentNode$(): IObservable<IVirtualNodeOrNull> {
    return this.#$parentNode$.subscribe;
  }

  /**
   * Returns the parent node of this node
   */
  get parentNode(): IVirtualNodeOrNull {
    return this.#$parentNode$.getValue();
  }

  /**
   * Returns the node before this node, or null if none.
   */
  get previousNode(): IVirtualNodeOrNull {
    return this.#previousNode;
  }

  /**
   * Returns the node after this node, or null if none.
   */
  get nextNode(): IVirtualNodeOrNull {
    return this.#nextNode;
  }

  /**
   * Returns the first child node of this node, or null if none.
   */
  get firstChild(): IVirtualNodeOrNull {
    return this.#firstChild;
  }

  /**
   * Returns the last child node of this node, or null if none.
   */
  get lastChild(): IVirtualNodeOrNull {
    return this.#lastChild;
  }

  /**
   * Returns true if this node is connected to a root node.
   */
  get isConnected(): boolean {
    const parentNode: IVirtualNodeOrNull = this.parentNode;
    return (parentNode === null)
      ? false
      : parentNode.isConnected;
  }

  /**
   * Returns an Observable sending "true" if this node is connected to a root node, or "false".
   * This is useful to detect changes in the "connected state" of this node.
   */
  get isConnected$(): IObservable<boolean> {
    if (this.#isConnected$ === void 0) { // micro-optimization
      this.#isConnected$ = shareObservableWithMulticastReplayLastSource<boolean>(
        distinctObservable<boolean>(
          switchMapObservable<IVirtualNodeOrNull, boolean>(this.parentNode$, (parentNode: IVirtualNodeOrNull): IObservable<boolean> => {
            if (parentNode === null) {
              return single(false); // faster
              // return single(this.isConnected); // faster
              // return reference((): boolean => this.isConnected);
            } else {
              return parentNode.isConnected$;
            }
          }),
        ));
    }
    return this.#isConnected$;
  }

  /**
   * Calls `factory` when the node is connected to a root node.
   * Then, it calls the returned `IUnsubscribe` function when it is disconnected
   */
  onConnected(
    factory: () => IUnsubscribe,
  ): IUnsubscribe {
    let running: boolean = true;
    let _unsubscribeOfFactory: IUnsubscribe | undefined;

    const unsubscribeOfFactory: IUnsubscribe = (): void => {
      if (_unsubscribeOfFactory !== void 0) {
        _unsubscribeOfFactory();
      }
    };

    const unsubscribeOfConnected: IUnsubscribe = this.isConnected$((connected: boolean): void => {
      unsubscribeOfFactory();
      if (connected) {
        _unsubscribeOfFactory = factory();
      }
    });

    return (): void => {
      if (running) {
        running = false;
        unsubscribeOfFactory();
        unsubscribeOfConnected();
      }
    };
  }

  /**
   * Returns true if this node contains "childNode".
   */
  contains(
    childNode: VirtualNode,
  ): boolean {
    let node: IVirtualNodeOrNull = childNode;

    do {
      if (node === this) {
        return true;
      } else {
        node = node.parentNode;
      }
    } while (node !== null);

    return false;
  }

  /**
   * Attaches this node to "parentNode" before "referenceNode".
   * Performs some internal verifications to ensure that this operation is possible.
   * Returns true if attaching this node was necessary (the node had to move).
   */
  attach(
    parentNode: VirtualNode,
    referenceNode: IVirtualNodeOrNull = null,
  ): boolean {
    // test if this node could be attached to parentNode
    if (
      !this.acceptsParent(parentNode)
      || !parentNode.acceptsChild(this)
    ) {
      throw new Error(`Cannot attach this node to this parent`);
    }

    if (this.contains(parentNode)) {
      throw new Error(`current node already contains parentNode`);
    }

    // test if this node requires to be attached (or maybe it doesn't move)
    if (referenceNode === null) {
      if (
        (this.parentNode === parentNode)
        && (this.parentNode.#lastChild === this) // current node is already the last child of parentNode, so we have nothing to do
      ) {
        return false;
      }
    } else {
      if (
        (referenceNode === this)
        || (this.#nextNode === referenceNode)
      ) { // current node is already before referenceNode, so we have nothing to do
        return false;
      }

      if (referenceNode.parentNode !== parentNode) {
        throw new Error(`referenceNode must have parentNode as parent`);
      }
    }

    // detach current node
    if (this.parentNode !== null) {
      if (this.#previousNode === null) { // current node is first child
        this.parentNode.#firstChild = this.#nextNode;
      } else {
        this.#previousNode.#nextNode = this.#nextNode;
      }

      if (this.#nextNode === null) { // current node is last child
        this.parentNode.#lastChild = this.#previousNode;
      } else {
        this.#nextNode.#previousNode = this.#previousNode;
      }
    }

    this.#nextNode = referenceNode;

    if (referenceNode === null) {
      this.#previousNode = parentNode.#lastChild;

      if (parentNode.#lastChild === null) { // empty list
        parentNode.#firstChild = this;
        parentNode.#lastChild = this;
      } else {
        parentNode.#lastChild.#nextNode = this;
        parentNode.#lastChild = this;
      }
    } else {
      this.#previousNode = referenceNode.#previousNode;

      if (referenceNode.#previousNode === null) { // referenceNode is first child
        parentNode.#firstChild = this;
      } else {
        referenceNode.#previousNode.#nextNode = this;
      }

      referenceNode.#previousNode = this;
    }

    this.#$parentNode$.emit(parentNode);

    return true;
  }

  /**
   * Detaches this node from its parent node.
   * Returns true if this operation was necessary (the node had a parent node)
   */
  detach(): boolean {
    if (this.acceptsParent(null)) {
      if (this.parentNode === null) {
        return false;
      } else {
        if (this.#previousNode === null) { // current node is first child
          this.parentNode.#firstChild = this.#nextNode;
        } else {
          this.#previousNode.#nextNode = this.#nextNode;
        }

        if (this.#nextNode === null) { // current node is last child
          this.parentNode.#lastChild = this.#previousNode;
        } else {
          this.#nextNode.#previousNode = this.#previousNode;
        }

        this.#previousNode = null;
        this.#nextNode = null;
        this.#$parentNode$.emit(null);

        return true;
      }
    } else {
      throw new Error(`Cannot detach this node`);
    }
  }

  /**
   * Returns an Iterator on the list of direct child nodes of this node.
   */
  * getChildren(): Generator<VirtualNode> {
    let node: IVirtualNodeOrNull = this.#firstChild;
    while (node !== null) {
      yield node;
      node = node.#nextNode;
    }
  }

  /**
   * Returns an Iterator on the list of direct child nodes of this node, in reverse order (starting from the last one).
   * @see getChildren
   */
  * getChildrenReversed(): Generator<VirtualNode> {
    let node: IVirtualNodeOrNull = this.#lastChild;
    while (node !== null) {
      yield node;
      node = node.#previousNode;
    }
  }

  /**
   * Returns an Iterator on the list of all child nodes of this node.
   */
  * getChildrenRecursive(): Generator<VirtualNode> {
    const iterator: Iterator<VirtualNode> = this.getChildren();
    let result: IteratorResult<VirtualNode>;
    while (!(result = iterator.next()).done) {
      const childNode: VirtualNode = result.value;
      yield childNode;
      yield* childNode.getChildrenRecursive();
    }
  }

  /**
   * Detaches all the child nodes of this node.
   */
  detachChildren(): void {
    let node: IVirtualNodeOrNull = this.#firstChild;
    while (node !== null) {
      const nextNode: IVirtualNodeOrNull = node.#nextNode;
      node.detach();
      node = nextNode;
    }
  }

  /**
   * Returns true if this node accepts "node" has children.
   * It is usually used to prevent invalid Tree to exist (we may think about a <button> containing an <input>)
   */
  abstract acceptsChild(
    node: VirtualNode,
  ): boolean;

  /**
   * Returns true if this node accepts "node" has its parent.
   */
  abstract acceptsParent(
    node: IVirtualNodeOrNull,
  ): boolean;
}



