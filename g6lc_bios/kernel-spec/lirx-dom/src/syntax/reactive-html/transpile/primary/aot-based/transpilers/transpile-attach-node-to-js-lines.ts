import { VirtualNode } from '../../../../../../dom-manipulation/virtual-nodes/virtual-node/virtual-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { wrapLinesWithRoundBrackets } from '../../../../../misc/lines/functions/wrap-lines-with-round-brackets';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileAttachNodeToJSLinesFunction,
  ITranspileAttachNodeToJSLinesOptions,
} from '../../transpilers/transpile-attach-node-to-js-lines.type';

export const transpileAOTAttachNodeToJSLines: ITranspileAttachNodeToJSLinesFunction = (
  {
    node,
    parentNode,
  }: ITranspileAttachNodeToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    ['aot_0('],
    wrapLinesWithRoundBrackets(node),
    [`,`],
    parentNode,
    [`);`],
  );
};

export function aot_0(
  node: VirtualNode,
  parentNode: VirtualNode,
): void {
  node.attach(parentNode);
}
