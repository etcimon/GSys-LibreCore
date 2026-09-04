import { IReactiveValue, extractReactiveValueFromString } from '../../../../misc/extract-reactive-value-from-string';

/**
 * Syntax:
 *  - standard: ($)?[name]
 *  - prefixed: bind-(input-)?name
 */

export interface IBindProperty {
  readonly name: string;
  readonly value: IReactiveValue;
  readonly prefixMode: boolean;
  readonly inputMode: boolean;
}

/*--------*/

const BIND_PROPERTY_BRACKET_PATTERN: string = '(\\$?)\\[([^\\]]+)\\]';
const BIND_PROPERTY_PREFIX_PATTERN: string = 'bind-(input-?)(.+)';
const BIND_PROPERTY_PATTERN: string = `(?:${BIND_PROPERTY_BRACKET_PATTERN})`
  + `|(?:${BIND_PROPERTY_PREFIX_PATTERN})`;
const BIND_PROPERTY_REGEXP: RegExp = new RegExp(`^${BIND_PROPERTY_PATTERN}$`);

export function extractBindPropertyFromReactiveHTMLAttribute(
  attribute: Attr,
): IBindProperty | null {
  const match: RegExpExecArray | null = BIND_PROPERTY_REGEXP.exec(attribute.name);
  if (match === null) {
    return null;
  } else {
    const prefixMode: boolean = (match[4] !== void 0);

    const value: string = attribute.value.trim();

    let name: string;
    let inputMode: boolean;

    if (prefixMode) {
      inputMode = match[3] !== '';
      name = match[4];
    } else {
      inputMode = match[1] !== '';
      name = match[2];
    }

    return {
      name,
      value: extractReactiveValueFromString(value),
      prefixMode,
      inputMode,
    };
  }
}




