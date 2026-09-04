import { ILines } from '../../../../../../misc/lines/lines.type';
import { IReactiveValue, IReactiveValueType } from '../../../../misc/extract-reactive-value-from-string';

export function transpileAOTReactiveValueToJSLines(
  {
    value,
    type,
  }: IReactiveValue,
): ILines {
  if (type === 'raw') {
    return [value];
  } else if (type === 'computed') {
    return [`() => (${value})`];
  } else {
    throw new Error(`Invalid reactive value mode: ${type}`);
  }
}

export function transpileAOTReactiveValueTypeToFunctionName(
  name: string,
  type: IReactiveValueType,
): string {
  if (type === 'raw') {
    return name;
  } else if (type === 'computed') {
    return `${name}_computed`;
  } else {
    throw new Error(`Invalid reactive value mode: ${type}`);
  }
}


