/**
 * Syntax:
 *  - raw: "value"
 *  - computed: "=> expression"
 */

export type IReactiveValueType =
  | 'raw'
  | 'computed'
  ;

export interface IReactiveValue {
  readonly value: string;
  readonly type: IReactiveValueType;
}

/*--------*/

const EVAL_REACTIVE_VALUE_REGEXP: RegExp = new RegExp(`^\\s*=>\\s*(.*)$`);

export function extractReactiveValueFromString(
  value: string,
): IReactiveValue {
  EVAL_REACTIVE_VALUE_REGEXP.lastIndex = 0;

  const match: RegExpExecArray | null = EVAL_REACTIVE_VALUE_REGEXP.exec(value);
  if (match === null) {
    return {
      value,
      type: 'raw',
    };
  } else {
    return {
      value: match[1],
      type: 'computed',
    };
  }
}
