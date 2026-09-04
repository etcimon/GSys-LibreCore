import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { generateJSLinesForStaticTextNodeIfNotEmpty } from './generate-js-lines-for-static-text-node-if-not-empty';

export interface ITranspileReactiveHTMLStaticTextNodeToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Text;
}

export function transpileReactiveHTMLStaticTextNodeToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLStaticTextNodeToJSLinesOptions,
): ILinesOrNull {
  return generateJSLinesForStaticTextNodeIfNotEmpty({
    ...options,
    value: node.data,
  });
}
