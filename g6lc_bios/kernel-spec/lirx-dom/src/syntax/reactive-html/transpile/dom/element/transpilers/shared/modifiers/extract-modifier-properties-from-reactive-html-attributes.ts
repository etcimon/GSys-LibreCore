import {
  extractModifierPropertyFromReactiveHTMLAttribute,
  IModifierProperty,
} from './extract-modifier-property-from-reactive-html-attribute';

export function extractModifierPropertiesFromReactiveHTMLAttributes(
  attributes: ArrayLike<Attr>,
): IModifierProperty[] {
  const modifiers: IModifierProperty[] = [];

  for (let i = 0, l = attributes.length; i < l; i++) {
    const attribute: Attr = attributes[i];
    const modifier: IModifierProperty | null = extractModifierPropertyFromReactiveHTMLAttribute(attribute);
    if (modifier !== null) {
      modifiers.push(modifier);
    }
  }

  return modifiers;
}

export function extractAndRemoveModifierPropertiesFromReactiveHTMLAttributes(
  attributes: ArrayLike<Attr>,
): IModifierProperty[] {
  const modifiers: IModifierProperty[] = extractModifierPropertiesFromReactiveHTMLAttributes(attributes);
  for (let i = 0, l = modifiers.length; i < l; i++) {
    const modifier: IModifierProperty = modifiers[i];
    if (modifier.attribute.ownerElement !== null) {
      modifier.attribute.ownerElement.removeAttribute(modifier.attribute.name);
    }
  }
  return modifiers;
}
