import { wrapLinesWithCurlyBrackets } from '../../../../../../misc/lines/functions/wrap-lines-with-curly-brackets';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import {
  ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap,
} from '../../../../primary/transpilers/transpile-create-reactive-switch-node-to-js-lines.type';
import { IReactiveValue } from '../../../../misc/extract-reactive-value-from-string';

export interface IGenerateJSLinesForRXSwitchOptions extends IHavingPrimaryTranspilersOptions {
  readonly expression: IReactiveValue;
  readonly templatesMap: ITranspileCreateReactiveSwitchNodeToJSLinesOptionsTemplatesMap;
  readonly defaultTemplate: ILinesOrNull;
}

export function generateJSLinesForRXSwitch(
  {
    expression,
    templatesMap,
    defaultTemplate,
    transpilers,
  }: IGenerateJSLinesForRXSwitchOptions,
): ILines {
  const {
    transpileAttachNodeToJSLines,
    transpileCreateReactiveSwitchNodeToJSLines,
  } = transpilers;

  return wrapLinesWithCurlyBrackets([
    `// reactive switch node`,
    ...transpileAttachNodeToJSLines({
      node: transpileCreateReactiveSwitchNodeToJSLines({
        expression,
        templatesMap,
        defaultTemplate,
      }),
      parentNode: ['parentNode'],
    }),
  ]);
}
