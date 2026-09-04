import { getElementNameSpaceURI } from '../../../../../../../dom-manipulation/helpers/misc/get-element-name-space-uri';
import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { HTML_NAMESPACE_URI_CONSTANT } from '../../../../../../../dom-manipulation/misc/namespace-uri/html-namespace-uri.constant';
import { inlineLastLines } from '../../../../../../misc/lines/functions/after-last-line';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap,
} from '../../../../primary/transpilers/transpile-create-reactive-custom-element-node-to-js-lines.type';
import { generateJSLinesForElement } from '../shared/generate-js-lines-for-element';
import {
  transpileReactiveHTMLCustomElementChildrenToSlotsOfJSLines,
} from './slots/transpile-reactive-html-custom-element-children-to-slots-of-js-lines';

export interface ITranspileReactiveHTMLCustomElementToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLCustomElementToJSLines(
  {
    node,
    transpilers,
  }: ITranspileReactiveHTMLCustomElementToJSLinesOptions,
): ILinesOrNull {
  const namespaceURI: string = getElementNameSpaceURI(node);
  const name: string = getElementTagName(node);
  const isCustomElement: boolean = (namespaceURI === HTML_NAMESPACE_URI_CONSTANT)
    && name.includes('-')
    && !node.hasAttribute('*external');

  if (isCustomElement) {
    const {
      transpileCreateReactiveCustomElementNodeToJSLines,
    } = transpilers;

    const slots: ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap = transpileReactiveHTMLCustomElementChildrenToSlotsOfJSLines({
      nodes: node.childNodes,
      transpilers,
    });

    const elementLines: ILines = [
      `// custom element '${name}'`,
      ...inlineLastLines(
        [`const node = (`],
        transpileCreateReactiveCustomElementNodeToJSLines({
          name,
          slots,
        }),
        [');'],
      ),
    ];

    return generateJSLinesForElement({
      node,
      elementLines,
      childrenLines: [],
      transpilers,
    });
  } else {
    return null;
  }
}

