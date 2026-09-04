import { ILines } from '../../../../../../misc/lines/lines.type';
import { IReactiveValue } from '../../../../misc/extract-reactive-value-from-string';

export function transpileReactiveValueToJSLines(
  {
    value,
    type,
  }: IReactiveValue,
): ILines {
  if (type === 'raw') {
    return [`unknownToObservableNotUndefined(${value})`];
  } else if (type === 'computed') {
    return [`computationToObservable(() => (${value}))`];
  } else {
    throw new Error(`Invalid reactive value mode: ${type}`);
  }
}




