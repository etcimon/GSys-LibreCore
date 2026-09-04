import { IObservableLike, unknownToObservableNotUndefined } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  IGenericVirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/generic-virtual-reactive-element-node.type';
import {
  IStylePropertiesMap,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/members/style/style-properties-map.type';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveStylePropertiesMapToJSLinesFunction,
  ITranspileSetReactiveStylePropertiesMapToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-style-properties-map-to-js-lines.type';
import {
  transpileAOTReactiveValueTypeToFunctionName,
  transpileAOTReactiveValueToJSLines,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactiveStylePropertiesMapToJSLines: ITranspileSetReactiveStylePropertiesMapToJSLinesFunction = (
  {
    node,
    value,
  }: ITranspileSetReactiveStylePropertiesMapToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_20', value.type)}(`],
    node,
    [`, `],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_20(
  node: IGenericVirtualReactiveElementNode,
  stylePropertiesMap$: IObservableLike<IStylePropertiesMap>,
): IUnsubscribe {
  return node.setReactiveStylePropertiesMap(
    unknownToObservableNotUndefined(stylePropertiesMap$),
  );
}

export function aot_20_computed(
  node: IGenericVirtualReactiveElementNode,
  stylePropertiesMap: () => IStylePropertiesMap,
): IUnsubscribe {
  return node.setReactiveStylePropertiesMap(
    computationToObservable(stylePropertiesMap),
  );
}

