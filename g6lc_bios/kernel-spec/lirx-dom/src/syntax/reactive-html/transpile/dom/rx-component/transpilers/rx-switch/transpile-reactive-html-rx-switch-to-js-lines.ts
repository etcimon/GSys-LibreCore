import { isElementNode } from '../../../../../../../dom-manipulation/helpers/is/node-type/is-element-node';
import {
  isTextNodeWithNonWhiteSpaceCharacters,
} from '../../../../../../../dom-manipulation/helpers/is/node-type/is-text-node-with-non-white-space-characters';
import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { createInvalidElementFoundError } from '../../../../../../misc/errors/create-invalid-element-found-error';
import { createMissingAttributeError } from '../../../../../../misc/errors/create-missing-attribute-error';
import { createShouldNotContainTextNodeError } from '../../../../../../misc/errors/create-should-not-contain-text-node-error';
import { createSwitchDefaultAlreadyDefinedError } from '../../../../../../misc/errors/create-switch-default-already-defined-error';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { NULL_TEMPLATE } from '../../../../../../misc/templates/null-template.constant';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap,
} from '../../../../primary/transpilers/transpile-create-reactive-switch-node-to-js-lines.type';
import {
  extractRXAttributesFromReactiveHTMLAttribute,
} from '../helpers/extract-attributes/extract-rx-attributes-from-reactive-html-attribute';
import { IMappedAttributes } from '../helpers/extract-attributes/mapped-attributes.type';
import { generateJSLinesForRXSwitch } from './generate-reactive-dom-js-lines-for-rx-switch';
import { transpileReactiveHTMLRXSwitchCaseToJSLines } from './rx-switch-case/transpile-reactive-html-rx-switch-case-to-js-lines';
import { transpileReactiveHTMLRXSwitchDefaultToJSLines } from './rx-switch-default/transpile-reactive-html-rx-switch-default-to-js-lines';
import { extractReactiveValueFromString } from '../../../../misc/extract-reactive-value-from-string';

const TAG_NAME: string = 'rx-switch';

const EXPRESSION_ATTRIBUTE_NAME: string = 'expression';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  EXPRESSION_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXSwitchToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXSwitchToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLRXSwitchToJSLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);
  if (name === TAG_NAME) {
    let expression!: string;
    const templatesMap: ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap = new Map<string, ILines>();
    let defaultTemplate!: ILinesOrNull;

    const attributes: IMappedAttributes = extractRXAttributesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    /* EXPRESSION */
    const expressionAttribute: string | undefined = attributes.get(EXPRESSION_ATTRIBUTE_NAME);

    if (expressionAttribute === void 0) {
      throw createMissingAttributeError(EXPRESSION_ATTRIBUTE_NAME, node);
    } else {
      expression = expressionAttribute;
    }

    // ANALYSE CHILD NODES -> TO extract templates
    const childNodes: ArrayLike<ChildNode> = node.childNodes;

    for (let i = 0, l = childNodes.length; i < l; i++) {
      const childNode: ChildNode = childNodes[i];
      if (isElementNode(childNode)) {
        const result: ILinesOrNull = transpileReactiveHTMLRXSwitchCaseToJSLines({
          ...options,
          node: childNode,
          templatesMap,
        });
        if (result === null) {
          const result: ILinesOrNull = transpileReactiveHTMLRXSwitchDefaultToJSLines({
            ...options,
            node: childNode,
          });
          if (result === null) {
            throw createInvalidElementFoundError(childNode);
          } else {
            if (defaultTemplate === void 0) {
              defaultTemplate = result;
            } else {
              throw createSwitchDefaultAlreadyDefinedError(node);
            }
          }
        }
      } else if (isTextNodeWithNonWhiteSpaceCharacters(childNode)) {
        throw createShouldNotContainTextNodeError(node);
      }
    }

    if (defaultTemplate === void 0) {
      defaultTemplate = [NULL_TEMPLATE];
    }

    return generateJSLinesForRXSwitch({
      ...options,
      expression: extractReactiveValueFromString(expression),
      templatesMap,
      defaultTemplate,
    });
  } else {
    return null;
  }
}


