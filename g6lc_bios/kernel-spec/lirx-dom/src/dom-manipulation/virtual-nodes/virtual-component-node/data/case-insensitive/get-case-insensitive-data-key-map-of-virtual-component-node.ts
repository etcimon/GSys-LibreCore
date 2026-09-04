import { VirtualComponentNode } from '../../virtual-component-node.class';
import { CaseInsensitiveKeyMap, IGenericCaseInsensitiveKeyMap } from '../../../../../misc/classes/case-insensitive-key-map.class';

export type InferVirtualComponentNodeDataStringKeys<GData extends object> = Extract<keyof GData, string>

export function getCaseInsensitiveDataKeyMapOfVirtualComponentNode<GData extends object>(
  node: VirtualComponentNode<any, GData>,
): CaseInsensitiveKeyMap<InferVirtualComponentNodeDataStringKeys<GData>> {
  return getCaseInsensitiveDataKeyMapCached<GData>(node.data);
}

const CACHE = new WeakMap<object, IGenericCaseInsensitiveKeyMap>();

function getCaseInsensitiveDataKeyMapCached<GData extends object>(
  data: GData,
): CaseInsensitiveKeyMap<InferVirtualComponentNodeDataStringKeys<GData>> {
  let map: CaseInsensitiveKeyMap<InferVirtualComponentNodeDataStringKeys<GData>> | undefined = CACHE.get(data) as CaseInsensitiveKeyMap<InferVirtualComponentNodeDataStringKeys<GData>> | undefined;
  if (map === void 0) {
    map = getCaseInsensitiveDataKeyMap<GData>(data);
    CACHE.set(data, map);
  }
  return map;
}

function getCaseInsensitiveDataKeyMap<GData extends object>(
  data: GData,
): CaseInsensitiveKeyMap<InferVirtualComponentNodeDataStringKeys<GData>> {
  return new CaseInsensitiveKeyMap<InferVirtualComponentNodeDataStringKeys<GData>>(
    Object.keys(data) as InferVirtualComponentNodeDataStringKeys<GData>[],
  );
}
