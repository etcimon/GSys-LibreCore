import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { isRXContainer } from '../../rx-container/is-rx-container';
import { generateJSLinesForRXTemplateFromElement } from './generate-js-lines-for-rx-template-from-element';
import { generateJSLinesForRXTemplateFromNodes } from './generate-js-lines-for-rx-template-from-nodes';

export interface IGenerateJSLinesForRXTemplateFromRXContainerElementOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly argumentsLines: ILinesOrNull;
}

export function generateJSLinesForRXTemplateFromRXContainerOrElement(
  {
    node,
    ...options
  }: IGenerateJSLinesForRXTemplateFromRXContainerElementOptions,
): ILines {
  return isRXContainer(node)
    ? generateJSLinesForRXTemplateFromNodes({
      ...options,
      nodes: node.childNodes,
    })
    : generateJSLinesForRXTemplateFromElement({
      ...options,
      node,
    });
}
