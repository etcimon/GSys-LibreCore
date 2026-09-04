import { indentLines } from '../../../../../misc/lines/functions/indent-lines';
import { linesOrNullToLines } from '../../../../../misc/lines/functions/lines-or-null-to-lines';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import {
  transpileReactiveStyleCSSGroupingRuleToCSSLines,
} from '../../css-grouping-rule/transpile-reactive-style-css-grouping-rule-to-js-lines';

export interface ITranspileReactiveStyleGenericCSSMediaRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSMediaRule;
}

export function transpileReactiveStyleGenericCSSMediaRuleToCSSLines(
  {
    rule,
    ...options
  }: ITranspileReactiveStyleGenericCSSMediaRuleToCSSLinesOptions,
): ILinesOrNull {
  const lines: ILinesOrNull = transpileReactiveStyleCSSGroupingRuleToCSSLines({
    ...options,
    rule,
  });

  return [
    `@media ${rule.media.mediaText} {`,
    ...indentLines(linesOrNullToLines(lines)),
    `}`,
  ];
}



