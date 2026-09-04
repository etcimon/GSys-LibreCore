import { nullIfEmptyLines } from '../../../../../misc/lines/functions/null-if-empty-lines';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { ILines } from '../../../../../misc/lines/lines.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import { transpileReactiveStyleCSSRuleToCSSLines } from '../../css-rule/transpile-reactive-style-css-rule-to-js-lines';

export interface ITranspileReactiveStyleGenericCSSRuleListToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rules: ArrayLike<CSSRule>;
}

export function transpileReactiveStyleGenericCSSRuleListToCSSLines(
  {
    rules,
    ...options
  }: ITranspileReactiveStyleGenericCSSRuleListToCSSLinesOptions,
): ILinesOrNull {
  const lines: ILines = [];
  for (let i = 0, l = rules.length; i < l; i++) {
    const result: ILinesOrNull = transpileReactiveStyleCSSRuleToCSSLines({
      rule: rules[i],
      ...options,
    });
    if (result !== null) {
      lines.push(...result);
    }
  }
  return nullIfEmptyLines(lines);
}
