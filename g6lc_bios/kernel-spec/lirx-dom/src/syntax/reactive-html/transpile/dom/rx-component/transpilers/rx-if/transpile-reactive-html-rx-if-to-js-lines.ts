import { isElementNode } from '../../../../../../../dom-manipulation/helpers/is/node-type/is-element-node';
import {
  isTextNodeWithNonWhiteSpaceCharacters,
} from '../../../../../../../dom-manipulation/helpers/is/node-type/is-text-node-with-non-white-space-characters';
import {
  createAtLeastOneOfTheseAttributesIsRequiredError,
} from '../../../../../../misc/errors/create-at-least-one-of-these-attributes-is-required-error';
import { createDuplicateTemplateError } from '../../../../../../misc/errors/create-duplicate-template-error';
import { createInvalidElementFoundError } from '../../../../../../misc/errors/create-invalid-element-found-error';
import { createMissingAttributeError } from '../../../../../../misc/errors/create-missing-attribute-error';
import { createMissingAttributeValueError } from '../../../../../../misc/errors/create-missing-attribute-value-error';
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
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  transpileReactiveHTMLRXChildTemplateToJSLines,
} from '../helpers/for-rx-template/transpile-reactive-html-rx-child-template-to-js-lines';
import { generateJSLinesForRXIf } from './generate-js-lines-for-rx-if';
import { transpileReactiveHTMLRXIfFalseToJSLines } from './rx-if-false/transpile-reactive-html-rx-if-false-to-js-lines';
import { transpileReactiveHTMLRXIfTrueToJSLines } from './rx-if-true/transpile-reactive-html-rx-if-true-to-js-lines';
import { extractReactiveValueFromString } from '../../../../misc/extract-reactive-value-from-string';

/*
Syntax:

<rx-if
  condition="conditionObservable"
  true="templateReferenceNameTrue"
  false="templateReferenceNameFalse"
></rx-if>

 */

/*
Syntax - alternative:

<element
  *if="conditionObservable"
>
  ...content
</element>

====> equivalent

<rx-template
  name="uuid"
>
  ...content
</rx-template>
<rx-if
  condition="conditionObservable"
  true="uuid"
></rx-if>

 */

const TAG_NAME: string = 'rx-if';
const COMMAND_NAME: string = '*if';

const CONDITION_ATTRIBUTE_NAME: string = 'condition';
const TEMPLATE_TRUE_ATTRIBUTE_NAME: string = 'true';
const TEMPLATE_FALSE_ATTRIBUTE_NAME: string = 'false';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  CONDITION_ATTRIBUTE_NAME,
  TEMPLATE_TRUE_ATTRIBUTE_NAME,
  TEMPLATE_FALSE_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXIfToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXIfToJSLines(
  options: ITranspileReactiveHTMLRXIfToJSLinesOptions,
): ILinesOrNull {
  return transpileReactiveHTMLRXChildTemplateToJSLines({
    ...options,
    tagName: TAG_NAME,
    commandName: COMMAND_NAME,
    onTag: getOnTagFunctionForRXIf(options),
    onCommand: getOnCommandFunctionForRXIf(options),
  });
}

/* FUNCTIONS */

/* TEMPLATE */

function getOnTagFunctionForRXIf(
  options: ITranspileReactiveHTMLRXIfToJSLinesOptions,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction {
  return (
    {
      node,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  ): ILinesOrNull => {
    let condition!: string;
    let templateTrue!: ILines;
    let templateFalse!: ILines;

    const attributes: IMappedAttributes = extractRXAttributesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    /* CONDITION */
    const conditionAttribute: string | undefined = attributes.get(CONDITION_ATTRIBUTE_NAME);

    if (conditionAttribute === void 0) {
      throw createMissingAttributeError(CONDITION_ATTRIBUTE_NAME, node);
    } else {
      condition = conditionAttribute;
    }

    /* TEMPLATES */
    const templateTrueAttribute: string | undefined = attributes.get(TEMPLATE_TRUE_ATTRIBUTE_NAME);
    const templateFalseAttribute: string | undefined = attributes.get(TEMPLATE_FALSE_ATTRIBUTE_NAME);

    if (templateTrueAttribute !== void 0) {
      templateTrue = [generateTemplateVariableName(templateTrueAttribute)];
    }

    if (templateFalseAttribute !== void 0) {
      templateFalse = [generateTemplateVariableName(templateFalseAttribute)];
    }

    // ANALYSE CHILD NODES
    const childNodes: ArrayLike<ChildNode> = node.childNodes;

    for (let i = 0, l = childNodes.length; i < l; i++) {
      const childNode: ChildNode = childNodes[i];
      if (isElementNode(childNode)) {
        const result: ILinesOrNull = transpileReactiveHTMLRXIfTrueToJSLines({
          ...options,
          node: childNode,
        });
        if (result === null) {
          const result: ILinesOrNull = transpileReactiveHTMLRXIfFalseToJSLines({
            ...options,
            node: childNode,
          });
          if (result === null) {
            throw createInvalidElementFoundError(childNode);
          } else if (templateFalse === void 0) {
            templateFalse = result;
          } else {
            throw createDuplicateTemplateError(TEMPLATE_FALSE_ATTRIBUTE_NAME, node);
          }
        } else if (templateTrue === void 0) {
          templateTrue = result;
        } else {
          throw createDuplicateTemplateError(TEMPLATE_TRUE_ATTRIBUTE_NAME, node);
        }
      } else if (isTextNodeWithNonWhiteSpaceCharacters(childNode)) {
        throw createShouldNotContainTextNodeError(node);
      }
    }

    if (
      (templateTrue === void 0)
      && (templateFalse === void 0)
    ) {
      throw createAtLeastOneOfTheseAttributesIsRequiredError([
        TEMPLATE_TRUE_ATTRIBUTE_NAME,
        TEMPLATE_FALSE_ATTRIBUTE_NAME,
      ], node);
    }

    if (templateTrue === void 0) {
      templateTrue = [NULL_TEMPLATE];
    }

    if (templateFalse === void 0) {
      templateFalse = [NULL_TEMPLATE];
    }

    return generateJSLinesForRXIf({
      ...options,
      condition: extractReactiveValueFromString(condition),
      templateTrue,
      templateFalse,
    });
  };
}

/* COMMAND */

function getOnCommandFunctionForRXIf(
  options: ITranspileReactiveHTMLRXIfToJSLinesOptions,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction {
  return (
    {
      node,
      attributeValue: condition,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ): ILinesOrNull => {
    if (condition === '') {
      throw createMissingAttributeValueError(COMMAND_NAME, node);
    } else {
      return generateJSLinesForRXIf({
        ...options,
        condition: extractReactiveValueFromString(condition),
        templateTrue: generateTemplate({
          argumentsLines: null,
        }),
        templateFalse: [NULL_TEMPLATE],
      });
    }
  };
}
