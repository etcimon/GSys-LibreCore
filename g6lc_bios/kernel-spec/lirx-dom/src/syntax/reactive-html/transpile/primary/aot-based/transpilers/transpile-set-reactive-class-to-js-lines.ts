import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveClassToJSLinesFunction,
  ITranspileSetReactiveClassToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-class-to-js-lines.type';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactiveClassToJSLines: ITranspileSetReactiveClassToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetReactiveClassToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_13', value.type)}(`],
    node,
    [`, `],
    name,
    [', '],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_13(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  enabled$: IObservableLike<boolean>,
): IUnsubscribe {
  return node.setReactiveClass(
    name,
    unknownToObservableNotUndefined(enabled$),
  );
}

export function aot_13_computed(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  enabled: () => boolean,
): IUnsubscribe {
  return node.setReactiveClass(
    name,
    computationToObservable(enabled),
  );
}
