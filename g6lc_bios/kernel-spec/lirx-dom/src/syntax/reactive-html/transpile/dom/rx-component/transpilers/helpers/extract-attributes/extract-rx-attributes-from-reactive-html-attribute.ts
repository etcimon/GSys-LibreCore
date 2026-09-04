import { createInvalidAttributeFoundError } from '../../../../../../../misc/errors/create-invalid-attribute-found-error';
import { IMappedAttributes } from './mapped-attributes.type';

export function extractRXAttributesFromReactiveHTMLAttribute(
  attributes: ArrayLike<Attr>,
  expectedAttributes: Set<string>,
): IMappedAttributes {
  const mappedAttributes: IMappedAttributes = new Map<string, string>();
  for (let i = 0, l = attributes.length; i < l; i++) {
    const attribute: Attr = attributes[i];
    if (expectedAttributes.has(attribute.name)) {
      mappedAttributes.set(attribute.name, attribute.value);
    } else {
      throw createInvalidAttributeFoundError(attribute);
    }
  }
  return mappedAttributes;
}

// export function extractRXAttributesFromReactiveHTMLAttribute(
//   attributes: ArrayLike<Attr>,
//   expectedAttributes: Set<string>,
// ): IMappedAttributes {
//   const result: IExtractRXAttributesAndLetPropertiesFromReactiveHTMLAttributeResult = extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute(
//     attributes,
//     expectedAttributes,
//   );
//   if (result.letProperties.length > 0) {
//     throw createInvalidAttributeFoundError(attribute);
//   } else {
//     return result.attributes;
//   }
// }
