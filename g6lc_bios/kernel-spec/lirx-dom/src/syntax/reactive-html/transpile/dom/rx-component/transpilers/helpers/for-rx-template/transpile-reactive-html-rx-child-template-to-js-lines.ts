import { getElementTagName } from '../../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { ILinesOrNull } from '../../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../../primary/primary-transpilers.type';
import { generateJSLinesForRXTemplateFromNodes } from './generate-js-lines-for-rx-template-from-nodes';
import { generateJSLinesForRXTemplateFromRXContainerOrElement } from './generate-js-lines-for-rx-template-from-rx-container-or-element';

/* SHARED */

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsGenerateTemplateFunctionOptions {
  readonly argumentsLines: ILinesOrNull;
}

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsGenerateTemplateFunction {
  (
    options: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsGenerateTemplateFunctionOptions,
  ): ILines;
}

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsSharedFunctionOptions {
  readonly generateTemplate: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsGenerateTemplateFunction;
}

/* TAG */

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions extends ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsSharedFunctionOptions {
  readonly node: Element;
}

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction {
  (
    options: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunctionOptions,
  ): ILinesOrNull;
}

/* COMMAND */

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions extends ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsSharedFunctionOptions {
  readonly node: Element;
  readonly attributeValue: string;
}

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction {
  (
    options: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunctionOptions,
  ): ILinesOrNull;
}

/* OPTIONS */

export interface ITranspileReactiveHTMLRXChildTemplateToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
  readonly tagName: string;
  readonly commandName: string;
  readonly templateName?: string;
  readonly onTag: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnTagFunction;
  readonly onCommand: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsOnCommandFunction;
}

export function transpileReactiveHTMLRXChildTemplateToJSLines(
  {
    node,
    tagName,
    commandName,
    templateName,
    onTag,
    onCommand,
    ...options
  }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptions,
): ILinesOrNull {
  const name: string = getElementTagName(node);

  const templateNameLines: ILines = (templateName === void 0)
    ? []
    : [`// ${templateName}`];

  if (name === tagName) {
    return onTag({
      node,
      generateTemplate: (
        {
          argumentsLines,
        }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsGenerateTemplateFunctionOptions,
      ): ILines => {
        return [
          ...templateNameLines,
          ...generateJSLinesForRXTemplateFromNodes({
            ...options,
            nodes: node.childNodes,
            argumentsLines,
          }),
        ];
      },
    });
  } else if (node.hasAttribute(commandName)) {
    const attributeValue: string = node.getAttribute(commandName) as string;
    node.removeAttribute(commandName);

    return onCommand({
      node,
      attributeValue,
      generateTemplate: (
        {
          argumentsLines,
        }: ITranspileReactiveHTMLRXChildTemplateToJSLinesOptionsGenerateTemplateFunctionOptions,
      ): ILines => {
        return [
          ...templateNameLines,
          ...generateJSLinesForRXTemplateFromRXContainerOrElement({
            ...options,
            node,
            argumentsLines,
          }),
        ];
      },
    });
  } else {
    return null;
  }
}
