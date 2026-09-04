import {
  createShouldNotHaveAttributeValueError,
} from '../../../../../../../../../misc/errors/create-should-not-have-attribute-value-error';
import { ILinesOrNull } from '../../../../../../../../../misc/lines/lines-or-null.type';
import {
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction,
  ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
} from '../../transpile-reactive-html-rx-child-template-to-js-lines';

export type ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions = Pick<ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions, 'attributeValue' | 'node'>

export interface ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunction {
  (
    options: ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
  ): ILinesOrNull;
}

export interface ICreateOnCommandFunctionForTemplateWithoutAttributes {
  readonly commandName: string;
  readonly getArgumentsLines?: ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunction;
}

export function createOnCommandFunctionForTemplateWithoutAttributes(
  {
    commandName,
    getArgumentsLines,
  }: ICreateOnCommandFunctionForTemplateWithoutAttributes,
): ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction {
  if (getArgumentsLines === void 0) {
    getArgumentsLines = (
      {
        node,
        attributeValue,
      }: ICreateOnCommandFunctionForTemplateWithoutAttributesGetArgumentsLinesFunctionOptions,
    ): ILinesOrNull => {
      if (attributeValue === '') {
        return null;
      } else {
        throw createShouldNotHaveAttributeValueError(commandName, node);
      }
    };
  }

  return (
    {
      node,
      attributeValue,
      generateTemplate,
    }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ): ILinesOrNull => {
    return generateTemplate({
      argumentsLines: getArgumentsLines!({
        node,
        attributeValue,
      }),
    });
  };
}
