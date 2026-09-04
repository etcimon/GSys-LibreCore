import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { throwIfHasChildNodes } from '../../../../../../../dom-manipulation/helpers/misc/throw-if-has-child-nodes';
import { createMissingAttributeError } from '../../../../../../misc/errors/create-missing-attribute-error';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { transpileReactiveHTMLElementToJSLines } from '../../../element/transpile-reactive-html-element-to-js-lines';
import {
  extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute,
} from '../helpers/extract-attributes/extract-rx-attributes-and-let-properties-from-reactive-html-attribute';
import {
  generateLetPropertyLinesForInjectTemplate,
} from '../helpers/for-rx-template/let-properties/generate-let-property-lines-for-inject-template';
import { transpileReactiveHTMLRXInjectSlotChildNodesToLines } from './transpile-reactive-html-rx-inject-slot-child-nodes-to-lines';

/*
Syntax:

<rx-inject-slot
  name="slotName"
>
  default content
</rx-inject-slot>

// <div *inject-slot="slotName">
//   default content
// </div>

 */

const TAG_NAME: string = 'rx-inject-slot';
const COMMAND_NAME: string = '*inject-slot';

const SLOT_NAME_ATTRIBUTE_NAME: string = 'name';
const REQUIRED_ATTRIBUTE_NAME: string = 'required';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  SLOT_NAME_ATTRIBUTE_NAME,
  REQUIRED_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXInjectSlotToLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

// TODO migrate to transpileReactiveHTMLRXChildTemplateToJSLines

export function transpileReactiveHTMLRXInjectSlotToLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLRXInjectSlotToLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);
  if (name === TAG_NAME) {
    let slotName!: string;
    let required!: boolean;

    const { attributes, letProperties } = extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    /* NAME */
    const slotNameAttribute: string | undefined = attributes.get(SLOT_NAME_ATTRIBUTE_NAME);

    if (slotNameAttribute === void 0) {
      throw createMissingAttributeError(SLOT_NAME_ATTRIBUTE_NAME, node);
    } else {
      slotName = slotNameAttribute;
    }

    /* REQUIRED */
    const requiredAttribute: string | undefined = attributes.get(REQUIRED_ATTRIBUTE_NAME);

    if (requiredAttribute === void 0) {
      required = false;
      // throw createMissingAttributeError(REQUIRED_ATTRIBUTE_NAME, node);
    } else {
      required = (requiredAttribute !== 'false');
    }

    if (required) {
      throwIfHasChildNodes(node);
    }

    return transpileReactiveHTMLRXInjectSlotChildNodesToLines({
      ...options,
      slotName,
      required,
      nodes: node.childNodes,
      letPropertiesLines: generateLetPropertyLinesForInjectTemplate(letProperties, node),
    });
  } else if (node.hasAttribute(COMMAND_NAME)) {
    const slotName: string = node.getAttribute(COMMAND_NAME) as string;
    node.removeAttribute(COMMAND_NAME);

    // TODO improve => remove the necessity to create a new node
    const element = document.createElement(TAG_NAME);
    element.setAttribute(SLOT_NAME_ATTRIBUTE_NAME, slotName);
    while (node.firstChild !== null) {
      element.appendChild(node.firstChild);
    }

    node.appendChild(element);

    return transpileReactiveHTMLElementToJSLines({
      ...options,
      node,
    });
  } else {
    return null;
  }
}
