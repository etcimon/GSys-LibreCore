import { isElementNode } from '../../../../../../../dom-manipulation/helpers/is/node-type/is-element-node';
import {
  isTextNodeWithNonWhiteSpaceCharacters,
} from '../../../../../../../dom-manipulation/helpers/is/node-type/is-text-node-with-non-white-space-characters';
import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import {
  createAtLeastOneOfTheseAttributesIsRequiredError,
} from '../../../../../../misc/errors/create-at-least-one-of-these-attributes-is-required-error';
import { createDuplicateTemplateError } from '../../../../../../misc/errors/create-duplicate-template-error';
import { createInvalidElementFoundError } from '../../../../../../misc/errors/create-invalid-element-found-error';
import { createMissingAttributeError } from '../../../../../../misc/errors/create-missing-attribute-error';
import { createShouldNotContainTextNodeError } from '../../../../../../misc/errors/create-should-not-contain-text-node-error';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { generateTemplateVariableName } from '../../../../../../misc/templates/generate-template-variable-name';
import { NULL_TEMPLATE } from '../../../../../../misc/templates/null-template.constant';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  extractRXAttributesFromReactiveHTMLAttribute,
} from '../helpers/extract-attributes/extract-rx-attributes-from-reactive-html-attribute';
import { IMappedAttributes } from '../helpers/extract-attributes/mapped-attributes.type';
import {
  generateJSLinesForRXTemplateFromRXContainerOrElement,
} from '../helpers/for-rx-template/generate-js-lines-for-rx-template-from-rx-container-or-element';
import { generateJSLinesForRXAsync } from './generate-js-lines-for-rx-async';
import {
  transpileReactiveHTMLRXAsyncFulfilledToJSLines,
} from './rx-async-fulfilled/transpile-reactive-html-rx-async-fulfilled-to-js-lines';
import { transpileReactiveHTMLRXAsyncPendingToJSLines } from './rx-async-pending/transpile-reactive-html-rx-async-pending-to-js-lines';
import { transpileReactiveHTMLRXAsyncRejectedToJSLines } from './rx-async-rejected/transpile-reactive-html-rx-async-rejected-to-js-lines';

/*
Syntax:

<rx-async
  expression="observable"
  pending="templatePending"
  fulfilled="templateFulfilled"
  rejected="templateRejected"
></rx-async>

 */

const TAG_NAME: string = 'rx-async';
const COMMAND_NAME: string = '*async';

const EXPRESSION_ATTRIBUTE_NAME: string = 'expression';
const TEMPLATE_PENDING_ATTRIBUTE_NAME: string = 'pending';
const TEMPLATE_FULFILLED_ATTRIBUTE_NAME: string = 'fulfilled';
const TEMPLATE_REJECTED_ATTRIBUTE_NAME: string = 'rejected';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  EXPRESSION_ATTRIBUTE_NAME,
  TEMPLATE_PENDING_ATTRIBUTE_NAME,
  TEMPLATE_FULFILLED_ATTRIBUTE_NAME,
  TEMPLATE_REJECTED_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXAsyncToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXAsyncToJSLines(
  {
    node,
    ...options
  }: ITranspileReactiveHTMLRXAsyncToJSLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);
  if (name === TAG_NAME) {
    let expression!: string;
    let templatePending!: ILines;
    let templateFulfilled!: ILines;
    let templateRejected!: ILines;

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

    /* TEMPLATES */
    let templatePendingAttribute: string | undefined = attributes.get(TEMPLATE_PENDING_ATTRIBUTE_NAME);
    let templateFulfilledAttribute: string | undefined = attributes.get(TEMPLATE_FULFILLED_ATTRIBUTE_NAME);
    let templateRejectedAttribute: string | undefined = attributes.get(TEMPLATE_REJECTED_ATTRIBUTE_NAME);

    if (templatePendingAttribute !== void 0) {
      templatePending = [generateTemplateVariableName(templatePendingAttribute)];
    }

    if (templateFulfilledAttribute !== void 0) {
      templateFulfilled = [generateTemplateVariableName(templateFulfilledAttribute)];
    }

    if (templateRejectedAttribute !== void 0) {
      templateRejected = [generateTemplateVariableName(templateRejectedAttribute)];
    }

    // ANALYSE CHILD NODES
    const childNodes: ArrayLike<ChildNode> = node.childNodes;

    for (let i = 0, l = childNodes.length; i < l; i++) {
      const childNode: ChildNode = childNodes[i];
      if (isElementNode(childNode)) {
        const result: ILinesOrNull = transpileReactiveHTMLRXAsyncPendingToJSLines({
          ...options,
          node: childNode,
        });
        if (result === null) {
          const result: ILinesOrNull = transpileReactiveHTMLRXAsyncFulfilledToJSLines({
            ...options,
            node: childNode,
          });
          if (result === null) {
            const result: ILinesOrNull = transpileReactiveHTMLRXAsyncRejectedToJSLines({
              ...options,
              node: childNode,
            });
            if (result === null) {
              throw createInvalidElementFoundError(childNode);
            } else if (templateRejected === void 0) {
              templateRejected = result;
            } else {
              throw createDuplicateTemplateError(TEMPLATE_REJECTED_ATTRIBUTE_NAME, node);
            }
          } else if (templateFulfilled === void 0) {
            templateFulfilled = result;
          } else {
            throw createDuplicateTemplateError(TEMPLATE_FULFILLED_ATTRIBUTE_NAME, node);
          }
        } else if (templatePending === void 0) {
          templatePending = result;
        } else {
          throw createDuplicateTemplateError(TEMPLATE_PENDING_ATTRIBUTE_NAME, node);
        }
      } else if (isTextNodeWithNonWhiteSpaceCharacters(childNode)) {
        throw createShouldNotContainTextNodeError(node);
      }
    }

    if (
      (templatePending === void 0)
      && (templateFulfilled === void 0)
      && (templateRejected === void 0)
    ) {
      throw createAtLeastOneOfTheseAttributesIsRequiredError([
        TEMPLATE_PENDING_ATTRIBUTE_NAME,
        TEMPLATE_FULFILLED_ATTRIBUTE_NAME,
        TEMPLATE_REJECTED_ATTRIBUTE_NAME,
      ], node);
    }

    if (templatePending === void 0) {
      templatePending = [NULL_TEMPLATE];
    }

    if (templateFulfilled === void 0) {
      templateFulfilled = [NULL_TEMPLATE];
    }

    if (templateRejected === void 0) {
      templateRejected = [NULL_TEMPLATE];
    }

    return generateJSLinesForRXAsync({
      ...options,
      expression,
      templatePending,
      templateFulfilled,
      templateRejected,
    });
  } else if (node.hasAttribute(COMMAND_NAME)) {
    const expression: string = node.getAttribute(COMMAND_NAME) as string;
    node.removeAttribute(COMMAND_NAME);

    return generateJSLinesForRXAsync({
      ...options,
      expression,
      templatePending: [NULL_TEMPLATE],
      templateFulfilled: generateJSLinesForRXTemplateFromRXContainerOrElement({
        ...options,
        node,
        argumentsLines: null,
      }),
      templateRejected: [NULL_TEMPLATE],
    });
  } else {
    return null;
  }
}


