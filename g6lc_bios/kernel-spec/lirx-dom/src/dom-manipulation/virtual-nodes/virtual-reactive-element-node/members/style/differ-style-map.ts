import { ISetStylePropertyOrNull } from '../../../virtual-element-node/members/style/style-property.type';
import { IStylePropertiesMap } from './style-properties-map.type';
import { IStylePropertyAndValueTuple } from './style-property-and-value-tuple';

/**
 * Removes from 'previousStyles' values in 'styles' (keep only styles to remove)
 * Appends in 'nextStyles' the list of new styles (styles to add / update)
 * @param previousStyles
 * @param styles - list of styles to set / update
 */
export function differStylePropertiesMap(
  previousStyles: IStylePropertiesMap,
  styles: IStylePropertiesMap,
): IStylePropertyAndValueTuple[] {
  const nextStyles: [string, ISetStylePropertyOrNull][] = [];
  const iterator: IterableIterator<[string, ISetStylePropertyOrNull]> = styles.entries();
  let result: IteratorResult<[string, ISetStylePropertyOrNull]>;
  while (!(result = iterator.next()).done) {
    const [key, styleProperty] = result.value;
    if (previousStyles.has(key)) {
      if (generateStylePropertyKey(previousStyles.get(key) as ISetStylePropertyOrNull) !== generateStylePropertyKey(styleProperty)) {
        nextStyles.push([key, styleProperty]);
      }
      previousStyles.delete(key);
    } else {
      nextStyles.push([key, styleProperty]);
    }
  }

  return nextStyles;
}

type IStylePropertyKey = string | null;

function generateStylePropertyKey(
  property: ISetStylePropertyOrNull,
): IStylePropertyKey {
  return (property === null)
    ? null
    : `${JSON.stringify(property.value)}-${JSON.stringify(property.priority ?? '')}`;
}
