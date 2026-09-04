import { ILinesOrNull } from '../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import { transpileReactiveStyleCSSStyleSheetToCSSLines } from '../css-style-sheet/transpile-reactive-style-css-style-sheet-to-js-lines';

export interface ITranspileReactiveStyleStyleElementToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly node: HTMLStyleElement;
}

export function transpileReactiveStyleStyleElementToCSSLines(
  {
    node,
    ...options
  }: ITranspileReactiveStyleStyleElementToCSSLinesOptions,
): ILinesOrNull {

  document.head.appendChild(node);

  const sheet: CSSStyleSheet = node.sheet as CSSStyleSheet;
  sheet.disabled = true;

  const lines: ILinesOrNull = transpileReactiveStyleCSSStyleSheetToCSSLines({
    ...options,
    sheet,
  });

  document.head.removeChild(node);

  return lines;
}

