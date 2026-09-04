/**
 * Syntax:
 *  - standard: ($)?(name) or  ($)?{name}
 *  - prefixed: on-(output-)?name(-observable)?
 */

export interface IEventProperty {
  readonly name: string;
  readonly value: string;
  readonly prefixMode: boolean;
  readonly outputMode: boolean;
  readonly observableMode: boolean;
}

/*--------*/

const EVENT_ATTRIBUTE_ROUND_BRACKET_PATTERN: string = '(?:\\([^\\)]+\\))';
const EVENT_ATTRIBUTE_CURLY_BRACKET_PATTERN: string = '(?:\\{[^\\}]+\\})';
const EVENT_ATTRIBUTE_BRACKET_PATTERN: string = `(\\$?)(${EVENT_ATTRIBUTE_ROUND_BRACKET_PATTERN}|${EVENT_ATTRIBUTE_CURLY_BRACKET_PATTERN})`;
const EVENT_ATTRIBUTE_PREFIX_PATTERN: string = 'on-(output-?)(.+)(-observable?)';
const EVENT_ATTRIBUTE_PATTERN: string = `(?:${EVENT_ATTRIBUTE_BRACKET_PATTERN})`
  + `|(?:${EVENT_ATTRIBUTE_PREFIX_PATTERN})`;
const EVENT_ATTRIBUTE_REGEXP: RegExp = new RegExp(`^${EVENT_ATTRIBUTE_PATTERN}$`);

export function extractEventPropertyFromReactiveHTMLAttribute(
  attribute: Attr,
): IEventProperty | null {
  const match: RegExpExecArray | null = EVENT_ATTRIBUTE_REGEXP.exec(attribute.name);
  if (match === null) {
    return null;
  } else {
    const prefixMode: boolean = (match[3] !== void 0);

    const value: string = attribute.value.trim();

    let name: string;
    let outputMode: boolean;
    let observableMode: boolean;

    if (prefixMode) {
      outputMode = match[3] !== '';
      observableMode = match[5] !== '';
      name = match[4].slice(1, -1);
    } else {
      outputMode = match[1] !== '';
      observableMode = match[2].startsWith('{');
      name = match[2].slice(1, -1);
    }

    return {
      name,
      value,
      prefixMode,
      outputMode,
      observableMode,
    };
  }
}




