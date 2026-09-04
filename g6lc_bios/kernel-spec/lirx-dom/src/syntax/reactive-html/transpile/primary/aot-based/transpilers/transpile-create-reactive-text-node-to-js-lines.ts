import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import {
  VirtualReactiveTextNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-text-node/virtual-reactive-text-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileCreateReactiveTextNodeToJSLinesFunction,
  ITranspileCreateReactiveTextNodeToJSLinesOptions,
} from '../../transpilers/transpile-create-reactive-text-node-to-js-lines.type';
import {
  VirtualReactiveIfNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-if-node/virtual-reactive-if-node.class';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTCreateReactiveTextNodeToJSLines: ITranspileCreateReactiveTextNodeToJSLinesFunction = (
  {
    value,
  }: ITranspileCreateReactiveTextNodeToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_9', value.type)}(`],
    transpileAOTReactiveValueToJSLines(value),
    [')'],
  );
};

export function aot_9(
  value$: IObservableLike<string>,
): VirtualReactiveTextNode {
  return new VirtualReactiveTextNode(
    unknownToObservableNotUndefined(value$),
  );
}

export function aot_9_computed(
  value: () => string,
): VirtualReactiveIfNode {
  return new VirtualReactiveTextNode(
    computationToObservable(value),
  );
}
