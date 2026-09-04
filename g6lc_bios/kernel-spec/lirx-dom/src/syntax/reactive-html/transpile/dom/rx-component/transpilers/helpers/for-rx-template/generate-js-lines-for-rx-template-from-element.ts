import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLElementToJSLines } from '../../../../element/transpile-reactive-html-element-to-js-lines';
import { generateJSLinesForRXTemplate } from './generate-js-lines-for-rx-template';

export interface IGenerateJSLinesForRXTemplateFromElementOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly argumentsLines: ILinesOrNull;
}

export function generateJSLinesForRXTemplateFromElement(
  {
    node,
    argumentsLines,
    ...options
  }: IGenerateJSLinesForRXTemplateFromElementOptions,
): ILines {
  return generateJSLinesForRXTemplate({
    argumentsLines,
    bodyLines: transpileReactiveHTMLElementToJSLines({
      ...options,
      node,
    }),
  });
}
