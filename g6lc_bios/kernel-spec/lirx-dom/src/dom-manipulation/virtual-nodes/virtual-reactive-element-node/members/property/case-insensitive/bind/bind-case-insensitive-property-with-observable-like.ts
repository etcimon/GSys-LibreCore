import { IUnsubscribe } from '@lirx/unsubscribe';

import { unknownToObservableNotUndefined, IObservableLike } from '@lirx/core';
import { bindCaseInsensitivePropertyWithObservable } from './bind-case-insensitive-property-with-observable';
import { InferCaseInsensitiveObjectKey } from '../../../../../../../misc/types/infer-case-insensitive-object-key.type';
import { VirtualReactiveElementNode } from '../../../../virtual-reactive-element-node.class';

export type InferBindCaseInsensitivePropertyWithObservableLikeValue<GElementNode extends Element, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveObjectKey<GElementNode, GCaseInsensitiveKey> extends never
    ? never
    : IObservableLike<GElementNode[InferCaseInsensitiveObjectKey<GElementNode, GCaseInsensitiveKey>]>
  ;

export function bindCaseInsensitivePropertyWithObservableLike<GElementNode extends Element, GCaseInsensitiveKey extends string>(
  node: VirtualReactiveElementNode<GElementNode>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value$: InferBindCaseInsensitivePropertyWithObservableLikeValue<GElementNode, GCaseInsensitiveKey>,
): IUnsubscribe {
  return bindCaseInsensitivePropertyWithObservable<GElementNode, GCaseInsensitiveKey>(
    node,
    caseInsensitiveKey,
    unknownToObservableNotUndefined(value$) as any,
  );
}

