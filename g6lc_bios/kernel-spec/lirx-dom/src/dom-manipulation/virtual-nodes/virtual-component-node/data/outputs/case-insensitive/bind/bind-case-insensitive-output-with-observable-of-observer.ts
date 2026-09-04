import { IUnsubscribe } from '@lirx/unsubscribe';
import { VirtualComponentNode } from '../../../../virtual-component-node.class';
import {
  InferCaseInsensitiveDataKeyOfVirtualComponentNode,
  getCaseInsensitiveDataKeyOfVirtualComponentNode,
} from '../../../case-insensitive/get-case-insensitive-data-key-of-virtual-component-node';
import { InferDataOutputValue } from '../../infer-data-outputs.type';
import { isOutput } from '../../is-output';
import { IObserver, IObservable } from '@lirx/core';
import { InferCaseInsensitiveDataOutputKey } from '../infer-case-insensitive-data-output-key.type';

export type InferBindCaseInsensitiveOutputWithObservableOfObserverValue<GData extends object, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveDataOutputKey<GData, GCaseInsensitiveKey> extends never
    ? never
    : IObservable<IObserver<InferDataOutputValue<GData[InferCaseInsensitiveDataOutputKey<GData, GCaseInsensitiveKey>]>>>
  ;

export function bindCaseInsensitiveOutputWithObservableOfObserver<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  $value: InferBindCaseInsensitiveOutputWithObservableOfObserverValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  type GKey = InferCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey>;

  const key: GKey = getCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey>(node, caseInsensitiveKey);

  if (isOutput(node.data[key])) {
    type GKeyOutput = InferCaseInsensitiveDataOutputKey<GData, GCaseInsensitiveKey>;

    return node.bindOutputWithObservableOfObserver<GKeyOutput>(
      key as unknown as GKeyOutput,
      $value,
    );
  } else {
    throw new Error(`"${key}" is not an Output`);
  }
}


