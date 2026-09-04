import { getElementNameSpaceURI } from '../../../../../../../dom-manipulation/helpers/misc/get-element-name-space-uri';
import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { inlineLastLines } from '../../../../../../misc/lines/functions/after-last-line';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { generateJSLinesForElement } from '../shared/generate-js-lines-for-element';

export interface ITranspileReactiveHTMLGenericElementToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLGenericElementToJSLines(
  {
    node,
    transpilers,
  }: ITranspileReactiveHTMLGenericElementToJSLinesOptions,
): ILinesOrNull {
  const namespaceURI: string = getElementNameSpaceURI(node);
  const name: string = getElementTagName(node);
  const isAttribute: string | null = node.getAttribute('is');

  const elementOptions: ElementCreationOptions | undefined = (isAttribute === null)
    ? void 0
    : {
      is: isAttribute,
    };

  const {
    transpileCreateReactiveElementNodeToJSLines,
  } = transpilers;

  const elementLines: ILines = [
    `// element '${name}'`,
    ...inlineLastLines(
      [`const node = (`],
      transpileCreateReactiveElementNodeToJSLines({
        namespaceURI,
        name,
        options: elementOptions,
      }),
      [');'],
    ),
  ];

  return generateJSLinesForElement({
    node,
    elementLines,
    transpilers,
  });
}
