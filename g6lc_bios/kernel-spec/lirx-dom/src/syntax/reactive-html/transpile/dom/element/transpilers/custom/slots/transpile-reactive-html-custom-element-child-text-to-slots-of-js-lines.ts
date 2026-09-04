import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLTextNodeToJSLines } from '../../../../text-node/transpile-reactive-html-text-node-to-js-lines';

export interface ITranspileReactiveHTMLCustomElementChildTextToSlotsOfJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Text;
  readonly defaultSlotBodyLines: ILines; // mutable reference
}

export function transpileReactiveHTMLCustomElementChildTextToSlotsOfJSLines(
  {
    node,
    defaultSlotBodyLines,
    ...options
  }: ITranspileReactiveHTMLCustomElementChildTextToSlotsOfJSLinesOptions,
): void {
  const lines: ILinesOrNull = transpileReactiveHTMLTextNodeToJSLines({
    ...options,
    node: node as Text,
  });
  if (lines !== null) {
    defaultSlotBodyLines.push(...lines);
  }
}
