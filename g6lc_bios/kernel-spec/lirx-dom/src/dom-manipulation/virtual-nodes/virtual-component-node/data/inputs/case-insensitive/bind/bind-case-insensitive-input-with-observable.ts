import { IUnsubscribe } from '@lirx/unsubscribe';
import { VirtualComponentNode } from '../../../../virtual-component-node.class';
import {
  InferCaseInsensitiveDataKeyOfVirtualComponentNode,
  getCaseInsensitiveDataKeyOfVirtualComponentNode,
} from '../../../case-insensitive/get-case-insensitive-data-key-of-virtual-component-node';
import { InferDataInputSetValue } from '../../infer-data-inputs.type';
import { isInput } from '../../is-input';
import { IObservable } from '@lirx/core';
import { InferCaseInsensitiveDataInputKey } from '../infer-case-insensitive-data-input-key.type';

export type InferBindCaseInsensitiveInputWithObservableValue<GData extends object, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveDataInputKey<GData, GCaseInsensitiveKey> extends never
    ? never
    : IObservable<InferDataInputSetValue<GData[InferCaseInsensitiveDataInputKey<GData, GCaseInsensitiveKey>]>>
  ;

export function bindCaseInsensitiveInputWithObservable<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value$: InferBindCaseInsensitiveInputWithObservableValue<GData, GCaseInsensitiveKey>,
): IUnsubscribe {
  type GKey = InferCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey>;

  const key: GKey = getCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey>(node, caseInsensitiveKey);

  if (isInput(node.data[key])) {
    type GKeyInput = InferCaseInsensitiveDataInputKey<GData, GCaseInsensitiveKey>;

    return node.bindInputWithObservable<GKeyInput>(
      key as unknown as GKeyInput,
      value$,
    );
  } else {
    throw new Error(`"${key}" is not an Input`);
  }
}


