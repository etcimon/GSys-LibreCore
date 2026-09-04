import { getElementTagName } from '../../../../../../../dom-manipulation/helpers/misc/get-element-tag-name';
import { stringToLines } from '../../../../../../misc/lines/functions/string-to-lines';
import { ILinesOrNull } from '../../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../../misc/lines/lines.type';
import { IHavingPrimaryTranspilersOptions } from '../../../../primary/primary-transpilers.type';

/*
Syntax:

<rx-script
>
  js code
</rx-script>

 */

const TAG_NAME: string = 'rx-script';
const ATTRIBUTE_NAME: string = 'rx';

export interface ITranspileReactiveHTMLRXScriptToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export function transpileReactiveHTMLRXScriptToJSLines(
  {
    node,
  }: ITranspileReactiveHTMLRXScriptToJSLinesOptions,
): ILinesOrNull {
  if (isRXScript(node)) {
    const lines: ILines = (node.textContent === null)
      ? []
      : stringToLines(node.textContent);
    return [
      `// rx-script`,
      ...lines,
    ];
  } else {
    return null;
  }
}

export function isRXScript(
  node: Element,
): boolean {
  return isRXScriptTagName(node)
    || isRXScriptHavingRxAttribute(node);
}

export function isRXScriptTagName(
  node: Element,
): boolean {
  return (getElementTagName(node) === TAG_NAME);
}

export function isRXScriptHavingRxAttribute(
  node: Element,
): boolean {
  return (getElementTagName(node) === 'script')
    && node.hasAttribute(ATTRIBUTE_NAME);
}

