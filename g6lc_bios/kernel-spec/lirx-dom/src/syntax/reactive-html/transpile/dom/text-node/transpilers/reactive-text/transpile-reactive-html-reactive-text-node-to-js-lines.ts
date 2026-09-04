import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLReactiveTextToJSLines } from './transpile-reactive-html-reactive-text-to-js-lines';

export interface ITranspileReactiveHTMLReactiveTextNodeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Text;
}

export function transpileReactiveHTMLReactiveTextNodeToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLReactiveTextNodeToJSLinesOptions,
): ILinesOrNull {
  return transpileReactiveHTMLReactiveTextToJSLines({
    ...options,
    value: node.data,
  });
}

