import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleGenericCSSMediaRuleToCSSLines,
} from './transpilers/transpile-reactive-style-generic-css-media-rule-to-js-lines';

export interface ITranspileReactiveStyleCSSMediaRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSMediaRule;
}

export const transpileReactiveStyleCSSMediaRuleToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSMediaRuleToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSMediaRuleToCSSLines,
]);



