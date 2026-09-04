import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  VirtualReactiveElementNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/virtual-reactive-element-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactivePropertyToJSLinesFunction,
  ITranspileSetReactivePropertyToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-property-to-js-lines.type';
import {
  bindCaseInsensitivePropertyWithObservableLike,
  InferBindCaseInsensitivePropertyWithObservableLikeValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/members/property/case-insensitive/bind/bind-case-insensitive-property-with-observable-like';
import {
  transpileAOTReactiveValueTypeToFunctionName,
  transpileAOTReactiveValueToJSLines,
} from './special/transpile-reactive-value-to-js-lines';
import { InferCaseInsensitiveObjectKey } from '../../../../../../misc/types/infer-case-insensitive-object-key.type';
import {
  bindCaseInsensitivePropertyWithObservable,
  InferBindCaseInsensitivePropertyWithObservableValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-reactive-element-node/members/property/case-insensitive/bind/bind-case-insensitive-property-with-observable';
import { computationToObservable } from '../../shared/functions/computation-to-observable';

export const transpileAOTSetReactivePropertyToJSLines: ITranspileSetReactivePropertyToJSLinesFunction = (
  {
    node,
    name,
    value,
  }: ITranspileSetReactivePropertyToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [`${transpileAOTReactiveValueTypeToFunctionName('aot_19', value.type)}(`],
    node,
    [', '],
    name,
    [', '],
    transpileAOTReactiveValueToJSLines(value),
    [');'],
  );
};

export function aot_19<GElementNode extends Element, GCaseInsensitiveKey extends string>(
  node: VirtualReactiveElementNode<GElementNode>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value$: InferBindCaseInsensitivePropertyWithObservableLikeValue<GElementNode, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitivePropertyWithObservableLike<GElementNode, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    value$,
  );
}

export function aot_19_computed<GElementNode extends Element, GCaseInsensitiveKey extends string>(
  node: VirtualReactiveElementNode<GElementNode>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value: () => GElementNode[InferCaseInsensitiveObjectKey<GElementNode, GCaseInsensitiveKey>],
): IUnsubscribe {
  return bindCaseInsensitivePropertyWithObservable<GElementNode, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    computationToObservable(value) as InferBindCaseInsensitivePropertyWithObservableValue<GElementNode, GCaseInsensitiveKey>,
  );
}


