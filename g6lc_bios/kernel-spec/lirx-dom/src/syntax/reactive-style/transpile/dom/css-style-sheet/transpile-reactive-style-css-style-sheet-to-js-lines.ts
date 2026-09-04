import { ILinesOrNull } from '../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import { transpileReactiveStyleCSSRuleListToCSSLines } from '../css-rule-list/transpile-reactive-style-css-rule-list-to-js-lines';

export interface ITranspileReactiveStyleCSSStyleSheetToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly sheet: CSSStyleSheet;
}

export function transpileReactiveStyleCSSStyleSheetToCSSLines(
  {
    sheet,
    ...options
  }: ITranspileReactiveStyleCSSStyleSheetToCSSLinesOptions,
): ILinesOrNull {
  return transpileReactiveStyleCSSRuleListToCSSLines({
    ...options,
    rules: sheet.cssRules,
  });
}

