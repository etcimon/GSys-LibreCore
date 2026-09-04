import { ITranspileReactiveHTMLRXChildTemplateToJSLinesOptions } from '../../transpile-reactive-html-rx-child-template-to-js-lines';
import {
  createOnCommandFunctionForTemplateWithoutAttributes,
  ICreateOnCommandFunctionForTemplateWithoutAttributes,
} from './create-on-command-function-for-template-without-attributes';
import {
  createOnTagFunctionForTemplateWithoutAttributes,
  ICreateOnTagFunctionForTemplateWithoutAttributes,
} from './create-on-tag-function-for-template-without-attributes';

export interface ICreateOnFunctionsForTemplateWithoutAttributes {
  readonly tag: ICreateOnTagFunctionForTemplateWithoutAttributes;
  readonly command: ICreateOnCommandFunctionForTemplateWithoutAttributes;
}

export type ICreateOnFunctionsForTemplateWithoutAttributesResult = Pick<ITranspileReactiveHTMLRXChildTemplateToJSLinesOptions, 'onTag' | 'onCommand'>;

export function createOnFunctionsForTemplateWithoutAttributes(
  {
    tag,
    command,
  }: ICreateOnFunctionsForTemplateWithoutAttributes,
): ICreateOnFunctionsForTemplateWithoutAttributesResult {
  return {
    onTag: createOnTagFunctionForTemplateWithoutAttributes(tag),
    onCommand: createOnCommandFunctionForTemplateWithoutAttributes(command),
  };
}
