import { IUnsubscribe } from '@lirx/unsubscribe';
import {
  VirtualComponentNode,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/virtual-component-node.class';
import { inlineLastLines } from '../../../../../misc/lines/functions/after-last-line';
import { ILines } from '../../../../../misc/lines/lines.type';
import {
  ITranspileSetReactiveOutputToJSLinesFunction,
  ITranspileSetReactiveOutputToJSLinesOptions,
} from '../../transpilers/transpile-set-reactive-output-to-js-lines.type';

import {
  bindCaseInsensitiveOutputWithObserverLike,
  InferBindCaseInsensitiveOutputWithObserverLikeValue,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/outputs/case-insensitive/bind/bind-case-insensitive-output-with-observer-like';
import {
  InferBindCaseInsensitiveOutputWithObservableOfObserverValue,
  bindCaseInsensitiveOutputWithObservableOfObserver,
} from '../../../../../../dom-manipulation/virtual-nodes/virtual-component-node/data/outputs/case-insensitive/bind/bind-case-insensitive-output-with-observable-of-observer';

export const transpileAOTSetReactiveOutputToJSLines: ITranspileSetReactiveOutputToJSLinesFunction = (
  {
    node,
    name,
    value,
    observableMode,
  }: ITranspileSetReactiveOutputToJSLinesOptions,
): ILines => {
  return inlineLastLines(
    [
      observableMode
        ? `aot_17(`
        : `aot_18(`,
    ],
    [],
    node,
    [', '],
    name,
    [', '],
    value,
    [');'],
  );
};

export function aot_17<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  $value: InferBindCaseInsensitiveOutputWithObservableOfObserverValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitiveOutputWithObservableOfObserver<GData, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    $value,
  );
}

export function aot_18<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  $value: InferBindCaseInsensitiveOutputWithObserverLikeValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitiveOutputWithObserverLike<GData, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    $value,
  );
}






