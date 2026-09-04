import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleGenericCSSGroupingRuleToCSSLines,
} from './transpilers/transpile-reactive-style-generic-css-grouping-rule-to-js-lines';

export interface ITranspileReactiveStyleCSSGroupingRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSGroupingRule;
}

export const transpileReactiveStyleCSSGroupingRuleToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSGroupingRuleToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSGroupingRuleToCSSLines,
]);



