import { throwIfHasChildNodes } from '../../../../../../../../../../dom-manipulation/helpers/misc/throw-if-has-child-nodes';
import { ILinesOrNull } from '../../../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../../../misc/lines/lines.type';
import { generateTemplateVariableName } from '../../../../../../../../../misc/templates/generate-template-variable-name';
import {
  extractRXAttributesFromReactiveHTMLAttribute,
} from '../../../extract-attributes/extract-rx-attributes-from-reactive-html-attribute';
import { IMappedAttributes } from '../../../extract-attributes/mapped-attributes.type';
import {
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
} from '../../transpile-reactive-html-rx-child-template-to-js-lines';

export interface ICreateOnTagFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions extends Pick<ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions, 'node'> {
  readonly attributes: IMappedAttributes;
}

export interface ICreateOnTagFunctionForTemplateWithoutAttributesGetArgumentsLinesFunction {
  (
    options: ICreateOnTagFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
  ): ILinesOrNull;
}

export interface ICreateOnTagFunctionForTemplateWithoutAttributes {
  readonly templateAttributeName: string;
  readonly extraAttributes?: readonly string[];
  readonly getArgumentsLines?: ICreateOnTagFunctionForTemplateWithoutAttributesGetArgumentsLinesFunction;
}

export function createOnTagFunctionForTemplateWithoutAttributes(
  {
    templateAttributeName,
    extraAttributes = [],
    getArgumentsLines = (): ILinesOrNull => null,
  }: ICreateOnTagFunctionForTemplateWithoutAttributes,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction {
  return (
    {
      node,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  ): ILinesOrNull => {
    let template!: ILines;

    const attributes: IMappedAttributes = extractRXAttributesFromReactiveHTMLAttribute(
      node.attributes,
      new Set<string>([
        templateAttributeName,
        ...extraAttributes,
      ]),
    );

    /* TEMPLATE */
    const templateAttribute: string | undefined = attributes.get(templateAttributeName);

    if (templateAttribute === void 0) {
      template = generateTemplate({
        argumentsLines: getArgumentsLines({
          node,
          attributes,
        }),
      });
    } else {
      template = [generateTemplateVariableName(templateAttribute)];
      throwIfHasChildNodes(node);
    }

    return template;
  };
}
