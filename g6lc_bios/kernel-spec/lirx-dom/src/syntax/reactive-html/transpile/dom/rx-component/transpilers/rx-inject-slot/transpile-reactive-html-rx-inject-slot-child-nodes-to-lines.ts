import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLNodesToJSLines } from '../../../nodes/transpile-reactive-html-nodes-to-js-lines';
import { generateJSLinesForRXInjectSlot, IGenerateJSLinesForRXInjectSlotOptions } from './generate-js-lines-for-rx-inject-slot';

export interface ITranspileReactiveHTMLRXInjectSlotChildNodesToLinesOptions extends //
  IHavingPrimaryTranspilersOptions,
  Omit<IGenerateJSLinesForRXInjectSlotOptions, 'defaultLines'>
//
{
  readonly nodes: ArrayLike<Node>;
  readonly required: boolean;
}

export function transpileReactiveHTMLRXInjectSlotChildNodesToLines(
  {
    nodes,
    required,
    slotName,
    ...options
  }: ITranspileReactiveHTMLRXInjectSlotChildNodesToLinesOptions,
): ILines {
  let defaultLines!: ILinesOrNull;

  if (required) {
    defaultLines = [
      `throw new Error('The slot ${JSON.stringify(slotName)} is required');`,
    ];
    // TODO throw if has child node
  } else {
    defaultLines = transpileReactiveHTMLNodesToJSLines({
      ...options,
      nodes,
    });
  }

  return generateJSLinesForRXInjectSlot({
    ...options,
    slotName,
    defaultLines,
  });
}
