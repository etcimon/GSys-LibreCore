import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import { transpileReactiveStyleCSSSelectorToCSSSelector } from '../../css-selector/transpile-reactive-style-css-selector-to-css-selector';

export interface ITranspileReactiveStyleGenericCSSStyleRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSStyleRule;
}

export function transpileReactiveStyleGenericCSSStyleRuleToCSSLines(
  {
    rule,
    ...options
  }: ITranspileReactiveStyleGenericCSSStyleRuleToCSSLinesOptions,
): ILinesOrNull {
  rule.selectorText = transpileReactiveStyleCSSSelectorToCSSSelector({
    ...options,
    selector: rule.selectorText,
  });

  return [
    rule.cssText,
    '',
  ];
}



