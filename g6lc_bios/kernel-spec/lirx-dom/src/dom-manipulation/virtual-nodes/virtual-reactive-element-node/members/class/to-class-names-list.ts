import { IClassNamesList } from './class-names-list.type';

export type IClassNamesListAsString = string;
export type IClassNamesListAsIterable = Iterable<string>;

export type IClassNamesListLike =
  | IClassNamesList
  | IClassNamesListAsString
  | IClassNamesListAsIterable
  ;

/**
 * Converts a `string`, an `Iterable<string>` or a `Set<string>`  into a `IClassNamesList` (alias for `Set<string>`).
 */
export function toClassNamesList(
  input: IClassNamesListLike,
): IClassNamesList {
  if (input instanceof Set) {
    return input;
  } else if (typeof input === 'string') {
    return stringToClassNamesList(input);
  } else {
    return new Set<string>(input);
  }
}

export function stringToClassNamesList(
  input: IClassNamesListAsString,
): IClassNamesList {
  return new Set<string>(
    input.trim().split(/\s+/),
  );
}
