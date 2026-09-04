import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import { transpileReactiveStyleGenericCSSRuleToCSSLines } from './transpilers/transpile-reactive-style-generic-css-rule-to-js-lines';

export interface ITranspileReactiveStyleCSSRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSRule;
}

export const transpileReactiveStyleCSSRuleToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSRuleToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSRuleToCSSLines,
]);



