import { IObservable } from '@lirx/core';
import { IGenericVirtualElementNode } from '../virtual-element-node/generic-virtual-element-node.type';
import { VirtualRootNode } from '../virtual-root-node/virtual-root-node.class';

export interface IVirtualShadowRootNodeInit extends Partial<ShadowRootInit> {
}

/**
 * Represents an abstract ShadowRoot Node in an abstract DOM.
 */
export class VirtualShadowRootNode<GParentNode extends IGenericVirtualElementNode> extends VirtualRootNode<ShadowRoot> {

  static attachShadow<GParentBode extends IGenericVirtualElementNode>(
    parentNode: GParentBode,
    {
      mode = 'open',
      ...options
    }: IVirtualShadowRootNodeInit = {},
  ): VirtualShadowRootNode<GParentBode> {
    if (parentNode.elementNode.shadowRoot === null) {
      parentNode.elementNode.attachShadow({
        ...options,
        mode,
      });
      return new VirtualShadowRootNode<GParentBode>(parentNode);
    } else {
      throw new Error(`Already have a shadowRoot`);
    }
  }

  static fromShadow<GParentBode extends IGenericVirtualElementNode>(
    parentNode: GParentBode,
  ): VirtualShadowRootNode<GParentBode> {
    if (parentNode.elementNode.shadowRoot === null) {
      throw new Error(`Does not have a shadowRoot`);
    } else {
      return new VirtualShadowRootNode<GParentBode>(parentNode);
    }
  }

  protected constructor(
    parentNode: GParentNode,
  ) {
    super(
      parentNode.elementNode.shadowRoot,
      parentNode,
    );
  }

  override get parentNode$(): IObservable<GParentNode> {
    return super.parentNode$ as IObservable<GParentNode>;
  }

  override get parentNode(): GParentNode {
    return super.parentNode as GParentNode;
  }

  override get isConnected(): boolean {
    return this.parentNode.isConnected;
  }

  override get isConnected$(): IObservable<boolean> {
    return this.parentNode.isConnected$;
  }
}

export type IGenericVirtualShadowRootNode = VirtualShadowRootNode<any>;
