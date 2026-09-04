import { IUnsubscribe } from '@lirx/unsubscribe';
import { VirtualComponentNode } from '../../../../virtual-component-node.class';
import { bindCaseInsensitiveOutputWithObserver } from './bind-case-insensitive-output-with-observer';
import { IObserverLike } from '@lirx/core';
import { InferDataOutputValue } from '../../infer-data-outputs.type';
import { InferCaseInsensitiveDataOutputKey } from '../infer-case-insensitive-data-output-key.type';

export type InferBindCaseInsensitiveOutputWithObserverLikeValue<GData extends object, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveDataOutputKey<GData, GCaseInsensitiveKey> extends never
    ? never
    : IObserverLike<InferDataOutputValue<GData[InferCaseInsensitiveDataOutputKey<GData, GCaseInsensitiveKey>]>>
  ;

export function bindCaseInsensitiveOutputWithObserverLike<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  $value: InferBindCaseInsensitiveOutputWithObserverLikeValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitiveOutputWithObserver<GData, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    $value as any,
  );
}
