import { IObservable } from '@lirx/core';
import { IUnsubscribe } from '@lirx/unsubscribe';
import { VirtualReactiveElementNode } from '../../../../virtual-reactive-element-node.class';
import {
  getCaseInsensitivePropertyKeyOfVirtualReactiveElementNode,
  InferCaseInsensitivePropertyKeyOfVirtualReactiveElementNode,
} from '../get-case-insensitive-property-key-of-virtual-reactive-element-node';
import { InferCaseInsensitiveObjectKey } from '../../../../../../../misc/types/infer-case-insensitive-object-key.type';

export type InferBindCaseInsensitivePropertyWithObservableValue<GElementNode extends Element, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveObjectKey<GElementNode, GCaseInsensitiveKey> extends never
    ? never
    : IObservable<GElementNode[InferCaseInsensitiveObjectKey<GElementNode, GCaseInsensitiveKey>]>
  ;

export function bindCaseInsensitivePropertyWithObservable<GElementNode extends Element, GCaseInsensitiveKey extends string>(
  node: VirtualReactiveElementNode<GElementNode>,
  caseInsensitiveKey: GCaseInsensitiveKey,
  value$: InferBindCaseInsensitivePropertyWithObservableValue<GElementNode, GCaseInsensitiveKey>,
): IUnsubscribe {
  type GKey = Extract<InferCaseInsensitivePropertyKeyOfVirtualReactiveElementNode<GElementNode, GCaseInsensitiveKey>, keyof GElementNode>;
  return node.setReactiveProperty<GKey>(
    getCaseInsensitivePropertyKeyOfVirtualReactiveElementNode<GElementNode, GCaseInsensitiveKey>(node, caseInsensitiveKey) as GKey,
    value$ as unknown as IObservable<GElementNode[GKey]>,
  );
}
