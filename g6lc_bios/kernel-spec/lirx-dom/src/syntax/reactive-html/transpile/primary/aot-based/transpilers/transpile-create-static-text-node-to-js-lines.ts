import {
  VirtualReactiveTextNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-text-node/virtual-reactive-text-node.class';
import { VirtualTextNode } from '../../../../../../dom-manipulation/virtual-nodes/virtual-text-node/virtual-text-node';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateStaticTextNodeToJSLinesFunction,
  ITranspileCreateStaticTextNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-static-text-node-to-js-lines.type';

export const transpileAOTCreateStaticTextNodeToJSLines: ITranspileCreateStaticTextNodeToJSLinesFunction = (
  {
    value,
  }: ITranspileCreateStaticTextNodeToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`aot_10(`],
    value,
    [')'],
  );
};

export function aot_10(
  value?: string,
): VirtualReactiveTextNode {
  return new VirtualTextNode(
    value,
  );
}
