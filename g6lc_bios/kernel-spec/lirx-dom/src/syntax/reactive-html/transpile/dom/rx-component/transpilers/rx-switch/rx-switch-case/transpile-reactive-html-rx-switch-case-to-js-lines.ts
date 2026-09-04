import { throwIfHasChildNodes } from '../../../../../../../../dom-manipulation/helpers/misc/throw-if-has-child-nodes';
import {
  createAtLeastOneOfTheseAttributesIsRequiredError,
} from '../../../../../../../misc/errors/create-at-least-one-of-these-attributes-is-required-error';
import { createMaximumOneOfTheseAttributesError } from '../../../../../../../misc/errors/create-maximum-one-of-these-attributes-error';
import { createMissingAttributeValueError } from '../../../../../../../misc/errors/create-missing-attribute-value-error';
import { createSwitchCaseAlreadyDefinedError } from '../../../../../../../misc/errors/create-switch-case-already-defined-error';
import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { generateTemplateVariableName } from '../../../../../../../misc/templates/generate-template-variable-name';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import {
  ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap,
} from '../../../../../primary/transpilers/transpile-create-reactive-switch-node-to-js-lines.type';
import {
  extractRXAttributesFromReactiveHTMLAttribute,
} from '../../helpers/extract-attributes/extract-rx-attributes-from-reactive-html-attribute';
import { IMappedAttributes } from '../../helpers/extract-attributes/mapped-attributes.type';
import {
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  transpileReactiveHTMLRXChildTemplateToJSLines,
} from '../../helpers/for-rx-template/transpile-reactive-html-rx-child-template-to-js-lines';

const TAG_NAME: string = 'rx-switch-case';
const COMMAND_NAME: string = '*switch-case';

const SWITCH_CASE_ATTRIBUTE_NAME: string = 'case';
const SWITCH_CASES_ATTRIBUTE_NAME: string = 'cases';
const TEMPLATE_ATTRIBUTE_NAME: string = 'template';

const ATTRIBUTE_NAMES: Set<string> = new Set<string>([
  SWITCH_CASE_ATTRIBUTE_NAME,
  SWITCH_CASES_ATTRIBUTE_NAME,
  TEMPLATE_ATTRIBUTE_NAME,
]);

export interface ITranspileReactiveHTMLRXSwitchCaseToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly templatesMap: ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap;
}

export function transpileReactiveHTMLRXSwitchCaseToJSLines(
  options: ITranspileReactiveHTMLRXSwitchCaseToJSLinesOptions,
): ILinesOrNull {
  return transpileReactiveHTMLRXChildTemplateToJSLines({
    ...options,
    tagName: TAG_NAME,
    commandName: COMMAND_NAME,
    onTag: getOnTagFunctionForRXSwitchCase(options),
    onCommand: getOnCommandFunctionForRXSwitchCase(options),
  });
}

/* FUNCTIONS */

/* TEMPLATE */

interface IGetOnTagFunctionForRXSwitchCaseOptions {
  readonly templatesMap: ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap;
}

function getOnTagFunctionForRXSwitchCase(
  {
    templatesMap,
  }: IGetOnTagFunctionForRXSwitchCaseOptions,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction {
  return (
    {
      node,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  ): ILinesOrNull => {
    let caseValues!: string[];
    let template!: ILines;

    const attributes: IMappedAttributes = extractRXAttributesFromReactiveHTMLAttribute(
      node.attributes,
      ATTRIBUTE_NAMES,
    );

    /* CASES VALUE */
    const casesValueAttribute: string | undefined = attributes.get(SWITCH_CASES_ATTRIBUTE_NAME);
    const caseValueAttribute: string | undefined = attributes.get(SWITCH_CASE_ATTRIBUTE_NAME);

    if (casesValueAttribute === void 0) {
      if (caseValueAttribute === void 0) {
        throw createAtLeastOneOfTheseAttributesIsRequiredError([SWITCH_CASE_ATTRIBUTE_NAME, SWITCH_CASES_ATTRIBUTE_NAME], node);
      } else {
        caseValues = [caseValueAttribute];
      }
    } else {
      if (caseValueAttribute === void 0) {
        caseValues = eval(casesValueAttribute);
      } else {
        throw createMaximumOneOfTheseAttributesError([SWITCH_CASE_ATTRIBUTE_NAME, SWITCH_CASES_ATTRIBUTE_NAME], node);
      }
    }

    /* TEMPLATE */
    const templateAttribute: string | undefined = attributes.get(TEMPLATE_ATTRIBUTE_NAME);

    if (templateAttribute === void 0) {
      template = generateTemplate({
        argumentsLines: null,
      });
    } else {
      template = [generateTemplateVariableName(templateAttribute)];
      throwIfHasChildNodes(node);
    }

    for (let i = 0, l = caseValues.length; i < l; i++) {
      templatesMap.set(caseValues[i], template);
    }

    return template;
  };
}

/* COMMAND */

interface IGetOnCommandFunctionForRXSwitchCaseOptions {
  readonly templatesMap: ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap;
}

function getOnCommandFunctionForRXSwitchCase(
  {
    templatesMap,
  }: IGetOnCommandFunctionForRXSwitchCaseOptions,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction {
  return (
    {
      node,
      attributeValue: caseValue,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ): ILinesOrNull => {
    if (caseValue === '') {
      throw createMissingAttributeValueError(COMMAND_NAME, node);
    } else if (templatesMap.has(caseValue)) {
      throw createSwitchCaseAlreadyDefinedError(caseValue, node.parentElement!);
    } else {
      const template: ILines = generateTemplate({
        argumentsLines: null,
      });
      templatesMap.set(caseValue, template);
      return template;
    }
  };
}


