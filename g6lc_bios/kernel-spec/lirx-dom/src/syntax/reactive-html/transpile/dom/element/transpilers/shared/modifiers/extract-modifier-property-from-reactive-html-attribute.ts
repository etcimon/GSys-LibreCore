/**
 * Syntax:
 *  - standard: #name
 *  - prefixed: mod-name
 */
export interface IModifierProperty {
  readonly weight: number | undefined;
  readonly name: string;
  readonly value: string;
  readonly prefixMode: boolean;
  readonly attribute: Attr;
}

/*--------*/

const MODIFIER_ATTRIBUTE_BRACKET_PATTERN: string = '\\#([^\\)]+)';
const MODIFIER_ATTRIBUTE_PREFIX_PATTERN: string = 'mod-(.+)';
const MODIFIER_ATTRIBUTE_PATTERN: string = `(?:${MODIFIER_ATTRIBUTE_BRACKET_PATTERN})`
  + `|(?:${MODIFIER_ATTRIBUTE_PREFIX_PATTERN})`;
const MODIFIER_ATTRIBUTE_REGEXP: RegExp = new RegExp(`^${MODIFIER_ATTRIBUTE_PATTERN}$`);

const MODIFIER_NAME_WEIGHT_PATTERN: string = '(-?\\d+)-(.*)';
const MODIFIER_NAME_WEIGHT_REGEXP: RegExp = new RegExp(`^${MODIFIER_NAME_WEIGHT_PATTERN}$`);

export function extractModifierPropertyFromReactiveHTMLAttribute(
  attribute: Attr,
): IModifierProperty | null {
  const match: RegExpExecArray | null = MODIFIER_ATTRIBUTE_REGEXP.exec(attribute.name);
  if (match === null) {
    return null;
  } else {
    const prefixMode: boolean = (match[2] !== void 0);

    let weight: number | undefined = void 0;
    let name: string = prefixMode ? match[2] : match[1];
    const value: string = attribute.value.trim();

    const matchWeight: RegExpExecArray | null = MODIFIER_NAME_WEIGHT_REGEXP.exec(name);
    if (matchWeight != null) {
      name = matchWeight[2];
      weight = Number(matchWeight[1]);
    }

    return {
      weight,
      name,
      value,
      prefixMode,
      attribute,
    };
  }
}
