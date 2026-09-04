import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import { transpileReactiveStyleCSSRuleListToCSSLines } from '../../css-rule-list/transpile-reactive-style-css-rule-list-to-js-lines';

export interface ITranspileReactiveStyleGenericCSSGroupingRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSGroupingRule;
}

export function transpileReactiveStyleGenericCSSGroupingRuleToCSSLines(
  {
    rule,
    ...options
  }: ITranspileReactiveStyleGenericCSSGroupingRuleToCSSLinesOptions,
): ILinesOrNull {
  return transpileReactiveStyleCSSRuleListToCSSLines({
    ...options,
    rules: rule.cssRules,
  });
}



