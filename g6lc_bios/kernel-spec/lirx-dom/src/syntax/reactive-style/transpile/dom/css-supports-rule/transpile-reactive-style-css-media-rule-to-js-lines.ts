import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleGenericCSSSupportsRuleToCSSLines,
} from './transpilers/transpile-reactive-style-generic-css-media-rule-to-js-lines';

export interface ITranspileReactiveStyleCSSSupportsRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSSupportsRule;
}

export const transpileReactiveStyleCSSSupportsRuleToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSSupportsRuleToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSSupportsRuleToCSSLines,
]);



