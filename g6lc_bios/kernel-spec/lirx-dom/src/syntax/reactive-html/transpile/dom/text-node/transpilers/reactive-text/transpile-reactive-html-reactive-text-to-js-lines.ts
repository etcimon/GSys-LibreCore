import { nullIfEmptyLines } from '../../../../../../misc/lines/functions/null-if-empty-lines';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';
import { generateJSLinesForStaticTextNode } from '../static-text/generate-js-lines-for-static-text-node';
import { generateJSLinesForReactiveTextNode } from './generate-js-lines-for-reactive-text-node';
import { extractReactiveValueFromString } from '../../../../misc/extract-reactive-value-from-string';

/**
 * Syntax: {{ variable }}
 */

const REACTIVE_TEXT_NODE_PATTERN: string = '{{(.*?)}}';
const REACTIVE_TEXT_NODE_REGEXP: RegExp = new RegExp(REACTIVE_TEXT_NODE_PATTERN, 'g');

export interface ITranspileReactiveHTMLReactiveTextToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly value: string;
}

export function transpileReactiveHTMLReactiveTextToJSLines(
  {
    value,
    ...options
  }: ITranspileReactiveHTMLReactiveTextToJSLinesOptions,
): ILinesOrNull {
  const lines: ILines = [];

  REACTIVE_TEXT_NODE_REGEXP.lastIndex = 0;
  let match: RegExpExecArray | null;
  let index: number = 0;

  while ((match = REACTIVE_TEXT_NODE_REGEXP.exec(value)) !== null) {
    if (index !== match.index) {
      lines.push(...generateJSLinesForStaticTextNode({
        ...options,
        value: value.substring(index, match.index),
      }));
    }

    lines.push(...generateJSLinesForReactiveTextNode({
      ...options,
      value: extractReactiveValueFromString(match[1].trim()),
    }));

    index = match.index + match[0].length;
  }

  if (index !== value.length) {
    lines.push(...generateJSLinesForStaticTextNode({
      ...options,
      value: value.substring(index),
    }));
  }

  return nullIfEmptyLines(lines);
}
