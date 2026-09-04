import {
  getCaseInsensitiveDataKeyMapOfVirtualComponentNode,
  InferVirtualComponentNodeDataStringKeys,
} from './get-case-insensitive-data-key-map-of-virtual-component-node';
import { VirtualComponentNode } from '../../virtual-component-node.class';
import { InferCaseInsensitiveKeyMapGetReturn } from '../../../../../misc/classes/case-insensitive-key-map.class';

export type InferCaseInsensitiveDataKeyOfVirtualComponentNode<GData extends object, GCaseInsensitiveKey extends string> =
  Extract<InferCaseInsensitiveKeyMapGetReturn<InferVirtualComponentNodeDataStringKeys<GData>, GCaseInsensitiveKey>, keyof GData>;

export function getCaseInsensitiveDataKeyOfVirtualComponentNode<GData extends object, GCaseInsensitiveKey extends string>(
  node: VirtualComponentNode<any, GData>,
  key: GCaseInsensitiveKey,
): InferCaseInsensitiveDataKeyOfVirtualComponentNode<GData, GCaseInsensitiveKey> {
  return getCaseInsensitiveDataKeyMapOfVirtualComponentNode<GData>(node).get<GCaseInsensitiveKey>(key) as any;
}
