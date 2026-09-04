import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  VirtualComponentNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveInputToJSLinesFunction,
  ITranspileSetReactiveInputToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-input-to-js-lines.type';
import {
  bindCaseInsensitiveInputWithObservableLike,
  InferBindCaseInsensitiveInputWithObservableLikeValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/inputs/case-insensitive/bind/bind-case-insensitive-input-with-observable-like';
import {
  InferDataInputGetValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/inputs/infer-data-inputs.type';
import {
  InferCaseInsensitiveDataInputKey,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/inputs/case-insensitive/infer-case-insensitive-data-input-key.type';
import {
  bindCaseInsensitiveInputWithObservable,
  InferBindCaseInsensitiveInputWithObservableValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/inputs/case-insensitive/bind/bind-case-insensitive-input-with-observable';
import {
  transpileAOTReactiveValueToJSLines,
  transpileAOTReactiveValueTypeToFunctionName,
} from './special/transpile-reactive-value-to-js-lines';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactiveInputToJSLines: ITranspileSetReactiveInputToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetReactiveInputToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_16', value.type)}(`],
    node,
    [', '],
    name,
    [', '],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_16<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value$: InferBindCaseInsensitiveInputWithObservableLikeValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitiveInputWithObservableLike<GData, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    value$,
  );
}

export function aot_16_computed<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value: () => InferDataInputGetValue<GData[InferCaseInsensitiveDataInputKey<GData, GCaseInsensitiveKey>]>,
): IUnsubscribe {
  return bindCaseInsensitiveInputWithObservable<GData, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    computationToObservable(value) as InferBindCaseInsensitiveInputWithObservableValue<GData, GCaseInsensitiveKey>,
  );
}

