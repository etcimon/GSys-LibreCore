import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import {
  transpileReactiveHTMLRXChildTemplateToJSLines,
} from '../../helpers/for-rx-template/transpile-reactive-html-rx-child-template-to-js-lines';
import { getOnFunctionsForRXAsyncChild } from '../shared/get-on-functions-for-rx-async-child';

const TAG_NAME: string = 'rx-async-fulfilled';
const COMMAND_NAME: string = '*async-fulfilled';

const TEMPLATE_ATTRIBUTE_NAME: string = 'template';

export interface ITranspileReactiveHTMLRXAsyncFulfilledToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXAsyncFulfilledToJSLines(
  options: ITranspileReactiveHTMLRXAsyncFulfilledToJSLinesOptions,
): ILinesOrNull {
  return transpileReactiveHTMLRXChildTemplateToJSLines({
    ...options,
    templateName: 'fulfilled',
    tagName: TAG_NAME,
    commandName: COMMAND_NAME,
    ...getOnFunctionsForRXAsyncChild({
      tag: {
        templateAttributeName: TEMPLATE_ATTRIBUTE_NAME,
      },
      command: {
        commandName: COMMAND_NAME,
      },
    }),
  });
}
