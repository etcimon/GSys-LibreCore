import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import {
  IClassNamesList,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/members/class/class-names-list.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveClassNamesListToJSLinesFunction,
  ITranspileSetReactiveClassNamesListToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-class-names-list-to-js-lines.type';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactiveClassNamesListToJSLines: ITranspileSetReactiveClassNamesListToJSLinesFunction = (
  {
    node,
    value,
  }: ITranspileSetReactiveClassNamesListToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_12', value.type)}(`],
    node,
    [`, `],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_12(
  node: IGenericVirtualReactiveElementNode,
  classNamesList$: IObservableLike<IClassNamesList>,
): IUnsubscribe {
  return node.setReactiveClassNamesList(
    unknownToObservableNotUndefined(classNamesList$),
  );
}

export function aot_12_computed(
  node: IGenericVirtualReactiveElementNode,
  classNamesList: () => IClassNamesList,
): IUnsubscribe {
  return node.setReactiveClassNamesList(
    computationToObservable(classNamesList),
  );
}
