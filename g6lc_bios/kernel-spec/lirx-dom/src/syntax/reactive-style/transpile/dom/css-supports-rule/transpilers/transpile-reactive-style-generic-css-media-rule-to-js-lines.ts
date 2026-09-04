import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { linesOrNullToLines } from '../../../../../misc/lines/functions/lines-or-null-to-lines';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import {
  transpileReactiveStyleCSSGroupingRuleToCSSLines,
} from '../../css-grouping-rule/transpile-reactive-style-css-grouping-rule-to-js-lines';

export interface ITranspileReactiveStyleGenericCSSSupportsRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSSupportsRule;
}

export function transpileReactiveStyleGenericCSSSupportsRuleToCSSLines(
  {
    rule,
    ...options
  }: ITranspileReactiveStyleGenericCSSSupportsRuleToCSSLinesOptions,
): ILinesOrNull {
  const lines: ILinesOrNull = transpileReactiveStyleCSSGroupingRuleToCSSLines({
    ...options,
    rule,
  });

  return [
    `@supports ${rule.conditionText} {`,
    ...indentLines(linesOrNullToLines(lines)),
    `}`,
  ];
}



