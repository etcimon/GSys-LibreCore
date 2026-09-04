import { VirtualReactiveElementNode } from '../../../virtual-reactive-element-node.class';
import {
  getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNode,
} from './get-case-insensitive-property-key-map-of-virtual-reactive-element-node';
import { InferCaseInsensitiveKeyMapGetReturn } from '../../../../../../misc/classes/case-insensitive-key-map.class';
import { InferElementKeys } from '../infer-element-keys.type';

export type InferCaseInsensitivePropertyKeyOfVirtualReactiveElementNode<GElementNode extends Element, GCaseInsensitiveKey extends string> =
  InferCaseInsensitiveKeyMapGetReturn<InferElementKeys<GElementNode>, GCaseInsensitiveKey>;

export function getCaseInsensitivePropertyKeyOfVirtualReactiveElementNode<GElementNode extends Element, GCaseInsensitiveKey extends string>(
  node: VirtualReactiveElementNode<GElementNode>,
  key: GCaseInsensitiveKey,
): InferCaseInsensitivePropertyKeyOfVirtualReactiveElementNode<GElementNode, GCaseInsensitiveKey> {
  return getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNode<GElementNode>(node).get<GCaseInsensitiveKey>(key);
}
