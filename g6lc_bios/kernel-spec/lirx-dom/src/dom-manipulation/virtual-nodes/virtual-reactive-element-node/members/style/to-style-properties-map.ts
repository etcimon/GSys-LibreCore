import { IStyleProperty } from '../../../virtual-element-node/members/style/style-property.type';
import { IStylePropertiesMap } from './style-properties-map.type';
import { IStylePropertyLike, toStyleProperty } from './to-style-property';

export type IStylePropertiesMapAsString = string;

export type IStylePropertiesMapAsIterableEntryA = [
  name: string,
  value: string | null,
  priority?: string,
];

export type IStylePropertiesMapAsIterableEntryB = [
  name: string,
  property: IStylePropertyLike | null,
];

export type IStylePropertiesMapAsIterableEntry =
  | IStylePropertiesMapAsIterableEntryA
  | IStylePropertiesMapAsIterableEntryB
  ;

export type IStylePropertiesMapAsIterable = Iterable<IStylePropertiesMapAsIterableEntry>;

export type IStylePropertiesMapAsRecordEntry =
  | IStylePropertyLike
  | null
  ;

export type IStylePropertiesMapAsRecord = Record<string, IStylePropertiesMapAsRecordEntry>;

export type IStylePropertiesMapLike =
  | IStylePropertiesMap
  | IStylePropertiesMapAsString
  | IStylePropertiesMapAsIterable
  | IStylePropertiesMapAsRecord
  ;

/**
 * Converts a `string` or an `Iterable<[string, string]>` into a `IStylePropertiesMap`.
 */
export function toStylePropertiesMap(
  input: IStylePropertiesMapLike,
): IStylePropertiesMap {
  if (input instanceof Map) {
    return input;
  } else if (typeof input === 'string') {
    return stringToStylePropertiesMap(input);
  } else if (Symbol.iterator in input) {
    return iterableToStylePropertiesMap(input);
  } else {
    return recordToStylePropertiesMap(input);
  }
}

let STRING_TO_STYLE_PROPERTIES_MAP_ELEMENT: HTMLElement;

export function stringToStylePropertiesMap(
  input: string,
): IStylePropertiesMap {
  const stylePropertiesMap: IStylePropertiesMap = new Map<string, IStyleProperty>();

  if (STRING_TO_STYLE_PROPERTIES_MAP_ELEMENT === void 0) {
    STRING_TO_STYLE_PROPERTIES_MAP_ELEMENT = document.createElement('div');
  }
  STRING_TO_STYLE_PROPERTIES_MAP_ELEMENT.setAttribute('style', input);
  const style: CSSStyleDeclaration = STRING_TO_STYLE_PROPERTIES_MAP_ELEMENT.style;

  for (let i = 0; i < style.length; i++) {
    const name: string = style.item(i);
    stylePropertiesMap.set(name, {
      value: style.getPropertyValue(name),
      priority: style.getPropertyPriority(name),
    });
  }

  return stylePropertiesMap;
}

export function iterableToStylePropertiesMap(
  input: IStylePropertiesMapAsIterable,
): IStylePropertiesMap {
  const stylePropertiesMap: IStylePropertiesMap = new Map<string, IStyleProperty>();

  const iterator: Iterator<IStylePropertiesMapAsIterableEntry> = input[Symbol.iterator]();
  let result: IteratorResult<IStylePropertiesMapAsIterableEntry>;
  while (!(result = iterator.next()).done) {
    const entry: IStylePropertiesMapAsIterableEntry = result.value;
    if (entry[1] !== null) {
      const name: string = entry[0];
      let property: IStyleProperty;

      if (entry.length === 3) {
        property = {
          value: entry[1],
          priority: entry[2] ?? '',
        };
      } else {
        property = toStyleProperty(entry[1]);
      }

      stylePropertiesMap.set(name, property);
    }
  }

  return stylePropertiesMap;
}

export function recordToStylePropertiesMap(
  input: IStylePropertiesMapAsRecord,
): IStylePropertiesMap {
  const stylePropertiesMap: IStylePropertiesMap = new Map<string, IStyleProperty>();

  const entries = Object.entries(input);

  for (let i = 0, l = entries.length; i < l; i++) {
    const [name, entry]: [string, IStylePropertiesMapAsRecordEntry] = entries[i];

    if (entry !== null) {
      stylePropertiesMap.set(name, toStyleProperty(entry));
    }
  }

  return stylePropertiesMap;
}
