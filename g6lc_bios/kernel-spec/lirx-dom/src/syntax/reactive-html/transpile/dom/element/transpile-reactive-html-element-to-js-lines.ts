import {
  createGenericToLinesIteratorTranspilerWithAsyncReference,
} from '../../../../misc/iterator-transpiler/create-generic-to-lines-iterator-transpiler-with-async-reference';
import { IHavingPrimaryTranspilersOptions } from '../../primary/primary-transpilers.type';
import { transpileReactiveHTMLRXComponentToJSLines } from '../rx-component/transpile-reactive-html-rx-component-to-reactive-dom-js-lines';
import { transpileReactiveHTMLCustomElementToJSLines } from './transpilers/custom/transpile-reactive-html-custom-element-to-dom-js-lines';
import {
  transpileReactiveHTMLGenericElementToJSLines,
} from './transpilers/generic/transpile-reactive-html-generic-element-to-dom-js-lines';

export interface ITranspileReactiveHTMLElementToJSLinesOptions extends IHavingPrimaryTranspilersOptions {
  readonly node: Element;
}

export const transpileReactiveHTMLElementToJSLines = createGenericToLinesIteratorTranspilerWithAsyncReference<[ITranspileReactiveHTMLElementToJSLinesOptions]>(() => [
  transpileReactiveHTMLRXComponentToJSLines,
  transpileReactiveHTMLCustomElementToJSLines,
  transpileReactiveHTMLGenericElementToJSLines,
]);
