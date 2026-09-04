import {
  IGenericVirtualElementNode,
} from '../../../dom-manipulation/virtual-nodes/virtual-element-node/generic-virtual-element-node.type';
import {
  IGenericVirtualShadowRootNode,
} from '../../../dom-manipulation/virtual-nodes/virtual-shadow-root-node/virtual-shadow-root-node.class';
import { IComponentStyle } from '../component-style.type';

export function compileStyleAsShadowComponentStyle(
  css: string,
): IComponentStyle {
  const sheet = new CSSStyleSheet();
  sheet.replaceSync(css);

  return (
    node: IGenericVirtualElementNode,
  ): void => {
    const shadowRoot: IGenericVirtualShadowRootNode | null = node.shadowRoot;
    if (shadowRoot === null) {
      throw new Error(`Not a shadow component`);
    } else {
      shadowRoot.rootNode.adoptedStyleSheets = [
        ...shadowRoot.rootNode.adoptedStyleSheets,
        sheet,
      ];
    }
  };
}


