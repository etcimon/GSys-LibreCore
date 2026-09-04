import { nullIfEmptyLines } from '../../../../../misc/lines/functions/null-if-empty-lines';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLNodeToJSLines } from '../../node/transpile-reactive-html-node-to-js-lines';

export interface ITranspileReactiveHTMLGenericNodesToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly nodes: ArrayLike<Node>;
}

export function transpileReactiveHTMLGenericNodesToJSLines(
  {
    nodes,
    ...options
  }: ITranspileReactiveHTMLGenericNodesToJSLinesOptions,
): ILinesOrNull {
  const lines: ILines = [];
  for (let i = 0, l = nodes.length; i < l; i++) {
    const result: ILinesOrNull = transpileReactiveHTMLNodeToJSLines({
      node: nodes[i],
      ...options,
    });
    if (result !== null) {
      lines.push(...result);
    }
  }
  return nullIfEmptyLines(lines);
}
