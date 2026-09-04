import { IUnsubscribe } from '@lirx/unsubscribe';
import { VirtualComponentNode } from '../../../../virtual-component-node.class';
import { unknownToObservableNotUndefined, IObservableLike } from '@lirx/core';
import { bindCaseInsensitiveInputWithObservable } from './bind-case-insensitive-input-with-observable';
import { InferDataInputGetValue } from '../../infer-data-inputs.type';
import { InferCaseInsensitiveDataInputKey } from '../infer-case-insensitive-data-input-key.type';

export type InferBindCaseInsensitiveInputWithObservableLikeValue<GData extends object, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveDataInputKey<GData, GCaseInsensitiveKey> extends never
    ? never
    : IObservableLike<InferDataInputGetValue<GData[InferCaseInsensitiveDataInputKey<GData, GCaseInsensitiveKey>]>>
  ;

export function bindCaseInsensitiveInputWithObservableLike<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value$: InferBindCaseInsensitiveInputWithObservableLikeValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitiveInputWithObservable<GData, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    unknownToObservableNotUndefined(value$) as any,
  );
}
