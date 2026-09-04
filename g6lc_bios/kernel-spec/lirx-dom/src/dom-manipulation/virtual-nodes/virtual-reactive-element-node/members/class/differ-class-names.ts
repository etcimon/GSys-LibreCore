import { IClassNamesList } from './class-names-list.type';

export function differClassNames(
  previousClassNames: IClassNamesList,
  classNames: IClassNamesList,
): string[] {
  const nextClassNames: string[] = [];
  const iterator: Iterator<string> = classNames.values();
  let result: IteratorResult<string>;
  while (!(result = iterator.next()).done) {
    if (previousClassNames.has(result.value)) {
      previousClassNames.delete(result.value);
    } else {
      nextClassNames.push(result.value);
    }
  }
  return nextClassNames;
}
