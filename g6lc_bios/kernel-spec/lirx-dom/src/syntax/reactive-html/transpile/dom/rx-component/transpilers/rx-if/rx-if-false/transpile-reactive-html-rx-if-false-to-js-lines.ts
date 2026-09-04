import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import {
  createOnFunctionsForTemplateWithoutAttributes,
} from '../../helpers/for-rx-template/built-in/without-attributes/create-on-functions-for-template-without-attributes';
import {
  transpileReactiveHTMLRXChildTemplateToJSLines,
} from '../../helpers/for-rx-template/transpile-reactive-html-rx-child-template-to-js-lines';

const TAG_NAME: string = 'rx-if-false';
const COMMAND_NAME: string = '*if-false';

const TEMPLATE_ATTRIBUTE_NAME: string = 'template';

export interface ITranspileReactiveHTMLRXIfFalseToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXIfFalseToJSLines(
  options: ITranspileReactiveHTMLRXIfFalseToJSLinesOptions,
): ILinesOrNull {
  return transpileReactiveHTMLRXChildTemplateToJSLines({
    ...options,
    templateName: 'false',
    tagName: TAG_NAME,
    commandName: COMMAND_NAME,
    ...createOnFunctionsForTemplateWithoutAttributes({
      tag: {
        templateAttributeName: TEMPLATE_ATTRIBUTE_NAME,
      },
      command: {
        commandName: COMMAND_NAME,
      },
    }),
  });
}
