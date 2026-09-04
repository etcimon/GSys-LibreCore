import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  IAttributeWriteValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-element-node/members/attribute/attribute-value.type';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveAttributeToJSLinesFunction,
  ITranspileSetReactiveAttributeToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-attribute-to-js-lines.type';
import {
  transpileAOTReactiveValueTypeToFunctionName,
  transpileAOTReactiveValueToJSLines,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactiveAttributeToJSLines: ITranspileSetReactiveAttributeToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetReactiveAttributeToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_11', value.type)}(`],
    node,
    [', '],
    name,
    [', '],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_11(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  value$: IObservableLike<IAttributeWriteValue>,
): IUnsubscribe {
  return node.setReactiveAttribute(
    name,
    unknownToObservableNotUndefined(value$),
  );
}

export function aot_11_computed(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  value: () => IAttributeWriteValue,
): IUnsubscribe {
  return node.setReactiveAttribute(
    name,
    computationToObservable(value),
  );
}
