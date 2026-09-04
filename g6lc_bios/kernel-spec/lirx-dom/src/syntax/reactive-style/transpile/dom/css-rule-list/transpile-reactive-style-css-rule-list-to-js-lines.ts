import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleGenericCSSRuleListToCSSLines,
} from './transpilers/transpile-reactive-style-generic-css-rule-list-to-js-lines';

export interface ITranspileReactiveStyleCSSRuleListToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rules: ArrayLike<CSSRule>;
}

export const transpileReactiveStyleCSSRuleListToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSRuleListToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSRuleListToCSSLines,
]);



