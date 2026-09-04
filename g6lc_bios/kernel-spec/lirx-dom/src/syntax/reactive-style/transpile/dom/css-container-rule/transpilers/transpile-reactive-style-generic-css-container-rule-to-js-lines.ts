import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { linesOrNullToLines } from '../../../../../misc/lines/functions/lines-or-null-to-lines';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import {
  transpileReactiveStyleCSSGroupingRuleToCSSLines,
} from '../../css-grouping-rule/transpile-reactive-style-css-grouping-rule-to-js-lines';

export interface ITranspileReactiveStyleGenericCSSContainerRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSContainerRule;
}

export function transpileReactiveStyleGenericCSSContainerRuleToCSSLines(
  {
    rule,
    ...options
  }: ITranspileReactiveStyleGenericCSSContainerRuleToCSSLinesOptions,
): ILinesOrNull {
  const lines: ILinesOrNull = transpileReactiveStyleCSSGroupingRuleToCSSLines({
    ...options,
    rule,
  });

  return [
    `@container ${rule.conditionText} {`,
    ...indentLines(linesOrNullToLines(lines)),
    `}`,
  ];
}



