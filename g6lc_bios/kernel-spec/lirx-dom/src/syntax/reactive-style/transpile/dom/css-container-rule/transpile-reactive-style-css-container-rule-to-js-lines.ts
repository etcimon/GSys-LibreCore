import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingHostSelectorOptions } from '../../types/having-host-selector-options';
import {
  transpileReactiveStyleGenericCSSContainerRuleToCSSLines,
} from './transpilers/transpile-reactive-style-generic-css-container-rule-to-js-lines';

export interface ITranspileReactiveStyleCSSContainerRuleToCSSLinesOptions extends IHavingHostSelectorOptions {
  readonly rule: CSSContainerRule;
}

export const transpileReactiveStyleCSSContainerRuleToCSSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveStyleCSSContainerRuleToCSSLinesOptions]>(() => [
  transpileReactiveStyleGenericCSSContainerRuleToCSSLines,
]);



