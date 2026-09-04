import { CaseInsensitiveKeyMap, IGenericCaseInsensitiveKeyMap } from '../../../../../../misc/classes/case-insensitive-key-map.class';
import { VirtualReactiveElementNode } from '../../../virtual-reactive-element-node.class';
import { InferElementKeys } from '../infer-element-keys.type';

export function getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNode<GElementNode extends Element>(
  node: VirtualReactiveElementNode<GElementNode>,
): CaseInsensitiveKeyMap<InferElementKeys<GElementNode>> {
  return getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNodeElement<GElementNode>(node.elementNode);
}

function getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNodeElement<GElementNode extends Element>(
  element: GElementNode,
): CaseInsensitiveKeyMap<InferElementKeys<GElementNode>> {
  return getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNodeElementConstructor<GElementNode>(Object.getPrototypeOf(element));
}

const CACHE = new WeakMap<Element, IGenericCaseInsensitiveKeyMap>();

function getCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNodeElementConstructor<GElementNode extends Element>(
  elementPrototype: GElementNode,
): CaseInsensitiveKeyMap<InferElementKeys<GElementNode>> {
  let map: IGenericCaseInsensitiveKeyMap | undefined = CACHE.get(elementPrototype);
  if (map === void 0) {
    map = createCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNodeElementPrototype<GElementNode>(elementPrototype);
    CACHE.set(elementPrototype, map);
  }
  return map as CaseInsensitiveKeyMap<InferElementKeys<GElementNode>>;
}

function createCaseInsensitivePropertyKeyMapOfVirtualReactiveElementNodeElementPrototype<GElementNode extends Element>(
  elementPrototype: GElementNode,
): CaseInsensitiveKeyMap<InferElementKeys<GElementNode>> {
  const keys: string[] = [];

  for (const key in elementPrototype) {
    keys.push(key);
  }

  return new CaseInsensitiveKeyMap<InferElementKeys<GElementNode>>(keys as InferElementKeys<GElementNode>[]);
}
