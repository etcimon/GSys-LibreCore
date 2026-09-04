import { getElementTagName } from '../../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { dashCaseToCamelCase } from '../../../../../../../misc/case-converters/dash-case';
import { createInvalidSlotNameError } from '../../../../../../../misc/errors/create-invalid-slot-name-error';
import { createMissingAttributeError } from '../../../../../../../misc/errors/create-missing-attribute-error';
import { createSlotAlreadyExistsError } from '../../../../../../../misc/errors/create-slot-already-exists-error';
import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import {
  ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap,
} from '../../../../../primary/transpilers/transpile-create-reactive-custom-element-node-to-js-lines.type';
import { transpileReactiveHTMLNodesToJSLines } from '../../../../nodes/transpile-reactive-html-nodes-to-js-lines';
import {
  ILetProperty,
} from '../../../../rx-component/transpilers/helpers/extract-attributes/extract-let-property-from-reactive-html-attribute';
import {
  extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute,
} from '../../../../rx-component/transpilers/helpers/extract-attributes/extract-rx-attributes-and-let-properties-from-reactive-html-attribute';
import {
  generateJSLinesForRXTemplate,
} from '../../../../rx-component/transpilers/helpers/for-rx-template/generate-js-lines-for-rx-template';
import {
  generateLetPropertyLinesForInjectTemplate,
} from '../../../../rx-component/transpilers/helpers/for-rx-template/let-properties/generate-let-property-lines-for-inject-template';
import {
  generateLetPropertyLinesForTemplate,
} from '../../../../rx-component/transpilers/helpers/for-rx-template/let-properties/generate-let-property-lines-for-template';
import {
  transpileReactiveHTMLRXInjectSlotChildNodesToLines,
} from '../../../../rx-component/transpilers/rx-inject-slot/transpile-reactive-html-rx-inject-slot-child-nodes-to-lines';
import { transpileReactiveHTMLElementToJSLines } from '../../../transpile-reactive-html-element-to-js-lines';
import { DEFAULT_SLOT_NAME_CONSTANT } from './default-slot-name.constant';

/*
Syntax:

<rx-slot
  name="slotName"
>
  content
</rx-slot>

// <div *slot="slotName">
//   content
// </div>

 */

export const RX_SLOT_TAG_NAME = 'rx-slot';
export const RX_SLOT_COMMAND = '*slot';

const NAME_ATTRIBUTE_NAME: string = 'name';
const PROXY_ATTRIBUTE_NAME: string = 'proxy';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  NAME_ATTRIBUTE_NAME,
  PROXY_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLCustomElementChildElementToSlotsOfJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly defaultSlotBodyLines: ILines; // mutable reference
  readonly slots: ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap;
}

export function transpileReactiveHTMLCustomElementChildElementToSlotsOfJSLines(
  {
    node,
    defaultSlotBodyLines,
    slots,
    ...options
  }: ITranspileReactiveHTMLCustomElementChildElementToSlotsOfJSLinesOptions,
): void {
  if (getElementTagName(node) === RX_SLOT_TAG_NAME) {
    const { attributes, letProperties } = extractRXAttributesAndLetPropertiesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    const name: string | undefined = attributes.get(NAME_ATTRIBUTE_NAME);
    const proxy: string | undefined = attributes.get(PROXY_ATTRIBUTE_NAME);

    if (name === void 0) {
      if (proxy === void 0) {
        throw createMissingAttributeError('name', node);
      } else {
        generateProxySlot({
          ...options,
          node,
          slots,
          proxyName: proxy,
          letProperties,
        });
      }
    } else if (name === DEFAULT_SLOT_NAME_CONSTANT) {
      throw createInvalidSlotNameError(DEFAULT_SLOT_NAME_CONSTANT, node);
    } else if (slots.has(name)) {
      throw createSlotAlreadyExistsError(name, node.parentElement!);
    } else {
      if (proxy === void 0) {
        slots.set(name, generateJSLinesForRXTemplate({
          argumentsLines: generateLetPropertyLinesForTemplate(letProperties),
          bodyLines: transpileReactiveHTMLNodesToJSLines({
            ...options,
            nodes: node.childNodes,
          }),
        }));
      } else {
        const proxyName: string = (proxy === '')
          ? name
          : proxy;

        generateProxySlot({
          ...options,
          node,
          slots,
          proxyName,
          letProperties,
        });
      }
    }
  } else {
    let name: string | null = node.getAttribute(RX_SLOT_COMMAND);
    if (name === null) {
      const lines: ILinesOrNull = transpileReactiveHTMLElementToJSLines({
        ...options,
        node: node as Element,
      });
      if (lines !== null) {
        defaultSlotBodyLines.push(...lines);
      }
    } else if (name === DEFAULT_SLOT_NAME_CONSTANT) {
      throw createInvalidSlotNameError(DEFAULT_SLOT_NAME_CONSTANT, node);
    } else if (slots.has(name)) {
      throw createSlotAlreadyExistsError(name, node.parentElement!);
    } else {
      node.removeAttribute(RX_SLOT_COMMAND);

      slots.set(name, generateJSLinesForRXTemplate({
        argumentsLines: null,
        bodyLines: transpileReactiveHTMLElementToJSLines({
          ...options,
          node: node as Element,
        }),
      }));
    }
  }
}

/*---*/

interface IGenerateProxySlotOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly slots: ITranspileCreateReactiveCustomElementNodeToJSLinesOptionsSlotsMap;
  readonly proxyName: string;
  readonly letProperties: ILetProperty[];
}

function generateProxySlot(
  {
    node,
    slots,
    proxyName,
    letProperties,
    ...options
  }: IGenerateProxySlotOptions,
): void {
  const letPropertiesForParent: ILetProperty[] = letProperties.map(({ name, value }: ILetProperty): ILetProperty => {
    name = dashCaseToCamelCase(name);
    value = dashCaseToCamelCase(value);
    return {
      name: value,
      value: name,
    };
  });

  const letPropertiesForChild: ILetProperty[] = letProperties.map(({ name }: ILetProperty): ILetProperty => {
    name = dashCaseToCamelCase(name);
    return {
      name,
      value: name,
    };
  });

  slots.set(proxyName, generateJSLinesForRXTemplate({
    argumentsLines: generateLetPropertyLinesForTemplate(letPropertiesForParent),
    bodyLines: transpileReactiveHTMLRXInjectSlotChildNodesToLines({
      ...options,
      slotName: proxyName,
      required: false, // TODO
      nodes: node.childNodes,
      letPropertiesLines: generateLetPropertyLinesForInjectTemplate(letPropertiesForChild, node),
    }),
  }));
}
