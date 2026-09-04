import { createInvalidAttributeFoundError } from '../../../../../../../misc/errors/create-invalid-attribute-found-error';
import { extractLetPropertyFromReactiveHTMLAttribute, ILetProperty } from './extract-let-property-from-reactive-html-attribute';
import { IMappedAttributes } from './mapped-attributes.type';

export interface IExtractRXAttributesAndLetPropertiesFromReactiveHTMLAttributeResult {
  readonly attributes: IMappedAttributes;
  readonly letProperties: ILetProperty[];
}

export function extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute(
  attributes: ArrayLike<Attr>,
  expectedAttributes: Set<string>,
): IExtractRXAttributesAndLetPropertiesFromReactiveHTMLAttributeResult {
  const mappedAttributes: IMappedAttributes = new Map<string, string>();
  const letProperties: ILetProperty[] = [];

  for (let i = 0, l = attributes.length; i < l; i++) {
    const attribute: Attr = attributes[i];
    if (expectedAttributes.has(attribute.name)) {
      mappedAttributes.set(attribute.name, attribute.value);
    } else {
      const letProperty: ILetProperty | null = extractLetPropertyFromReactiveHTMLAttribute(attribute);
      if (letProperty === null) {
        throw createInvalidAttributeFoundError(attribute);
      } else {
        letProperties.push(letProperty);
      }
    }
  }

  return {
    attributes: mappedAttributes,
    letProperties,
  };
}
