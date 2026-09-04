import { IObserver } from '@lirx/core';
import { createEventListener, isNullish } from '@lirx/utils';
import { VirtualDOMNode } from '../virtual-dom-node/virtual-dom-node.class';
import { linkDOMNodeWithVirtualDOMNode } from '../virtual-node/members/link/link-dom-node-with-virtual-dom-node';
import { IVirtualShadowRootNodeInit, VirtualShadowRootNode } from '../virtual-shadow-root-node/virtual-shadow-root-node.class';
import { IAttributeReadValue, IAttributeWriteValue } from './members/attribute/attribute-value.type';
import { InferVirtualElementNodePropertyKeys } from './members/property/infer-virtual-element-node-property-keys.type';
import { IGetStylePropertyOptions, ISetStylePropertyOrStringOrNull, IStyleProperty } from './members/style/style-property.type';
import { IUnsubscribe } from '@lirx/unsubscribe';

/**
 * Represents an abstract Element in an abstract DOM.
 * This is used as a wrapper for an Element.
 */
export class VirtualElementNode<GElementNode extends Element> extends VirtualDOMNode {
  readonly #elementNode: GElementNode;
  #shadowRoot: VirtualShadowRootNode<this> | null;
  readonly #selfDOMNodes: [GElementNode]; // computed

  constructor(
    namespaceURI: string,
    name: string,
    options?: ElementCreationOptions,
  ) {
    super();
    this.#elementNode = document.createElementNS(namespaceURI, name, options) as GElementNode;
    this.#shadowRoot = null;
    this.#selfDOMNodes = [
      this.#elementNode,
    ];

    linkDOMNodeWithVirtualDOMNode(this.#elementNode, this);
  }

  /**
   * Returns the Element of this node.
   */
  get elementNode(): GElementNode {
    return this.#elementNode;
  }

  get shadowRoot(): VirtualShadowRootNode<this> | null {
    return this.#shadowRoot;
  }

  override getSelfDOMNodes(): readonly Node[] {
    return this.#selfDOMNodes;
  }

  override getParentDOMNode(): ParentNode {
    return this.#elementNode;
  }

  override getReferenceDOMNode(): Node {
    return this.#elementNode;
  }

  attachShadow(
    options?: IVirtualShadowRootNodeInit,
  ): VirtualShadowRootNode<this> {
    return this.#shadowRoot = VirtualShadowRootNode.attachShadow<this>(this, options);
  }

  /* EVENT */

  /**
   * Creates an EventListener of type "type" on the element of this node, whose listener is an Observer.
   */
  setEventListener<GEvent extends Event>(
    type: string,
    observer: IObserver<GEvent>,
    options?: boolean | AddEventListenerOptions,
  ): IUnsubscribe {
    return createEventListener<string, GEvent>(
      this.#elementNode as any,
      type,
      observer as any,
      options,
    );
  }

  /* PROPERTY */

  /**
   * Returns the value of the property "propertyKey" of the element of this node.
   */
  getProperty<GPropertyKey extends InferVirtualElementNodePropertyKeys<GElementNode>>(
    propertyKey: GPropertyKey,
  ): GElementNode[GPropertyKey] {
    return this.#elementNode[propertyKey];
  }

  /**
   * Sets the value of the property "propertyKey" of the element of this node.
   */
  setProperty<GPropertyKey extends InferVirtualElementNodePropertyKeys<GElementNode>>(
    propertyKey: GPropertyKey,
    value: GElementNode[GPropertyKey],
  ): void {
    this.#elementNode[propertyKey] = value;
  }

  /* ATTRIBUTE */

  /**
   * Returns the value of the attribute "name" of the element of this node.
   * If the attribute is not set, the function returns null.
   */
  getAttribute(
    name: string,
  ): IAttributeReadValue {
    return this.#elementNode.hasAttribute(name)
      ? this.#elementNode.getAttribute(name)
      : null;
  }

  /**
   * Set the value of the attribute "name" of the element of this node.
   * If the value is null, the attribute is removed.
   */
  setAttribute(
    name: string,
    value: IAttributeWriteValue,
  ): void {
    if (isNullish(value) || (value === false)) {
      this.#elementNode.removeAttribute(name);
    } else if (value === true) {
      this.#elementNode.setAttribute(name, '');
    } else {
      this.#elementNode.setAttribute(name, String(value));
    }
  }

  /**
   * Returns an Iterator on the list of attributes of the element of this node.
   */
  * getAttributesIterator(): Generator<[string, string]> {
    for (let i = 0, l = this.#elementNode.attributes.length; i < l; i++) {
      const attr: Attr = this.#elementNode.attributes[i];
      yield [attr.name, attr.value];
    }
  }

  /* CLASS */

  /**
   * Returns true if the element of this node has the css class "name".
   * Else returns false.
   */
  hasClass(
    name: string,
  ): boolean {
    return this.#elementNode.classList.contains(name);
  }

  /**
   * Sets the css class "name" of the element of this node.
   * If "enabled" is true, then the class is present, else if "enabled" is false, the class is removed.
   */
  setClass(
    name: string,
    enabled: boolean,
  ): void {
    this.#elementNode.classList.toggle(name, enabled);
  }

  /**
   * Returns an Iterator on the list of css classes of the element of this node.
   */
  * getClassesIterator(): Generator<string> {
    for (let i = 0, l = this.#elementNode.classList.length; i < l; i++) {
      yield this.#elementNode.classList[i];
    }
  }

  /* STYLE */

  /**
   * Returns the style property with the name "name" of the element of this node.
   */
  getStyleProperty(
    name: string,
    {
      computed = false,
    }: IGetStylePropertyOptions = {},
  ): IStyleProperty {
    const style: CSSStyleDeclaration = computed
      ? getComputedStyle(this.#elementNode as unknown as HTMLElement)
      : (this.#elementNode as unknown as HTMLElement).style;
    return {
      value: style.getPropertyValue(name),
      priority: style.getPropertyPriority(name),
    };
  }

  /**
   * Sets the style property with the name "name" of the element of this node.
   */
  setStyleProperty(
    name: string,
    property: ISetStylePropertyOrStringOrNull,
  ): void {
    const style: CSSStyleDeclaration = (this.#elementNode as unknown as HTMLElement).style;

    if (property === null) {
      style.removeProperty(
        name,
      );
    } else if (typeof property === 'string') {
      style.setProperty(
        name,
        property,
      );
    } else {
      style.setProperty(
        name,
        property.value,
        property.priority,
      );
    }
  }

  /**
   * Returns an Iterator on the list of style properties of the element of this node.
   */
  * getStylePropertiesIterator(): Generator<IStyleProperty> {
    const style: CSSStyleDeclaration = (this.#elementNode as unknown as HTMLElement).style;
    for (let i = 0, l = style.length; i < l; i++) {
      yield this.getStyleProperty(style[i]);
    }
  }
}

