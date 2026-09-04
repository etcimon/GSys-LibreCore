import { isCSSContainerRule } from '../../../../../../dom-manipulation/helpers/is/css-rule/is-css-container-rule';
import { isCSSMediaRule } from '../../../../../../dom-manipulation/helpers/is/css-rule/is-css-media-rule';
import { isCSSStyleRule } from '../../../../../../dom-manipulation/helpers/is/css-rule/is-css-style-rule';
import { isCSSSupportsRule } from '../../../../../../dom-manipulation/helpers/is/css-rule/is-css-supports-rule';
import { ILinesOrNull } from '../../../../../misc/lines/lines-or-null.type';
import { IHavingHostSelectorOptions } from '../../../types/having-host-selector-options';
import {
  transpileReactiveStyleCSSContainerRuleToCSSLines,
} from '../../css-container-rule/transpile-reactive-style-css-container-rule-to-js-lines';
import { transpileReactiveStyleCSSMediaRuleToCSSLines } from '../../css-media-rule/transpile-reactive-style-css-media-rule-to-js-lines';
import { transpileReactiveStyleCSSStyleRuleToCSSLines } from '../../css-style-rule/transpile-reactive-style-css-style-rule-to-js-lines';
import {
  transpileReactiveStyleCSSSupportsRuleToCSSLines,
} from '../../css-supports-rule/transpile-reactive-style-css-media-rule-to-js-lines';

export interface ITranspileReactiveStyleGenericCSSRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSRule;
}

export function transpileReactiveStyleGenericCSSRuleToCSSLines(
  {
    rule,
    ...options
  }: ITranspileReactiveStyleGenericCSSRuleToCSSLinesOptions,
): ILinesOrNull {
  if (isCSSStyleRule(rule)) {
    return transpileReactiveStyleCSSStyleRuleToCSSLines({
      ...options,
      rule,
    });
  } else if (isCSSMediaRule(rule)) {
    return transpileReactiveStyleCSSMediaRuleToCSSLines({
      ...options,
      rule,
    });
  } else if (isCSSSupportsRule(rule)) {
    return transpileReactiveStyleCSSSupportsRuleToCSSLines({
      ...options,
      rule,
    });
  } else if (isCSSContainerRule(rule)) {
    return transpileReactiveStyleCSSContainerRuleToCSSLines({
      ...options,
      rule,
    });
  } else {
    return [
      rule.cssText,
    ];
  }
}
