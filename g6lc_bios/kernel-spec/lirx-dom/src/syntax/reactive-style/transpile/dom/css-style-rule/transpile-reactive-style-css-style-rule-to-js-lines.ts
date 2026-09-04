import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleGenericCSSStyleRuleToCSSLines,
} from './transpilers/transpile-reactive-style-generic-css-style-rule-to-js-lines';

export interface ITranspileReactiveStyleCSSStyleRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSStyleRule;
}

export const transpileReactiveStyleCSSStyleRuleToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSStyleRuleToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSStyleRuleToCSSLines,
]);



