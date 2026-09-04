import { ISetStyleProperty, IStyleProperty } from '../../../virtual-element-node/members/style/style-property.type';

export type IStylePropertyAsString = string;
export type IStylePropertyAsTuple = [
  value: string,
  priority?: string,
];

export type IStylePropertyLike =
  | ISetStyleProperty
  | IStylePropertyAsString
  | IStylePropertyAsTuple
  ;

export function toStyleProperty(
  input: IStylePropertyLike,
): IStyleProperty {
  if (Array.isArray(input)) {
    return tupleToStyleProperty(input);
  } else if (typeof input === 'string') {
    return stringToStyleProperty(input);
  } else {
    return {
      priority: '',
      ...input,
    };
  }
}

export function stringToStyleProperty(
  input: string,
): IStyleProperty {
  const isImportant: boolean = input.trim().endsWith('!important');
  if (isImportant) {
    return {
      value: input.slice(0, -10).trim(),
      priority: 'important',
    };
  } else {
    return {
      value: input.trim(),
      priority: '',
    };
  }
}

export function tupleToStyleProperty(
  [
    value,
    priority = '',
  ]: IStylePropertyAsTuple,
): IStyleProperty {
  return {
    value,
    priority,
  };
}
