import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  ISetStylePropertyOrStringOrNull,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-element-node/members/style/style-property.type';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveStylePropertyToJSLinesFunction,
  ITranspileSetReactiveStylePropertyToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-style-property-to-js-lines.type';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactiveStylePropertyToJSLines: ITranspileSetReactiveStylePropertyToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetReactiveStylePropertyToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_21', value.type)}(`],
    node,
    [', '],
    name,
    [', '],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_21(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  styleProperty$: IObservableLike<ISetStylePropertyOrStringOrNull>,
): IUnsubscribe {
  return node.setReactiveStyleProperty(
    name,
    unknownToObservableNotUndefined(styleProperty$),
  );
}

export function aot_21_computed(
  node: IGenericVirtualReactiveElementNode,
  name: string,
  styleProperty: () => ISetStylePropertyOrStringOrNull,
): IUnsubscribe {
  return node.setReactiveStyleProperty(
    name,
    computationToObservable(styleProperty),
  );
}
